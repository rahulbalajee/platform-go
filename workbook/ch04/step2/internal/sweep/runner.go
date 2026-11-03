// START imports OMIT

package sweep

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
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

// Config holds every knob that shapes a sweep's load on the outside world.
type Config struct {
	Timeout time.Duration // bound on each check
	HTTP    HTTPProber    // checks http:// and https:// targets
}

// Runner executes sweeps.
type Runner struct {
	cfg Config
}

// NewRunner validates cfg and returns a Runner.
func NewRunner(cfg Config) (*Runner, error) {
	if cfg.Timeout <= 0 {
		return nil, fmt.Errorf("timeout must be positive, got %s", cfg.Timeout)
	}
	return &Runner{cfg: cfg}, nil
}

// START run OMIT
// Run checks every target at the same time and sends each result on the
// returned channel as soon as it is ready. The channel is closed after the
// last result.
func (r *Runner) Run(ctx context.Context, targets []Target) <-chan Result {
	results := make(chan Result)
	var wg sync.WaitGroup
	for _, t := range targets {
		wg.Go(func() {
			results <- r.check(ctx, t)
		})
	}
	go func() {
		wg.Wait()      // every check has sent its result...
		close(results) // ...so closing can't race with a send
	}()
	return results
}

// END run OMIT

// START check OMIT
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

// END check OMIT
