package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

// Exercise 3.5: a Retry-After header replaces the client's own backoff,
// and a wait that would outlast the context's deadline is not started.

// busy answers 503 with Retry-After: after, failing times, then 200.
func busy(t *testing.T, after string, failing int32) *httptest.Server {
	var calls atomic.Int32
	return httptest.NewTestServer(t, http.HandlerFunc(
		func(w http.ResponseWriter, _ *http.Request) {
			if calls.Add(1) <= failing {
				w.Header().Set("Retry-After", after)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			w.WriteHeader(http.StatusOK)
		}))
}

func testClient(srv *httptest.Server) *Client {
	return &Client{BaseURL: srv.URL, HTTP: srv.Client(), Attempts: 3,
		Backoff: 100 * time.Millisecond, Log: slog.New(slog.DiscardHandler)}
}

func TestRetryAfterReplacesTheBackoff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := testClient(busy(t, "2", 2))
		start := time.Now()
		if err := c.Deploy(t.Context(), "us-east-1", "checkout", "v1"); err != nil {
			t.Fatal(err)
		}
		if got := time.Since(start); got != 4*time.Second {
			t.Errorf("took %v, want exactly 4s: two waits of Retry-After: 2", got)
		}
	})
}

func TestRetryAfterBeyondTheDeadlineGivesUpAtOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := testClient(busy(t, "30", 3))
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		defer cancel()
		start := time.Now()
		err := c.Deploy(ctx, "us-east-1", "checkout", "v1")
		apiErr, ok := errors.AsType[*APIError](err)
		if !ok || apiErr.RetryAfter != 30*time.Second {
			t.Fatalf("err = %v, want an *APIError with RetryAfter 30s", err)
		}
		if got := time.Since(start); got != 0 {
			t.Errorf("waited %v before giving up; a 30s wait can't fit in 5s", got)
		}
	})
}
