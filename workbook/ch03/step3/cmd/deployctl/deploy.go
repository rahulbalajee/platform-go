// START imports OMIT
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"sync"
	"time"
)

// END imports OMIT

// START result OMIT
// result is the outcome for one target.
type result struct {
	Target string
	Took   time.Duration
	Err    error
}

// END result OMIT
// START deploy OMIT
func deploy(ctx context.Context, g globals, args []string,
	getenv func(string) string, stdout io.Writer) error {

	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	parallel := fs.Int("parallel", 4, "targets deployed at once")
	only := fs.String("only", "", "comma-separated subset of targets")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("deploy needs one VERSION, got %d arguments", fs.NArg())
	}
	if *parallel < 1 {
		return errors.New("-parallel must be at least 1")
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

	client := newClient(cfg, getenv)
	if err := client.checkAuth(ctx); err != nil {
		return err
	}
	return rollout(ctx, client, cfg.Service, version, targets, *parallel, stdout)
}

// END deploy OMIT
// START rollout OMIT
// rollout deploys to every target, at most parallel at a time, prints each
// result as it arrives, and returns one error describing all failures.
func rollout(ctx context.Context, c *Client, service, version string,
	targets []string, parallel int, stdout io.Writer) error {

	fmt.Fprintf(stdout, "deploying %s %s to %d targets\n",
		service, version, len(targets))
	results := make(chan result)
	go func() { // starts the workers in order, then closes results
		slots := make(chan struct{}, parallel) // a worker holds a slot
		var wg sync.WaitGroup
		for _, target := range targets {
			slots <- struct{}{} // wait for a free slot before starting
			wg.Go(func() {
				defer func() { <-slots }()
				results <- deployOne(ctx, c, target, service, version)
			})
		}
		wg.Wait() // every worker has sent its result...
		close(results)
	}()

	var failed []error
	for r := range results { // only this loop touches failed
		if r.Err != nil {
			r.Err = fmt.Errorf("%s: %w", r.Target, r.Err)
			failed = append(failed, r.Err)
		}
		printResult(stdout, r)
	}
	if len(failed) == 0 {
		return nil
	}
	return fmt.Errorf("deploy of %s failed on %d of %d targets: %w",
		version, len(failed), len(targets), errors.Join(failed...))
}

// END rollout OMIT
// START deployone OMIT
// deployOne deploys one target and times it.
func deployOne(ctx context.Context, c *Client, target, service,
	version string) result {

	start := time.Now()
	err := c.Deploy(ctx, target, service, version)
	return result{Target: target, Took: elapsed(start), Err: err}
}

// END deployone OMIT
// START print OMIT
func printResult(w io.Writer, r result) {
	status := "deployed"
	if r.Err != nil {
		status = "failed"
	}
	fmt.Fprintf(w, "  %-11s %-8s %s\n", r.Target, status, r.Took)
}

// END print OMIT
