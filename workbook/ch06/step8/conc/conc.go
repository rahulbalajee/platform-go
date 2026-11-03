// START head OMIT

// Package conc provides small, leak-free concurrency building blocks for
// platform tooling.
//
// Every helper in this package follows the same contract: when it returns,
// every goroutine it started has exited. Callers never need to "wait a bit"
// for background work to drain.
package conc

import (
	"context"
	"iter"
	"sync"

	"golang.org/x/sync/errgroup"
)

// END head OMIT

// START map OMIT

// Map calls fn for every item, running at most limit calls at once, and
// returns the results in input order.
//
// Map is fail-fast: the first error cancels the context passed to the calls
// still in flight, no new calls are started, and that first error is
// returned. Use it when the caller needs all results or none, for example
// fetching the config of every cluster before rendering a fleet-wide diff.
func Map[T, R any](ctx context.Context, items []T, limit int,
	fn func(context.Context, T) (R, error)) ([]R, error) {

	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(max(limit, 1))

	out := make([]R, len(items))
	for i, item := range items {
		if ctx.Err() != nil {
			break // a call already failed; don't start new work
		}
		g.Go(func() error { // blocks while limit calls are running
			r, err := fn(ctx, item)
			if err != nil {
				return err
			}
			out[i] = r // each goroutine owns exactly one index: no lock needed
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return out, nil
}

// END map OMIT

// START stream OMIT

// Stream calls fn for every value produced by in, running at most limit calls
// at once, and yields each result as soon as it is ready (completion order,
// not input order).
//
// Stream never stops because an individual call "failed": fn reports
// failures inside R. That is the right shape for fleet operations, where one
// unhealthy target is data, not a reason to abort.
//
// If the consumer stops early (break out of the range loop), Stream cancels
// the context passed to in-flight calls and waits for every goroutine to
// exit before returning control to the caller. If ctx itself is cancelled,
// Stream stops starting new calls but still yields the result of every call
// it already started, so callers can report partial progress accurately.
// in is consumed on a separate goroutine and must not block indefinitely.
func Stream[T, R any](ctx context.Context, in iter.Seq[T], limit int,
	fn func(context.Context, T) R) iter.Seq[R] {

	return func(yield func(R) bool) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()

		// Unbuffered: a slow consumer slows the producers (backpressure).
		results := make(chan R)
		consumerGone := make(chan struct{}) // closed when yield returns false
		done := make(chan struct{})

		go func() { // producer: owns the workers and closes results
			defer close(done)
			defer close(results)

			// A channel semaphore rather than errgroup.SetLimit: g.Go blocks
			// without watching ctx, so after cancellation it would still
			// launch one more call once a slot frees up.
			sem := make(chan struct{}, max(limit, 1))
			var wg sync.WaitGroup
			for item := range in {
				select {
				case sem <- struct{}{}:
				case <-ctx.Done():
				}
				if ctx.Err() != nil {
					break
				}
				wg.Go(func() {
					defer func() { <-sem }()
					r := fn(ctx, item)
					select {
					case results <- r:
					case <-consumerGone: // nobody is listening; drop it
					}
				})
			}
			wg.Wait()
		}()

		for r := range results {
			if !yield(r) {
				close(consumerGone) // workers stop trying to send...
				cancel()            // ...and in-flight calls are cancelled
				break
			}
		}
		<-done // every goroutine has exited; nothing outlives the loop
	}
}

// END stream OMIT
