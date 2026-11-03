// START head OMIT

package sweep

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

// CachingResolver deduplicates and caches DNS lookups. Sweeping 500 URLs on
// 20 hosts should cost 20 lookups, not 500, and must not hammer the resolver
// when hundreds of goroutines ask for the same name in the same millisecond.
type CachingResolver struct {
	Resolver *net.Resolver
	TTL      time.Duration
	Timeout  time.Duration // bound for a shared lookup, independent of callers

	group singleflight.Group
	mu    sync.Mutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	addrs   []string
	expires time.Time
}

// END head OMIT

// START lookup OMIT
// LookupHost returns cached addresses or performs one shared lookup for all
// concurrent callers of the same host.
func (r *CachingResolver) LookupHost(ctx context.Context, host string) (
	[]string, error) {

	if addrs, ok := r.cached(host); ok {
		return addrs, nil
	}
	// The shared lookup must not inherit any single caller's cancellation:
	// if the first caller gives up, everyone else waiting would fail too.
	// Detach it, bound it with its own timeout, and let each caller wait
	// only as long as its own context allows.
	ch := r.group.DoChan(host, func() (any, error) {
		lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), r.Timeout)
		defer cancel()
		addrs, err := r.Resolver.LookupHost(lctx, host)
		if err == nil {
			r.store(host, addrs)
		}
		return addrs, err
	})
	select {
	case res := <-ch:
		if res.Err != nil {
			return nil, res.Err
		}
		return res.Val.([]string), nil
	case <-ctx.Done():
		return nil, context.Cause(ctx)
	}
}

// END lookup OMIT

// START cache OMIT
func (r *CachingResolver) cached(host string) ([]string, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.cache[host]
	if !ok || time.Now().After(e.expires) {
		return nil, false
	}
	return e.addrs, true
}

func (r *CachingResolver) store(host string, addrs []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cache == nil {
		r.cache = make(map[string]cacheEntry)
	}
	r.cache[host] = cacheEntry{addrs: addrs, expires: time.Now().Add(r.TTL)}
}

// END cache OMIT

// START dial OMIT
// DialContext dials addr ("host:port") using cached resolution, trying each
// address in turn. It has the signature http.Transport.DialContext expects.
func (r *CachingResolver) DialContext(ctx context.Context, network, addr string) (
	net.Conn, error) {

	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	var d net.Dialer
	if net.ParseIP(host) != nil {
		return d.DialContext(ctx, network, addr)
	}
	addrs, err := r.LookupHost(ctx, host)
	if err != nil {
		return nil, err
	}
	var errs []error
	for _, ip := range addrs {
		conn, err := d.DialContext(ctx, network, net.JoinHostPort(ip, port))
		if err == nil {
			return conn, nil
		}
		errs = append(errs, err)
		if ctx.Err() != nil {
			break
		}
	}
	return nil, errors.Join(errs...)
}

// END dial OMIT
