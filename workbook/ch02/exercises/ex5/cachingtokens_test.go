package platformapi_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"platformapi"
)

// slowIssuer is an identity provider that takes delay to issue a token
// valid for an hour. Tokens are numbered: tok-1, tok-2, ...
func slowIssuer(fetches *atomic.Int32, delay time.Duration) func(
	context.Context) (string, time.Time, error) {

	return func(ctx context.Context) (string, time.Time, error) {
		n := fetches.Add(1)
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return "", time.Time{}, ctx.Err()
		}
		return fmt.Sprintf("tok-%d", n), time.Now().Add(time.Hour), nil
	}
}

func TestCachingTokenSourceSharesOneFetch(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fetches atomic.Int32
		ts := platformapi.NewCachingTokenSource(slowIssuer(&fetches, time.Second))
		var _ platformapi.TokenInvalidator = ts
		var wg sync.WaitGroup
		for range 100 {
			wg.Go(func() {
				if tok, err := ts.Token(t.Context()); err != nil || tok != "tok-1" {
					t.Errorf("Token = %q, %v; want tok-1", tok, err)
				}
			})
		}
		wg.Wait()
		if n := fetches.Load(); n != 1 {
			t.Errorf("100 concurrent callers caused %d fetches, want 1", n)
		}
	})
}

func TestCachingTokenSourceRefreshesBeforeExpiry(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fetches atomic.Int32
		ts := platformapi.NewCachingTokenSource(slowIssuer(&fetches, time.Second))
		for _, step := range []struct {
			after time.Duration
			want  string
		}{
			{0, "tok-1"},                // fetched; valid for an hour
			{58 * time.Minute, "tok-1"}, // more than a minute left
			{2 * time.Minute, "tok-2"},  // less than a minute left: refresh
		} {
			time.Sleep(step.after)
			if tok, err := ts.Token(t.Context()); err != nil || tok != step.want {
				t.Errorf("after %v: Token = %q, %v; want %s",
					step.after, tok, err, step.want)
			}
		}
	})
}

func TestCachingTokenSourceIgnoresStaleInvalidations(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fetches atomic.Int32
		ts := platformapi.NewCachingTokenSource(slowIssuer(&fetches, time.Second))
		if tok, _ := ts.Token(t.Context()); tok != "tok-1" {
			t.Fatalf("first token %q", tok)
		}
		ts.InvalidateToken("tok-1")
		if tok, _ := ts.Token(t.Context()); tok != "tok-2" {
			t.Errorf("after invalidation: %q, want tok-2", tok)
		}
		ts.InvalidateToken("tok-1") // a late report about the old token
		if tok, _ := ts.Token(t.Context()); tok != "tok-2" {
			t.Errorf("after a stale invalidation: %q, want tok-2 still", tok)
		}
		if n := fetches.Load(); n != 2 {
			t.Errorf("fetched %d times, want 2", n)
		}
	})
}

func TestCachingTokenSourceDoesNotCacheErrors(t *testing.T) {
	calls := 0
	flaky := func(context.Context) (string, time.Time, error) {
		if calls++; calls == 1 {
			return "", time.Time{}, errors.New("identity provider unavailable")
		}
		return "tok-ok", time.Now().Add(time.Hour), nil
	}
	ts := platformapi.NewCachingTokenSource(flaky)
	if _, err := ts.Token(t.Context()); err == nil {
		t.Fatal("the first fetch failed, but Token returned no error")
	}
	if tok, err := ts.Token(t.Context()); err != nil || tok != "tok-ok" {
		t.Errorf("second Token = %q, %v; want a fresh fetch", tok, err)
	}
}

func TestWaitingCallerCanGiveUp(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fetches atomic.Int32
		ts := platformapi.NewCachingTokenSource(slowIssuer(&fetches, 10*time.Second))
		var wg sync.WaitGroup
		wg.Go(func() { // starts the slow fetch and waits it out
			if tok, err := ts.Token(t.Context()); tok != "tok-1" {
				t.Errorf("patient caller: %q, %v", tok, err)
			}
		})
		synctest.Wait() // the fetch is in flight
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		start := time.Now()
		_, err := ts.Token(ctx)
		if !errors.Is(err, context.DeadlineExceeded) ||
			time.Since(start) != time.Second {
			t.Errorf("impatient caller: %v after %v, want its own deadline at 1s",
				err, time.Since(start))
		}
		wg.Wait()
	})
}

func TestCachingTokenSourceWithTheClient(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fetches atomic.Int32
		ts := platformapi.NewCachingTokenSource(slowIssuer(&fetches, time.Second))
		client, fake := newClient(t, platformapi.WithTokenSource(ts))
		fake.RequireToken("tok-1")
		if _, err := client.GetService(t.Context(), "checkout"); err != nil {
			t.Fatal(err)
		}
		fake.RequireToken("tok-2") // credentials rotate on the server
		if _, err := client.GetService(t.Context(), "checkout"); err != nil {
			t.Fatalf("after rotation: %v", err)
		}
		if n := fetches.Load(); n != 2 {
			t.Errorf("fetched %d times, want 2", n)
		}
	})
}
