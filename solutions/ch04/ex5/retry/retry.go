// START head OMIT

// Package retry implements context-aware retries with capped exponential
// backoff and full jitter, the strategy that best spreads retry storms
// across a fleet of clients.
//
// Operations signal non-retryable failures with Permanent and can request a
// specific delay (for example from an HTTP Retry-After header) with After.
package retry

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"time"
)

// END head OMIT

// START policy OMIT

// Policy configures retries. The zero value is usable: 3 attempts, 100ms
// base delay, 5s cap, and every error retryable unless marked Permanent.
type Policy struct {
	MaxAttempts int           // total attempts, including the first
	BaseDelay   time.Duration // delay before the first retry (before jitter)
	MaxDelay    time.Duration // cap for any single delay

	// MaxElapsed, if positive, bounds the whole retry loop: Do gives up
	// rather than sleep past MaxElapsed after the first attempt started.
	// Zero means no limit beyond MaxAttempts.
	MaxElapsed time.Duration

	// Retryable classifies errors. nil means "retry anything not Permanent".
	Retryable func(error) bool

	// OnRetry, if set, is called before each sleep. Use it for logs/metrics.
	OnRetry func(attempt int, err error, delay time.Duration)
}

func (p Policy) withDefaults() Policy {
	if p.MaxAttempts <= 0 {
		p.MaxAttempts = 3
	}
	if p.BaseDelay <= 0 {
		p.BaseDelay = 100 * time.Millisecond
	}
	if p.MaxDelay <= 0 {
		p.MaxDelay = 5 * time.Second
	}
	return p
}

// END policy OMIT

// START do OMIT

// Do runs op until it succeeds, returns a non-retryable error, exhausts the
// attempt budget, or ctx is done. The error returned on exhaustion wraps the
// last error from op, so errors.Is/As see through it.
func (p Policy) Do(ctx context.Context, op func(context.Context) error) error {
	p = p.withDefaults()
	start := time.Now()
	var err error
	for attempt := 1; ; attempt++ {
		if err = op(ctx); err == nil {
			return nil
		}
		if ctx.Err() != nil { // the caller gave up; don't mistake it for a flaky op
			return fmt.Errorf("retry aborted after %d attempts: %w (last error: %w)",
				attempt, context.Cause(ctx), err)
		}
		if !p.shouldRetry(err) {
			return err // Permanent errors are transparent to errors.Is/As
		}
		if attempt >= p.MaxAttempts {
			return &ExhaustedError{Attempts: attempt, Err: err}
		}

		delay := p.backoff(attempt, err)
		if p.MaxElapsed > 0 && time.Since(start)+delay > p.MaxElapsed {
			// The next attempt would start after the budget: give up now
			// instead of sleeping only to give up.
			return &ExhaustedError{Attempts: attempt, Err: err}
		}
		if p.OnRetry != nil {
			p.OnRetry(attempt, err, delay)
		}
		t := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			t.Stop()
			// Report both why we stopped and what we were retrying.
			return fmt.Errorf("retry aborted after %d attempts: %w (last error: %w)",
				attempt, context.Cause(ctx), err)
		case <-t.C:
		}
	}
}

// END do OMIT

// START value OMIT

// Value is Do for operations that return a result. It is a generic method,
// which Go supports from 1.27 on, so call sites read naturally:
//
//	cfg, err := policy.Value(ctx, fetchConfig)
func (p Policy) Value[T any](ctx context.Context,
	op func(context.Context) (T, error)) (T, error) {

	var out T
	err := p.Do(ctx, func(ctx context.Context) error {
		v, err := op(ctx)
		if err == nil {
			out = v
		}
		return err
	})
	return out, err
}

// END value OMIT

// START backoff OMIT

// backoff returns the delay before retry number attempt (1-based) using
// "full jitter": a uniform random duration in [0, min(MaxDelay, Base*2^n)).
// An After error overrides the computed delay (still capped).
func (p Policy) backoff(attempt int, err error) time.Duration {
	if a, ok := errors.AsType[*afterError](err); ok {
		return min(a.delay, p.MaxDelay)
	}
	ceiling := p.MaxDelay
	if shift := attempt - 1; shift < 32 { // avoid overflow on huge attempt counts
		ceiling = min(p.BaseDelay<<shift, p.MaxDelay)
	}
	//nolint:gosec // G404: jitter needs spread, not unpredictability
	return rand.N(ceiling) + 1 // +1ns keeps the delay strictly positive
}

func (p Policy) shouldRetry(err error) bool {
	if _, ok := errors.AsType[*permanentError](err); ok {
		return false
	}
	if p.Retryable != nil {
		return p.Retryable(err)
	}
	return true
}

// END backoff OMIT

// START errors OMIT

// Permanent marks err as non-retryable. The wrapper is transparent: its
// message is err's message and errors.Is/As see through it.
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return &permanentError{err}
}

type permanentError struct{ err error }

func (e *permanentError) Error() string { return e.err.Error() }
func (e *permanentError) Unwrap() error { return e.err }

// After marks err as retryable after at least d, overriding backoff. Use it
// for HTTP 429/503 responses that carry Retry-After.
func After(d time.Duration, err error) error {
	return &afterError{delay: d, err: err}
}

type afterError struct {
	delay time.Duration
	err   error
}

func (e *afterError) Error() string { return e.err.Error() }
func (e *afterError) Unwrap() error { return e.err }

// ExhaustedError reports that every attempt failed.
type ExhaustedError struct {
	Attempts int
	Err      error // the last attempt's error
}

func (e *ExhaustedError) Error() string {
	return fmt.Sprintf("gave up after %d attempts: %v", e.Attempts, e.Err)
}
func (e *ExhaustedError) Unwrap() error { return e.Err }

// END errors OMIT
