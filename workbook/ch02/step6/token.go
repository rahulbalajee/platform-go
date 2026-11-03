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
