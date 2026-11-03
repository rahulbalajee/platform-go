package retry_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"sweep/retry"
)

func TestDoStopsWithinMaxElapsed(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := retry.Policy{
			MaxAttempts: 100,
			BaseDelay:   time.Second,
			MaxDelay:    time.Second,
			MaxElapsed:  5 * time.Second,
		}
		calls := 0
		var lastEnd time.Time
		start := time.Now()
		err := p.Do(t.Context(), func(context.Context) error {
			calls++
			time.Sleep(500 * time.Millisecond) // each attempt takes 0.5s
			lastEnd = time.Now()
			return errFlaky
		})

		ex, ok := errors.AsType[*retry.ExhaustedError](err)
		if !ok || ex.Attempts != calls || !errors.Is(err, errFlaky) {
			t.Fatalf("err = %v, want ExhaustedError after %d attempts wrapping "+
				"the last error", err, calls)
		}
		// Attempt k starts by 1.5s*(k-1): at least four fit in five seconds.
		if calls < 4 {
			t.Errorf("gave up after %d attempts, want at least 4", calls)
		}
		// Never sleep past the budget, and never sleep just to give up. The
		// last attempt starts within the budget and takes its 0.5s.
		if el := time.Since(start); el > 5500*time.Millisecond {
			t.Errorf("Do returned after %v, want at most 5.5s", el)
		}
		if idle := time.Since(lastEnd); idle != 0 {
			t.Errorf("Do slept %v after the last attempt before giving up", idle)
		}
	})
}

func TestZeroMaxElapsedMeansNoLimit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := retry.Policy{MaxAttempts: 4, BaseDelay: time.Hour, MaxDelay: time.Hour}
		calls := 0
		_ = p.Do(t.Context(), func(context.Context) error {
			calls++
			return errFlaky
		})
		if calls != 4 {
			t.Errorf("calls = %d, want all 4 attempts", calls)
		}
	})
}
