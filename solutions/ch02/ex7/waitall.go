// START waitall OMIT

package platformapi

import (
	"context"
	"errors"
	"sync"
)

// WaitAll waits for every operation in ops, following at most limit of
// them at a time (limit < 1 means all at once). It returns the final
// state of each resource in the order of ops, and the errors of the
// operations that failed or could not be followed, joined in that order.
// One failure does not stop the others.
func (c *Client) WaitAll[T any](ctx context.Context, ops []*Operation[T],
	limit int, opts ...CallOption) ([]*T, error) {

	if limit < 1 || limit > len(ops) {
		limit = len(ops)
	}
	results := make([]*T, len(ops))
	errs := make([]error, len(ops))
	slots := make(chan struct{}, limit) // a semaphore: one token per Wait
	var wg sync.WaitGroup
	for i, op := range ops {
		wg.Go(func() {
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				errs[i] = context.Cause(ctx)
				return
			}
			defer func() { <-slots }()
			results[i], errs[i] = c.Wait(ctx, op, opts...)
		})
	}
	wg.Wait() // every goroutine has finished: none outlives the call
	return results, errors.Join(errs...)
}

// END waitall OMIT
