// START types OMIT

package sweep

import (
	"context"
	"fmt"
	"time"
)

// Status is the outcome of checking one target.
type Status string

const (
	StatusUp   Status = "up"
	StatusDown Status = "down"
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

// END types OMIT

// START config OMIT
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

// END config OMIT

// START run OMIT
// Run checks every target, one after another, and returns the results in
// input order.
func (r *Runner) Run(ctx context.Context, targets []Target) []Result {
	results := make([]Result, 0, len(targets))
	for _, t := range targets {
		results = append(results, r.check(ctx, t))
	}
	return results
}

// END run OMIT

// START check OMIT
func (r *Runner) check(ctx context.Context, t Target) Result {
	res := Result{Index: t.Index, Target: t.Raw, Kind: t.Kind}
	ctx, cancel := context.WithTimeout(ctx, r.cfg.Timeout)
	defer cancel()

	start := time.Now()
	detail, err := r.cfg.HTTP.Probe(ctx, t)
	res.Detail, res.Latency = detail, time.Since(start)
	if err != nil {
		res.Status, res.Error = StatusDown, err.Error()
		return res
	}
	res.Status = StatusUp
	return res
}

// END check OMIT
