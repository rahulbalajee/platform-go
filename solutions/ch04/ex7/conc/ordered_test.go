package conc_test

import (
	"context"
	"slices"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"sweep/conc"
)

func TestStreamOrderedYieldsInInputOrder(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		delays := []time.Duration{3 * time.Second, time.Second, 2 * time.Second}
		sleep := func(_ context.Context, d time.Duration) time.Duration {
			time.Sleep(d)
			return d
		}
		start := time.Now()
		var got []time.Duration
		ordered := conc.StreamOrdered(t.Context(), slices.Values(delays), 3, sleep)
		for d := range ordered {
			got = append(got, d)
		}
		if !slices.Equal(got, delays) {
			t.Errorf("order = %v, want input order %v", got, delays)
		}
		if el := time.Since(start); el != 3*time.Second {
			t.Errorf("took %v, want 3s: the calls must still run concurrently", el)
		}
	})
}

// A slow first item must not let the others run ahead without bound: a
// result that can't be yielded yet keeps its slot.
func TestStreamOrderedBoundsUnyieldedResults(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		delays := []time.Duration{10 * time.Second, time.Second, time.Second,
			time.Second, time.Second}
		var started atomic.Int64
		sleep := func(_ context.Context, d time.Duration) time.Duration {
			started.Add(1)
			time.Sleep(d)
			return d
		}
		var at5s atomic.Int64
		time.AfterFunc(5*time.Second, func() { at5s.Store(started.Load()) })

		var got []time.Duration
		ordered := conc.StreamOrdered(t.Context(), slices.Values(delays), 2, sleep)
		for d := range ordered {
			got = append(got, d)
		}
		if !slices.Equal(got, delays) {
			t.Errorf("order = %v, want input order %v", got, delays)
		}
		if n := at5s.Load(); n != 2 {
			t.Errorf("%d calls had started after 5s, want 2 (the limit)", n)
		}
	})
}

func TestStreamOrderedEarlyBreakCancelsAndWaits(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var started, finished atomic.Int64
		work := func(ctx context.Context, i int) int {
			started.Add(1)
			defer finished.Add(1)
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
			return i
		}
		items := slices.Values(make([]int, 100))
		n := 0
		for range conc.StreamOrdered(t.Context(), items, 8, work) {
			if n++; n == 3 {
				break
			}
		}
		if s, f := started.Load(), finished.Load(); s != f {
			t.Fatalf("started %d but finished %d: StreamOrdered returned "+
				"with work in flight", s, f)
		}
		if s := started.Load(); s >= 100 {
			t.Errorf("started %d calls; early break should stop new work", s)
		}
	})
}

func TestStreamOrderedParentCancelDeliversStartedResults(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		time.AfterFunc(1500*time.Millisecond, cancel) // "Ctrl-C" mid-run
		var started atomic.Int64
		work := func(ctx context.Context, i int) int {
			started.Add(1)
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
			return i
		}
		items := []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
		var got []int
		for i := range conc.StreamOrdered(ctx, slices.Values(items), 2, work) {
			got = append(got, i)
		}
		// Two calls finished at 1s, two more were cancelled at 1.5s, and
		// every started call is reported, in order.
		if want := []int{0, 1, 2, 3}; !slices.Equal(got, want) ||
			started.Load() != 4 {
			t.Errorf("got %v from %d started calls, want %v", got,
				started.Load(), want)
		}
	})
}
