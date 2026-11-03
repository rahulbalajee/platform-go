// START caching OMIT

package platformapi

import (
	"context"
	"sync"
	"time"
)

// CachingTokenSource caches a token from an identity provider until one
// minute before it expires. Concurrent callers share a single fetch. It
// implements TokenInvalidator, so a token the API rejects is replaced at
// once. It is safe for concurrent use.
type CachingTokenSource struct {
	fetch func(context.Context) (string, time.Time, error)

	mu        sync.Mutex // guards the fields below
	token     string
	refreshAt time.Time
	inflight  chan struct{} // non-nil while a fetch runs; closed when it ends
}

// NewCachingTokenSource returns a CachingTokenSource that calls fetch for
// a token and the time it expires.
func NewCachingTokenSource(
	fetch func(context.Context) (token string, expiry time.Time, err error),
) *CachingTokenSource {
	return &CachingTokenSource{fetch: fetch}
}

// END caching OMIT

// START token OMIT

// Token returns the cached token, or fetches a new one. Callers that
// arrive during a fetch wait for it, each until its own ctx is done.
func (s *CachingTokenSource) Token(ctx context.Context) (string, error) {
	for {
		s.mu.Lock()
		if s.token != "" && time.Now().Before(s.refreshAt) {
			tok := s.token
			s.mu.Unlock()
			return tok, nil
		}
		if wait := s.inflight; wait != nil {
			s.mu.Unlock()
			select {
			case <-wait: // look again: the fetch may have failed
				continue
			case <-ctx.Done():
				return "", context.Cause(ctx)
			}
		}
		done := make(chan struct{})
		s.inflight = done
		s.mu.Unlock()
		return s.refresh(ctx, done)
	}
}

// refresh runs one fetch and publishes its result. The lock is not held
// while fetch runs, so waiting callers are not stuck behind the network.
func (s *CachingTokenSource) refresh(ctx context.Context,
	done chan struct{}) (string, error) {

	tok, expiry, err := s.fetch(ctx)
	s.mu.Lock()
	if err == nil {
		s.token, s.refreshAt = tok, expiry.Add(-time.Minute)
	}
	s.inflight = nil
	s.mu.Unlock()
	close(done)
	if err != nil {
		return "", err
	}
	return tok, nil
}

// InvalidateToken drops the cached token if it is still the rejected one.
// A rejection reported after a refresh is ignored.
func (s *CachingTokenSource) InvalidateToken(rejected string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token == rejected {
		s.token = ""
	}
}

// END token OMIT
