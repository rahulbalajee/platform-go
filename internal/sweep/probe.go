package sweep

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// START prober OMIT
// A Prober performs one attempt against a target. It returns a short,
// human-readable detail (for example "200 OK") and an error if the target is
// unhealthy. Probers must honour ctx: the runner enforces per-attempt
// timeouts and cancellation through it.
//
// Errors wrapped with retry.Permanent are not retried; everything else is.
type Prober interface {
	Probe(ctx context.Context, t Target) (detail string, err error)
}

// ProberFunc adapts a function to the Prober interface.
type ProberFunc func(ctx context.Context, t Target) (string, error)

func (f ProberFunc) Probe(ctx context.Context, t Target) (string, error) {
	return f(ctx, t)
}

// END prober OMIT

// START http OMIT
// HTTPProber issues a GET and treats 2xx/3xx as healthy, 429 and 5xx as
// retryable failures, and other 4xx as permanent failures.
type HTTPProber struct {
	Client    *http.Client // must not set Timeout; deadlines come from ctx
	UserAgent string
}

// StatusError reports an unhealthy HTTP status.
type StatusError struct{ Code int }

func (e *StatusError) Error() string {
	return fmt.Sprintf("unhealthy status %d %s", e.Code, http.StatusText(e.Code))
}

func (p HTTPProber) Probe(ctx context.Context, t Target) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.URL.String(), nil)
	if err != nil {
		return "", retry.Permanent(err)
	}
	req.Header.Set("User-Agent", p.UserAgent)

	resp, err := p.Client.Do(req)
	if err != nil {
		// An untrusted or expired certificate won't heal in 200ms. Other
		// transport errors (refused, reset, timeout) are worth retrying.
		if _, ok := errors.AsType[*tls.CertificateVerificationError](err); ok {
			return "", retry.Permanent(err)
		}
		return "", err
	}
	defer resp.Body.Close()
	// Read a bounded amount so the connection can be reused. (Go 1.27 also
	// drains on Close, but being explicit keeps behaviour version-independent.)
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))

	detail := resp.Status
	switch code := resp.StatusCode; {
	case code < 400:
		return detail, nil
	case code == http.StatusTooManyRequests || code == http.StatusServiceUnavailable:
		if d, ok := parseRetryAfter(resp.Header.Get("Retry-After")); ok {
			return detail, retry.After(d, &StatusError{code})
		}
		return detail, &StatusError{code}
	case code >= 500:
		return detail, &StatusError{code}
	default:
		return detail, retry.Permanent(&StatusError{code}) // 4xx won't fix itself
	}
}

// END http OMIT

func parseRetryAfter(v string) (time.Duration, bool) {
	if v == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
		return time.Duration(secs) * time.Second, true
	}
	if t, err := http.ParseTime(v); err == nil {
		return max(time.Until(t), 0), true
	}
	return 0, false
}

// TCPProber succeeds if a TCP connection can be established.
type TCPProber struct {
	Dial func(ctx context.Context, network, addr string) (net.Conn, error)
}

func (p TCPProber) Probe(ctx context.Context, t Target) (string, error) {
	conn, err := p.Dial(ctx, "tcp", t.URL.Host)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	return "connected to " + conn.RemoteAddr().String(), nil
}

// TLSProber performs a TLS handshake and fails, permanently, if the leaf
// certificate expires within MinValidity. Expiring certificates are the
// single most common self-inflicted outage this tool can catch early.
type TLSProber struct {
	Dial        func(ctx context.Context, network, addr string) (net.Conn, error)
	MinValidity time.Duration
	Config      *tls.Config // optional; ServerName is derived from the target
	Now         func() time.Time
}

func (p TLSProber) Probe(ctx context.Context, t Target) (string, error) {
	raw, err := p.Dial(ctx, "tcp", t.URL.Host)
	if err != nil {
		return "", err
	}
	defer raw.Close()

	cfg := &tls.Config{}
	if p.Config != nil {
		cfg = p.Config.Clone()
	}
	cfg.ServerName = t.URL.Hostname()
	conn := tls.Client(raw, cfg)
	if err := conn.HandshakeContext(ctx); err != nil {
		if _, ok := errors.AsType[*tls.CertificateVerificationError](err); ok {
			return "", retry.Permanent(err) // a bad chain won't fix itself
		}
		return "", err
	}
	leaf := conn.ConnectionState().PeerCertificates[0]
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	left := leaf.NotAfter.Sub(now())
	detail := fmt.Sprintf("cert %q expires in %s", leaf.Subject.CommonName, humanDays(left))
	if left < p.MinValidity {
		return detail, retry.Permanent(fmt.Errorf("certificate expires in %s (minimum %s)",
			humanDays(left), humanDays(p.MinValidity)))
	}
	return detail, nil
}

// DNSProber resolves a name. It deliberately bypasses any cache: the point
// is to test resolution itself.
type DNSProber struct {
	Resolver *net.Resolver
}

func (p DNSProber) Probe(ctx context.Context, t Target) (string, error) {
	addrs, err := p.Resolver.LookupHost(ctx, t.URL.Hostname())
	if err != nil {
		if dnsErr, ok := errors.AsType[*net.DNSError](err); ok && dnsErr.IsNotFound {
			return "", retry.Permanent(err) // NXDOMAIN is an answer, not a blip
		}
		return "", err
	}
	return fmt.Sprintf("%d address(es): %s", len(addrs), addrs[0]), nil
}

func humanDays(d time.Duration) string {
	days := d.Hours() / 24
	if days >= 2 || days <= -2 {
		return fmt.Sprintf("%.0fd", days)
	}
	return d.Round(time.Minute).String()
}
