// Package sweeptest provides a fake fleet of HTTP endpoints for testing
// sweep and the tools built on it, in the spirit of net/http/httptest.
package sweeptest

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// START fleet OMIT
// Fleet is an http.Handler with one path per behaviour a health checker
// must classify correctly:
//
//	/ok       200 OK
//	/flaky    502 for the first two requests, then 200
//	/down     503 Service Unavailable, every time
//	/missing  404 Not Found
//	/slow     no answer until the client gives up (at most SlowFor)
//
// It counts requests per path, so tests can assert on traffic and wait
// for a request to arrive instead of sleeping.
type Fleet struct {
	SlowFor time.Duration // how long /slow stalls; zero means one minute

	mu     sync.Mutex
	hits   map[string]int
	notify chan struct{} // closed and replaced on every request
}

// NewFleet returns a ready-to-serve Fleet.
func NewFleet() *Fleet {
	return &Fleet{hits: map[string]int{}, notify: make(chan struct{})}
}

func (f *Fleet) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	n := f.record(r.URL.Path)
	switch r.URL.Path {
	case "/ok":
		_, _ = w.Write([]byte("ok\n"))
	case "/flaky":
		if n <= 2 {
			http.Error(w, "warming up", http.StatusBadGateway)
		}
	case "/down":
		http.Error(w, "maintenance", http.StatusServiceUnavailable)
	case "/slow":
		stall := f.SlowFor
		if stall == 0 {
			stall = time.Minute
		}
		select {
		case <-time.After(stall):
		case <-r.Context().Done():
		}
	default:
		http.NotFound(w, r)
	}
}

// END fleet OMIT

func (f *Fleet) record(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hits[path]++
	close(f.notify)
	f.notify = make(chan struct{})
	return f.hits[path]
}

// Hits returns how many requests path has received.
func (f *Fleet) Hits(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

// WaitFor blocks until path has received at least n requests or ctx is done.
func (f *Fleet) WaitFor(ctx context.Context, path string, n int) error {
	for {
		f.mu.Lock()
		got, changed := f.hits[path], f.notify
		f.mu.Unlock()
		if got >= n {
			return nil
		}
		select {
		case <-changed:
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
}

// NewServer starts a Fleet on a real loopback socket, for tests that run
// separate processes, and closes it when the test ends.
func NewServer(t testing.TB) (*httptest.Server, *Fleet) {
	t.Helper()
	f := NewFleet()
	srv := httptest.NewServer(f)
	t.Cleanup(func() {
		srv.CloseClientConnections() // unblock any /slow handlers
		srv.Close()
	})
	return srv, f
}
