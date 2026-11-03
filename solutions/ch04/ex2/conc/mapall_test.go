package conc_test

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"sweep/conc"
)

func TestMapAllCollectsEveryError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		errOdd := errors.New("odd")
		var inFlight, peak atomic.Int64
		fn := func(ctx context.Context, n int) (int, error) {
			cur := inFlight.Add(1)
			defer inFlight.Add(-1)
			for {
				p := peak.Load()
				if cur <= p || peak.CompareAndSwap(p, cur) {
					break
				}
			}
			time.Sleep(time.Second)
			if err := ctx.Err(); err != nil {
				return 0, err // a sibling's failure must not cancel this call
			}
			if n%2 == 1 {
				return 0, fmt.Errorf("item %d: %w", n, errOdd)
			}
			return n * 10, nil
		}

		start := time.Now()
		got, err := conc.MapAll(t.Context(), []int{1, 2, 3, 4, 5}, 2, fn)
		if want := []int{0, 20, 0, 40, 0}; !slices.Equal(got, want) {
			t.Errorf("results = %v, want %v", got, want)
		}
		if !errors.Is(err, errOdd) {
			t.Fatalf("err = %v, want it to wrap every failure", err)
		}
		want := "item 1: odd\nitem 3: odd\nitem 5: odd"
		if err.Error() != want {
			t.Errorf("err = %q, want the failures in input order: %q", err, want)
		}
		if p := peak.Load(); p != 2 {
			t.Errorf("peak concurrency = %d, want 2", p)
		}
		// Five one-second calls, two at a time: three rounds.
		if el := time.Since(start); el != 3*time.Second {
			t.Errorf("took %v, want 3s", el)
		}
	})
}

func TestMapAllReturnsNilWhenEverythingSucceeds(t *testing.T) {
	double := func(_ context.Context, n int) (int, error) { return 2 * n, nil }
	got, err := conc.MapAll(t.Context(), []int{1, 2, 3}, 0, double)
	if err != nil {
		t.Fatalf("err = %#v, want nil", err)
	}
	if want := []int{2, 4, 6}; !slices.Equal(got, want) {
		t.Errorf("results = %v, want %v", got, want)
	}
}
