// START imports OMIT

package sweep

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"slices"
	"time"

	"sweep/conc"
)

// END imports OMIT

// Status is the outcome of checking one target.
type Status string

const (
	StatusUp        Status = "up"
	StatusDown      Status = "down"
	StatusCancelled Status = "cancelled" // the run was interrupted mid-check
)

// Result is the report for one target.
type Result struct {
	Index   int
	Target  string
	Kind    Kind
	Status  Status
	Latency time.Duration
	Detail  string
	Error   string
}

// START config OMIT
// Config holds every knob that shapes a sweep's load on the outside world.
type Config struct {
	Concurrency int           // targets in flight across the whole run
	Timeout     time.Duration // bound on each check
	HTTP        HTTPProber    // checks http:// and https:// targets
}

// Runner executes sweeps. It is safe for concurrent use.
type Runner struct {
	cfg Config
}

// NewRunner validates cfg and returns a Runner.
func NewRunner(cfg Config) (*Runner, error) {
	var errs []error
	check := func(ok bool, format string, arg any) {
		if !ok {
			errs = append(errs, fmt.Errorf(format, arg))
		}
	}
	check(cfg.Concurrency >= 1, "concurrency must be >= 1, got %d", cfg.Concurrency)
	check(cfg.Timeout > 0, "timeout must be positive, got %s", cfg.Timeout)
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	return &Runner{cfg: cfg}, nil
}

// END config OMIT

// START run OMIT
// Run checks every target and yields results as they complete. Breaking out
// of the loop cancels the remaining work; cancelling ctx stops new checks
// and marks in-flight ones as cancelled. Either way, no goroutine outlives
// the loop.
func (r *Runner) Run(ctx context.Context, targets []Target) iter.Seq[Result] {
	return conc.Stream(ctx, slices.Values(targets), r.cfg.Concurrency, r.check)
}

// END run OMIT

// errAttemptTimeout is the cancellation cause of a single timed-out attempt,
// distinguishing "this target is slow" from "the user pressed Ctrl-C".
var errAttemptTimeout = errors.New("attempt timed out")

func (r *Runner) check(ctx context.Context, t Target) Result {
	res := Result{Index: t.Index, Target: t.Raw, Kind: t.Kind}
	actx, cancel := context.WithTimeoutCause(ctx, r.cfg.Timeout, errAttemptTimeout)
	defer cancel()

	start := time.Now()
	detail, err := r.cfg.HTTP.Probe(actx, t)
	res.Detail, res.Latency = detail, time.Since(start)
	switch {
	case err == nil:
		res.Status = StatusUp
	case ctx.Err() != nil: // the whole run was cancelled, not just this check
		return cancelled(res, context.Cause(ctx))
	case errors.Is(context.Cause(actx), errAttemptTimeout):
		res.Status = StatusDown
		res.Error = fmt.Sprintf("%v after %s", errAttemptTimeout, r.cfg.Timeout)
	default:
		res.Status, res.Error = StatusDown, err.Error()
	}
	return res
}

func cancelled(res Result, cause error) Result {
	res.Status = StatusCancelled
	res.Error = cause.Error()
	return res
}
