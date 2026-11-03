// START token OMIT

package platformapi

import (
	"context"
	"errors"
)

// TokenSource supplies the bearer token for a request. The client calls
// Token before every attempt, so implementations should cache tokens and
// must be safe for concurrent use.
type TokenSource interface {
	Token(ctx context.Context) (string, error)
}

// TokenSourceFunc adapts an ordinary function to a TokenSource.
type TokenSourceFunc func(ctx context.Context) (string, error)

// Token calls f(ctx).
func (f TokenSourceFunc) Token(ctx context.Context) (string, error) { return f(ctx) }

// StaticToken returns a TokenSource that always returns token.
func StaticToken(token string) TokenSource {
	return TokenSourceFunc(func(context.Context) (string, error) {
		if token == "" {
			return "", errors.New("platformapi: empty static token")
		}
		return token, nil
	})
}

// END token OMIT

// START invalidator OMIT

// TokenInvalidator is an optional interface for a TokenSource that caches
// tokens. When the API rejects a token with 401 Unauthorized, the client
// calls InvalidateToken with the rejected token and retries the request
// once with a fresh one. Implementations should drop their cached token
// only if it is still the rejected one: concurrent requests may report
// the same rejection after the token has already been refreshed.
//
// The method is on a separate interface so that TokenSource
// implementations written before it existed still compile and work.
type TokenInvalidator interface {
	InvalidateToken(rejected string)
}

// END invalidator OMIT
