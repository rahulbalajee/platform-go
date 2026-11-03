package platformapi

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"time"
)

// START operation OMIT

// Operation is a long-running server-side operation acting on a T, such as
// the rollout started by CreateDeployment. It is plain data: store its ID
// and resume later with Wait(ctx, &Operation[Deployment]{ID: id}).
type Operation[T any] struct {
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`    // e.g. "deployment.create"
	Done    bool            `json:"done"`    // no further changes
	Message string          `json:"message"` // progress, for humans
	Error   *OperationError `json:"error,omitempty"`
	Result  *T              `json:"result"` // latest state of the resource
}

// END operation OMIT

// START poll OMIT

// Poll returns an iterator over snapshots of op, fetched every poll
// interval (see WithPollInterval) until the operation is done. The last
// snapshot yielded has Done set. A failed fetch yields the error and ends
// the iteration; transient failures are retried first.
//
// Poll and Wait stop when ctx is done, but the operation itself continues
// on the server. To stop a deployment, call CancelDeployment.
func (c *Client) Poll[T any](ctx context.Context, op *Operation[T],
	opts ...CallOption) iter.Seq2[*Operation[T], error] {

	return func(yield func(*Operation[T], error) bool) {
		if op == nil || checkID("operation", op.ID) != nil {
			yield(nil, errors.New("platformapi: Poll: operation has no ID"))
			return
		}
		r := newRequest("GET", opts, "operations", op.ID)
		for {
			cur, err := c.call[*Operation[T]](ctx, r)
			if err != nil {
				yield(nil, err)
				return
			}
			if cur.Error != nil {
				cur.Error.OperationID = cur.ID
			}
			if !yield(cur, nil) || cur.Done {
				return
			}
			if err := sleep(ctx, c.poll); err != nil {
				yield(nil, fmt.Errorf("platformapi: waiting for %s: %w", op.ID, err))
				return
			}
		}
	}
}

// END poll OMIT

// START wait OMIT

// Wait polls op until it is done and returns the final state of its
// resource. If the operation failed, Wait returns that final state too,
// with an *OperationError.
func (c *Client) Wait[T any](ctx context.Context, op *Operation[T],
	opts ...CallOption) (*T, error) {

	for cur, err := range c.Poll(ctx, op, opts...) {
		switch {
		case err != nil:
			return nil, err
		case cur.Done && cur.Error != nil:
			return cur.Result, cur.Error // not a nil *OperationError in an error
		case cur.Done:
			return cur.Result, nil
		}
	}
	return nil, fmt.Errorf("platformapi: operation %s: polling ended early", op.ID)
}

// END wait OMIT

// sleep waits for d or until ctx is done, whichever comes first.
func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return context.Cause(ctx)
	case <-t.C:
		return nil
	}
}
