// START imports OMIT

package sweep

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"slices"
	"time"

	"golang.org/x/time/rate"

	"github.com/rahulbalajee/platform-go/pkg/conc"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// END imports OMIT

// START status OMIT
// Status is the outcome of checking one target.
type Status string

const (
	StatusUp        Status = "up"
	StatusDown      Status = "down"
	StatusCancelled Status = "cancelled" // the run was interrupted mid-check
)

// END status OMIT

// START result OMIT
// Result is the report for one target. It is designed to be printed as a
// table row or serialised as one JSON line.
type Result struct {
	Index    int           `json:"index"`
	Target   string        `json:"target"`
	Kind     Kind          `json:"kind"`
	Status   Status        `json:"status"`
	Attempts int           `json:"attempts"`
	Latency  time.Duration `json:"latency_ns"`
	Detail   string        `json:"detail,omitempty"`
	Error    string        `json:"error,omitempty"`
}

// END result OMIT

// START config OMIT
// Config holds every knob that shapes a sweep's load on the outside world.
type Config struct {
	Concurrency int           // targets in flight across the whole run
	PerHost     int           // targets in flight against any single host
	Rate        float64       // attempts started per second; 0 = unlimited
	Timeout     time.Duration // bound on each individual attempt
	Retry       retry.Policy
	Probers     map[Kind]Prober
}

// Runner executes sweeps. It is safe for concurrent use.
type Runner struct {
	cfg     Config
	limiter *rate.Limiter
	hosts   *conc.KeyedSemaphore
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
	check(cfg.PerHost >= 1, "per-host limit must be >= 1, got %d", cfg.PerHost)
	check(cfg.Timeout > 0, "timeout must be positive, got %s", cfg.Timeout)
	check(cfg.Rate >= 0, "rate must be >= 0, got %g", cfg.Rate)
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}

	limit, burst := rate.Inf, 0
	if cfg.Rate > 0 {
		limit, burst = rate.Limit(cfg.Rate), max(1, int(cfg.Rate/10))
	}
	return &Runner{
		cfg:     cfg,
		limiter: rate.NewLimiter(limit, burst),
		hosts:   conc.NewKeyedSemaphore(cfg.PerHost),
	}, nil
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

// START check OMIT
// errAttemptTimeout is the cancellation cause of a single timed-out attempt,
// distinguishing "this target is slow" from "the user pressed Ctrl-C".
var errAttemptTimeout = errors.New("attempt timed out")

func (r *Runner) check(ctx context.Context, t Target) Result {
	res := Result{Index: t.Index, Target: t.Raw, Kind: t.Kind}
	prober, ok := r.cfg.Probers[t.Kind]
	if !ok {
		res.Status = StatusDown
		res.Error = fmt.Sprintf("no prober for kind %q", t.Kind)
		return res
	}

	// Politeness first: wait for a slot on this host before doing anything.
	release, err := r.hosts.Acquire(ctx, t.Host())
	if err != nil {
		return cancelled(res, err)
	}
	defer release()

	err = r.cfg.Retry.Do(ctx, func(ctx context.Context) error {
		// Every attempt, including retries, spends from the global budget.
		if err := r.limiter.Wait(ctx); err != nil {
			return retry.Permanent(err) // ctx is done or its deadline is too near
		}
		res.Attempts++
		actx, cancel := context.WithTimeoutCause(ctx, r.cfg.Timeout,
			errAttemptTimeout)
		defer cancel()

		start := time.Now()
		detail, perr := prober.Probe(actx, t)
		res.Detail, res.Latency = detail, time.Since(start)
		if perr != nil && errors.Is(context.Cause(actx), errAttemptTimeout) {
			// The prober's own error just echoes the cause; say it once.
			return fmt.Errorf("%w after %s", errAttemptTimeout, r.cfg.Timeout)
		}
		return perr
	})

	switch {
	case err == nil:
		res.Status = StatusUp
	case ctx.Err() != nil: // the whole run was cancelled, not just this check
		return cancelled(res, context.Cause(ctx))
	default:
		res.Status, res.Error = StatusDown, rootMessage(err)
	}
	return res
}

func cancelled(res Result, cause error) Result {
	res.Status = StatusCancelled
	res.Error = cause.Error()
	return res
}

// rootMessage keeps the retry wrapper's attempt count but avoids repeating
// nested context noise in a one-line report.
func rootMessage(err error) string {
	if ex, ok := errors.AsType[*retry.ExhaustedError](err); ok {
		return fmt.Sprintf("%v (after %d attempts)", ex.Err, ex.Attempts)
	}
	return err.Error()
}

// END check OMIT
