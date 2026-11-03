// START imports OMIT

package platformapi

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// sdkVersion is appended to every User-Agent so the platform team can see
// which SDK versions are still in use before removing anything.
const sdkVersion = "1.0.0"

// END imports OMIT

// START client OMIT

// Client calls the platform API. Create it with New; the zero value is not
// usable. A Client is safe for concurrent use and should be reused: it
// holds no per-call state, and its *http.Client pools connections.
type Client struct {
	base *url.URL
	config
}

// config holds everything an Option may change. Options cannot reach it
// after New returns, so a shared Client is never reconfigured under load.
type config struct {
	hc        *http.Client
	tokens    TokenSource // nil: send no Authorization header
	limiter   Limiter     // nil: no client-side rate limit
	userAgent string
	log       *slog.Logger
	poll      time.Duration
}

// END client OMIT

// START option OMIT

// An Option configures a Client. Options are applied in order, so a later
// option overrides an earlier one.
type Option func(*config) error

// New returns a Client for the API at baseURL, for example
// "https://platform.internal". It validates baseURL and every option and
// reports all problems at once. New performs no I/O.
func New(baseURL string, opts ...Option) (*Client, error) {
	cfg := config{
		hc:        &http.Client{}, // no Client.Timeout: contexts own deadlines
		userAgent: "platformapi-go/" + sdkVersion,
		log:       slog.New(slog.DiscardHandler),
		poll:      2 * time.Second,
	}
	var errs []error
	base, err := parseBaseURL(baseURL)
	if err != nil {
		errs = append(errs, err)
	}
	for _, opt := range opts {
		if err := opt(&cfg); err != nil {
			errs = append(errs, err)
		}
	}
	if err := errors.Join(errs...); err != nil {
		return nil, fmt.Errorf("platformapi.New: %w", err)
	}
	return &Client{base: base, config: cfg}, nil
}

// END option OMIT

func parseBaseURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	switch {
	case err != nil:
		return nil, fmt.Errorf("base URL: %w", err)
	case u.Scheme != "http" && u.Scheme != "https":
		return nil, fmt.Errorf("base URL %q: scheme must be http or https", raw)
	case u.Host == "":
		return nil, fmt.Errorf("base URL %q: missing host", raw)
	case u.RawQuery != "" || u.Fragment != "":
		return nil, fmt.Errorf("base URL %q: must not have a query or fragment", raw)
	}
	u.Path = strings.TrimSuffix(u.Path, "/")
	return u, nil
}

// START options OMIT

// WithHTTPClient sets the *http.Client used for requests. Use it to add
// tracing or metrics with a wrapping http.RoundTripper, or to set TLS
// options. Its Timeout should be zero; use contexts for deadlines.
func WithHTTPClient(hc *http.Client) Option {
	return func(c *config) error {
		if hc == nil {
			return errors.New("WithHTTPClient: nil *http.Client")
		}
		c.hc = hc
		return nil
	}
}

// WithUserAgent prefixes the User-Agent header with product, for example
// "ship/2.3.0", so the platform team can tell callers apart in its logs.
func WithUserAgent(product string) Option {
	return func(c *config) error {
		if product == "" || strings.ContainsAny(product, "\r\n") {
			return fmt.Errorf("WithUserAgent: invalid product %q", product)
		}
		c.userAgent = product + " platformapi-go/" + sdkVersion
		return nil
	}
}

// END options OMIT

// START tokenoptions OMIT

// WithTokenSource authenticates every request with a bearer token from ts.
func WithTokenSource(ts TokenSource) Option {
	return func(c *config) error {
		if ts == nil {
			return errors.New("WithTokenSource: nil TokenSource")
		}
		c.tokens = ts
		return nil
	}
}

// WithToken authenticates every request with a fixed bearer token. It is
// shorthand for WithTokenSource(StaticToken(token)).
func WithToken(token string) Option {
	return func(c *config) error {
		if token == "" {
			return errors.New("WithToken: empty token")
		}
		c.tokens = StaticToken(token)
		return nil
	}
}

// END tokenoptions OMIT

// START logger OMIT

// WithLogger logs every request at debug level and every retry at warn
// level. The default discards logs.
func WithLogger(l *slog.Logger) Option {
	return func(c *config) error {
		if l == nil {
			return errors.New("WithLogger: nil *slog.Logger")
		}
		c.log = l
		return nil
	}
}

// END logger OMIT

// START poll OMIT

// WithPollInterval sets how often Poll and Wait fetch an operation. The
// default is 2s.
func WithPollInterval(d time.Duration) Option {
	return func(c *config) error {
		if d <= 0 {
			return fmt.Errorf("WithPollInterval: interval %v is not positive", d)
		}
		c.poll = d
		return nil
	}
}

// END poll OMIT

// START limiter OMIT

// Limiter is a client-side rate limiter. *rate.Limiter from
// golang.org/x/time/rate satisfies it; this package does not depend on it.
type Limiter interface {
	// Wait blocks until the next request may proceed or ctx is done.
	Wait(ctx context.Context) error
}

// WithLimiter makes the client wait on l before every attempt, including
// retries, so retries spend from the same budget as first attempts.
func WithLimiter(l Limiter) Option {
	return func(c *config) error {
		if l == nil {
			return errors.New("WithLimiter: nil Limiter")
		}
		c.limiter = l
		return nil
	}
}

// END limiter OMIT
