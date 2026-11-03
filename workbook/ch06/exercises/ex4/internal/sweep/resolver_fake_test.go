package sweep_test

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"sweep/internal/sweep"
)

// countingResolver is a fake DNS resolver: it knows a few names, takes
// 100ms to answer, and counts how often it was asked.
type countingResolver struct {
	addrs map[string][]string
	calls atomic.Int64
}

func (r *countingResolver) LookupHost(ctx context.Context, host string) (
	[]string, error) {

	r.calls.Add(1)
	select {
	case <-time.After(100 * time.Millisecond):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if addrs, ok := r.addrs[host]; ok {
		return addrs, nil
	}
	return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
}

func TestCachingResolverSharesOneLookup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		fake := &countingResolver{addrs: map[string][]string{
			"db.internal": {"10.0.3.7"},
		}}
		r := &sweep.CachingResolver{Resolver: fake, TTL: 30 * time.Second,
			Timeout: time.Second}
		lookup := func() {
			addrs, err := r.LookupHost(t.Context(), "db.internal")
			if err != nil || len(addrs) != 1 || addrs[0] != "10.0.3.7" {
				t.Errorf("LookupHost = %v, %v; want [10.0.3.7]", addrs, err)
			}
		}

		var wg sync.WaitGroup
		for range 50 {
			wg.Go(lookup)
		}
		wg.Wait()
		if n := fake.calls.Load(); n != 1 {
			t.Fatalf("50 concurrent lookups asked the resolver %d times, want 1", n)
		}
		time.Sleep(29 * time.Second) // still inside the TTL
		lookup()
		if n := fake.calls.Load(); n != 1 {
			t.Errorf("a lookup inside the TTL asked the resolver again (%d calls)", n)
		}
		time.Sleep(2 * time.Second) // the entry has expired
		lookup()
		if n := fake.calls.Load(); n != 2 {
			t.Errorf("after the TTL: %d calls, want 2", n)
		}
	})
}

func TestCachingResolverDialsTheResolvedAddress(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	_, port, _ := net.SplitHostPort(l.Addr().String())
	fake := &countingResolver{addrs: map[string][]string{
		"db.internal": {"127.0.0.1"},
	}}
	r := &sweep.CachingResolver{Resolver: fake, TTL: time.Minute, Timeout: time.Second}

	conn, err := r.DialContext(t.Context(), "tcp", net.JoinHostPort("db.internal", port))
	if err != nil {
		t.Fatalf("DialContext: %v", err)
	}
	conn.Close()
	_, err = r.DialContext(t.Context(), "tcp", net.JoinHostPort("nope.internal", port))
	if dnsErr, ok := errors.AsType[*net.DNSError](err); !ok || !dnsErr.IsNotFound {
		t.Errorf("unknown name: err = %v, want a not-found DNS error", err)
	}
	if n := fake.calls.Load(); n != 2 {
		t.Errorf("resolver calls = %d, want 2", n)
	}
}
