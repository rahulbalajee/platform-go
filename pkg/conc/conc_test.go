package conc_test

import (
	"context"
	"errors"
	"slices"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"go.uber.org/goleak"

	"github.com/rahulbalajee/platform-go/pkg/conc"
)

// TestMain fails the package if any test leaves a goroutine behind.
func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }

func TestMapPreservesOrderAndBoundsConcurrency(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var inFlight, peak atomic.Int64
		items := []int{5, 1, 4, 2, 3}

		got, err := conc.Map(t.Context(), items, 2, func(ctx context.Context, n int) (int, error) {
			cur := inFlight.Add(1)
			defer inFlight.Add(-1)
			for { // record the high-water mark
				p := peak.Load()
				if cur <= p || peak.CompareAndSwap(p, cur) {
					break
				}
			}
			time.Sleep(time.Duration(n) * time.Second) // virtual time: instant
			return n * n, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if want := []int{25, 1, 16, 4, 9}; !slices.Equal(got, want) {
			t.Errorf("Map = %v, want %v", got, want)
		}
		if p := peak.Load(); p != 2 {
			t.Errorf("peak concurrency = %d, want 2", p)
		}
	})
}

func TestMapFailFastCancelsSiblings(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		boom := errors.New("boom")
		var cancelled atomic.Int64

		_, err := conc.Map(t.Context(), []int{1, 2, 3, 4}, 4, func(ctx context.Context, n int) (int, error) {
			if n == 1 {
				// Fail only after every sibling is running and blocked.
				time.Sleep(time.Second)
				return 0, boom
			}
			select {
			case <-ctx.Done():
				cancelled.Add(1)
				return 0, ctx.Err()
			case <-time.After(time.Hour):
				return n, nil
			}
		})
		if !errors.Is(err, boom) {
			t.Fatalf("err = %v, want boom", err)
		}
		if c := cancelled.Load(); c != 3 {
			t.Errorf("cancelled siblings = %d, want 3", c)
		}
	})
}

func TestStreamYieldsInCompletionOrder(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		delays := []time.Duration{3 * time.Second, 1 * time.Second, 2 * time.Second}
		var got []time.Duration
		for d := range conc.Stream(t.Context(), slices.Values(delays), 3,
			func(ctx context.Context, d time.Duration) time.Duration {
				time.Sleep(d)
				return d
			}) {
			got = append(got, d)
		}
		want := []time.Duration{time.Second, 2 * time.Second, 3 * time.Second}
		if !slices.Equal(got, want) {
			t.Errorf("order = %v, want %v", got, want)
		}
	})
}

func TestStreamEarlyBreakCancelsAndWaits(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var started, finished atomic.Int64
		items := slices.Values(make([]int, 100))

		n := 0
		for range conc.Stream(t.Context(), items, 8, func(ctx context.Context, _ int) int {
			started.Add(1)
			defer finished.Add(1)
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
			return 0
		}) {
			if n++; n == 3 {
				break
			}
		}
		// Stream must not return while workers are still running.
		if s, f := started.Load(), finished.Load(); s != f {
			t.Fatalf("started %d but finished %d: Stream returned with work in flight", s, f)
		}
		if s := started.Load(); s >= 100 {
			t.Errorf("started %d calls; early break should stop new work", s)
		}
	})
}

func TestStreamParentCancelStillDeliversStartedResults(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		var started atomic.Int64
		go func() {
			time.Sleep(1500 * time.Millisecond) // "Ctrl-C" mid-run
			cancel()
		}()

		got := 0
		for range conc.Stream(ctx, slices.Values(make([]int, 10)), 2,
			func(ctx context.Context, i int) int {
				started.Add(1)
				select {
				case <-ctx.Done():
				case <-time.After(time.Second):
				}
				return i
			}) {
			got++
		}
		// Two calls finished at 1s; the next two were cancelled in flight at
		// 1.5s; nothing else may start. Every started call must be reported.
		if s := started.Load(); int64(got) != s || s != 4 {
			t.Errorf("yielded %d results for %d started calls, want 4 and 4", got, s)
		}
	})
}

func TestKeyedSemaphoreLimitsPerKey(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		sem := conc.NewKeyedSemaphore(2)
		ctx := t.Context()

		relA1, _ := sem.Acquire(ctx, "a")
		relA2, _ := sem.Acquire(ctx, "a")
		relB1, err := sem.Acquire(ctx, "b") // other keys are independent
		if err != nil {
			t.Fatal(err)
		}

		acquired := make(chan struct{})
		go func() {
			rel, err := sem.Acquire(ctx, "a") // third holder of "a" must wait
			if err == nil {
				close(acquired)
				rel()
			}
		}()
		synctest.Wait()
		select {
		case <-acquired:
			t.Fatal("third acquire of key a did not block")
		default:
		}

		relA1()
		synctest.Wait()
		select {
		case <-acquired:
		default:
			t.Fatal("waiter not woken after release")
		}
		relA2()
		relA1() // double release is a no-op
		relB1()
		synctest.Wait()
		if n := sem.Len(); n != 0 {
			t.Errorf("Len = %d after all releases, want 0 (idle keys must be freed)", n)
		}
	})
}

func TestKeyedSemaphoreHonoursContext(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		sem := conc.NewKeyedSemaphore(1)
		rel, _ := sem.Acquire(t.Context(), "k")
		defer rel()

		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		defer cancel()
		start := time.Now()
		if _, err := sem.Acquire(ctx, "k"); !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("err = %v, want DeadlineExceeded", err)
		}
		if el := time.Since(start); el != 5*time.Second {
			t.Errorf("gave up after %v, want exactly 5s of virtual time", el)
		}
	})
}
