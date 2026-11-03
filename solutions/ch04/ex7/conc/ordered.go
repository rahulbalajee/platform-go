package conc

import (
	"context"
	"iter"
	"sync"
)

// StreamOrdered is Stream with results in input order. Calls still run
// concurrently, at most limit at a time, and each result is yielded as soon
// as every result before it has been.
//
// A result that is ready but can't be yielded yet keeps its call's slot, so
// at most limit results are ever running or waiting: one slow item makes
// the stream wait rather than buffer the rest of the input. Early break and
// cancellation behave as for Stream.
func StreamOrdered[T, R any](ctx context.Context, in iter.Seq[T], limit int,
	fn func(context.Context, T) R) iter.Seq[R] {

	return func(yield func(R) bool) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()

		limit := max(limit, 1)
		sem := make(chan struct{}, limit)
		// One single-use channel per started call, queued in input order.
		// Each call holds a slot until its result is yielded, so at most
		// limit channels are queued and sending to pending never blocks.
		pending := make(chan chan R, limit)
		done := make(chan struct{})

		go func() { // producer: owns the workers and closes pending
			defer close(done)
			defer close(pending)
			var wg sync.WaitGroup
			for item := range in {
				select {
				case sem <- struct{}{}:
				case <-ctx.Done():
				}
				if ctx.Err() != nil {
					break
				}
				out := make(chan R, 1) // buffered: the worker never blocks
				pending <- out
				wg.Go(func() { out <- fn(ctx, item) })
			}
			wg.Wait()
		}()

		for out := range pending {
			r := <-out // waits for this item, whatever finished after it
			more := yield(r)
			<-sem // free the slot only once the result has been handed over
			if !more {
				cancel()
				break
			}
		}
		<-done // every goroutine has exited; nothing outlives the loop
	}
}
