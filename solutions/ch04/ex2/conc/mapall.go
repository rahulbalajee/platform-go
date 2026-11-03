package conc

import (
	"context"
	"errors"
	"sync"
)

// MapAll calls fn for every item, running at most limit calls at once, and
// returns every result in input order together with every error.
//
// Unlike Map, MapAll is not fail-fast: a failed call does not cancel the
// others. The error is nil if every call succeeded; otherwise it joins the
// failures in input order, and the result of a failed item is R's zero
// value. Use it when partial results are worth having, for example reading
// the version of every cluster and listing the ones that didn't answer.
func MapAll[T, R any](ctx context.Context, items []T, limit int,
	fn func(context.Context, T) (R, error)) ([]R, error) {

	out := make([]R, len(items))
	errs := make([]error, len(items))
	sem := make(chan struct{}, max(limit, 1))
	var wg sync.WaitGroup
	for i, item := range items {
		sem <- struct{}{} // blocks while limit calls are running
		wg.Go(func() {
			defer func() { <-sem }()
			r, err := fn(ctx, item)
			if err != nil {
				errs[i] = err // each goroutine owns index i of both slices
				return
			}
			out[i] = r
		})
	}
	wg.Wait()
	return out, errors.Join(errs...) // nil if every element is nil
}
