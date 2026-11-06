// START head OMIT

package platformapi_test

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// END head OMIT

// START retrytest OMIT

func TestRetriesReuseTheIdempotencyKey(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.FailNext(2, http.StatusServiceUnavailable, 0)

		op, err := client.CreateDeployment(t.Context(), staging)
		if err != nil {
			t.Fatal(err)
		}
		reqs := fake.Requests()
		if len(reqs) != 3 {
			t.Fatalf("got %d requests, want 3 (two 503s, then success)", len(reqs))
		}
		for _, r := range reqs[1:] {
			if r.IdempotencyKey != reqs[0].IdempotencyKey ||
				r.RequestID != reqs[0].RequestID {
				t.Errorf("attempt sent key %q, request %q; want %q, %q",
					r.IdempotencyKey, r.RequestID,
					reqs[0].IdempotencyKey, reqs[0].RequestID)
			}
		}
		if op.ID == "" || op.Result.State != platformapi.StatePending {
			t.Errorf("operation = %+v, want a pending deployment", op)
		}
	})
}

// END retrytest OMIT

// START retryafter OMIT

func TestRetryAfterIsHonoured(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		policy := retry.Policy{MaxAttempts: 3, MaxDelay: time.Minute}
		client, fake := newClient(t, platformapi.WithRetry(policy))
		fake.FailNext(1, http.StatusTooManyRequests, 7*time.Second)

		start := time.Now()
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
		if el := time.Since(start); el != 7*time.Second {
			t.Errorf("retried after %v of virtual time, want exactly 7s", el)
		}
	})
}

// END retryafter OMIT

// START permanent OMIT

func TestClientErrorsAreNotRetried(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.GetDeployment(t.Context(), "d-404")
	if !errors.Is(err, platformapi.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	if n := len(fake.Requests()); n != 1 {
		t.Errorf("sent %d requests, want 1: a 404 is not retryable", n)
	}
}

func TestRetriesGiveUp(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		client, fake := newClient(t)
		fake.FailNext(10, http.StatusBadGateway, 0)
		_, err := client.GetEnvironment(t.Context(), "dev")
		if _, ok := errors.AsType[*retry.ExhaustedError](err); !ok {
			t.Fatalf("err = %v, want *retry.ExhaustedError", err)
		}
		if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
			apiErr.StatusCode != http.StatusBadGateway {
			t.Errorf("err = %v, want the last 502 in the chain", err)
		}
		if n := len(fake.Requests()); n != 4 {
			t.Errorf("sent %d requests, want the default 4 attempts", n)
		}
	})
}

// END permanent OMIT

// START caching OMIT

// cachingTokens caches one token and counts how often it is invalidated.
type cachingTokens struct {
	mu          sync.Mutex
	cached      string
	issue       func() string
	invalidated atomic.Int32
}

func (c *cachingTokens) Token(context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached == "" {
		c.cached = c.issue()
	}
	return c.cached, nil
}

func (c *cachingTokens) InvalidateToken(rejected string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cached == rejected { // another request may have refreshed it already
		c.cached = ""
		c.invalidated.Add(1)
	}
}

// END caching OMIT

// START rotation OMIT

func TestRejectedTokenIsRefreshedOnce(t *testing.T) {
	current := "token-1"
	tokens := &cachingTokens{issue: func() string { return current }}
	client, fake := newClient(t, platformapi.WithTokenSource(tokens))
	fake.RequireToken("token-1")
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatal(err)
	}

	current = "token-2" // the identity provider rotates credentials
	fake.RequireToken("token-2")
	if _, err := client.GetService(t.Context(), "checkout"); err != nil {
		t.Fatalf("after rotation: %v", err)
	}
	if n := tokens.invalidated.Load(); n != 1 {
		t.Errorf("invalidated %d times, want 1", n)
	}

	fake.RequireToken("token-3") // a token the source will never issue
	_, err := client.GetService(t.Context(), "checkout")
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
		apiErr.StatusCode != http.StatusUnauthorized {
		t.Errorf("err = %v, want a 401 after one refresh attempt", err)
	}
}

func TestLimiterGatesEveryAttempt(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		lim := &countingLimiter{}
		client, fake := newClient(t, platformapi.WithLimiter(lim))
		fake.FailNext(2, http.StatusServiceUnavailable, 0)
		if _, err := client.GetEnvironment(t.Context(), "dev"); err != nil {
			t.Fatal(err)
		}
		if n := lim.waits.Load(); n != 3 {
			t.Errorf("limiter consulted %d times, want once per attempt (3)", n)
		}
	})
}

// END rotation OMIT
