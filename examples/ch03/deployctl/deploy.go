package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/conc"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

const deployUsage = `usage: deployctl deploy [-timeout D] [-parallel N] [-only T,...] VERSION
`

// result is the outcome for one target.
type result struct {
	Target string
	Took   time.Duration
	Err    error
}

func deploy(ctx context.Context, g globals, args []string,
	getenv func(string) string, log *slog.Logger, stdout io.Writer) error {

	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	timeout := fs.Duration("timeout", 30*time.Second, "deadline for the whole deploy")
	parallel := fs.Int("parallel", 4, "targets deployed at once")
	only := fs.String("only", "", "comma-separated subset of targets")
	if err := parse(fs, args, stdout, deployUsage); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fmt.Errorf("deploy needs one VERSION, got %d arguments",
			fs.NArg()), "deploy")
	}
	if *parallel < 1 {
		return usageError(errors.New("-parallel must be at least 1"), "deploy")
	}
	version := fs.Arg(0)

	cfg, err := loadConfig(g.config)
	if err != nil {
		return err
	}
	targets := cfg.Targets
	if *only != "" {
		targets = splitList(*only)
	}

	// START cause OMIT
	// The cause is a ready-made user-facing error. It also wraps
	// DeadlineExceeded, so errors.Is checks written for plain timeouts
	// keep working.
	ctx, cancel := context.WithTimeoutCause(ctx, *timeout, &clierr.Error{
		Code:    clierr.ExitTempFail,
		ID:      "DPL-TIMEOUT",
		Message: fmt.Sprintf("deploy did not finish within %s", *timeout),
		Hint: `targets may still be converging: check "deployctl status", ` +
			"then re-run",
		Err: context.DeadlineExceeded,
	})
	defer cancel()
	// END cause OMIT

	client := newClient(cfg, getenv, log)
	if err := client.checkAuth(ctx); err != nil {
		return err
	}
	return rollout(ctx, client, cfg.Service, version, targets, *parallel,
		g.output == "json", stdout)
}

// START rollout OMIT
// rollout deploys to every target, at most parallel at a time, prints each
// result as it arrives, and returns one error describing all failures.
func rollout(ctx context.Context, c *Client, service, version string,
	targets []string, parallel int, asJSON bool, stdout io.Writer) error {

	if !asJSON {
		fmt.Fprintf(stdout, "deploying %s %s to %d targets\n",
			service, version, len(targets))
	}
	one := func(ctx context.Context, target string) result {
		start := time.Now()
		err := clierr.Safe(func() error { // a panic here is on a worker goroutine
			return c.Deploy(ctx, target, service, version)
		})
		return result{Target: target, Took: elapsed(start), Err: err}
	}

	var failed []error
	seen := make(map[string]bool)
	for r := range conc.Stream(ctx, slices.Values(targets), parallel, one) {
		seen[r.Target] = true
		if r.Err != nil {
			r.Err = targetError(ctx, r.Target, r.Err)
			failed = append(failed, r.Err)
		}
		printResult(stdout, r, asJSON)
	}
	for _, t := range targets { // never started: the context ended first
		if !seen[t] {
			failed = append(failed, &clierr.Error{Message: t + ": not started"})
		}
	}
	if len(failed) == 0 {
		return nil
	}
	return rolloutError(ctx, version, len(failed), len(targets), failed)
}

// END rollout OMIT

// START outcome OMIT
// rolloutError is the single error for a rollout with failures. If the
// context ended (deadline or signal), that is the headline; otherwise it
// is a partial failure, which is exit 1 even when some targets timed out.
func rolloutError(ctx context.Context, version string, nFailed, total int,
	failed []error) error {

	e := &clierr.Error{
		Code: clierr.ExitFailure,
		ID:   "DPL-PARTIAL",
		Message: fmt.Sprintf("deploy of %s failed on %d of %d targets",
			version, nFailed, total),
		Hint: "fix the failing targets, then re-run with -only " +
			strings.Join(names(failed), ","),
		Docs: docs + "#dpl-partial",
		Err:  errors.Join(failed...),
	}
	switch cause := context.Cause(ctx); {
	case cause == nil:
	case errors.Is(cause, context.DeadlineExceeded):
		if c, ok := errors.AsType[*clierr.Error](cause); ok {
			e.Code, e.ID, e.Message, e.Hint = c.Code, c.ID, c.Message, c.Hint
			e.Docs = ""
		}
	default: // a signal: Run turns it into 128+n
		e.ID, e.Docs = "DPL-INTERRUPTED", ""
		e.Message = fmt.Sprintf("deploy of %s interrupted; %d of %d targets "+
			"not updated", version, nFailed, total)
		e.Hint = "re-run the same command to finish the rollout"
	}
	return e
}

// END outcome OMIT

// START targeterr OMIT
// targetError turns one target's failure into a line a person can act on,
// prefixed with the target, and keeps the full error underneath.
func targetError(ctx context.Context, target string, err error) error {
	msg := err.Error() // last resort: the raw chain
	if apiErr, ok := errors.AsType[*APIError](err); ok {
		msg = fmt.Sprintf("%s (HTTP %d", apiErr.Message, apiErr.Status)
		if ex, ok := errors.AsType[*retry.ExhaustedError](err); ok {
			msg += fmt.Sprintf(", %d attempts", ex.Attempts)
		}
		msg += ")"
	}
	if _, ok := errors.AsType[*clierr.PanicError](err); ok {
		msg = "internal error (see crash report)"
	}
	// net/http fails with context.Cause(ctx), not ctx.Err(), so test for
	// the cause: errors.Is(err, context.Canceled) is false after a signal.
	if cause := context.Cause(ctx); cause != nil && errors.Is(err, cause) {
		msg = "stopped before the API answered"
	}
	return &clierr.Error{Message: target + ": " + msg, Err: err}
}

// END targeterr OMIT

// names returns the target names from errors made by targetError.
func names(failed []error) []string {
	var out []string
	for _, err := range failed {
		if e, ok := errors.AsType[*clierr.Error](err); ok {
			out = append(out, strings.SplitN(e.Message, ":", 2)[0])
		}
	}
	return out
}

func printResult(w io.Writer, r result, asJSON bool) {
	status, detail := "deployed", ""
	if r.Err != nil {
		status, detail = "failed", clierr.UserMessage(r.Err)
	}
	if asJSON {
		_ = json.NewEncoder(w).Encode(struct {
			Target string `json:"target"`
			Status string `json:"status"`
			Took   string `json:"took"`
			Error  string `json:"error,omitempty"`
		}{r.Target, status, r.Took.String(), detail})
		return
	}
	fmt.Fprintf(w, "  %-11s %-8s %s\n", r.Target, status, r.Took)
}
