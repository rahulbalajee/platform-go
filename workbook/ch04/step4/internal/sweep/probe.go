// START imports OMIT

package sweep

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// END imports OMIT

// START prober OMIT
// A Prober performs one attempt against a target. It returns a short,
// human-readable detail (for example "200 OK") and an error if the target is
// unhealthy. Probers must honour ctx: the runner enforces per-attempt
// timeouts and cancellation through it.
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
// HTTPProber issues a GET and treats 2xx/3xx as healthy and anything else
// as down.
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
		return "", err
	}
	req.Header.Set("User-Agent", p.UserAgent)

	resp, err := p.Client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	// Read a bounded amount so the connection can be reused. (Go 1.27 also
	// drains on Close, but being explicit keeps behaviour version-independent.)
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))

	if resp.StatusCode >= 400 {
		return resp.Status, &StatusError{resp.StatusCode}
	}
	return resp.Status, nil
}

// END http OMIT

// START tcp OMIT
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

// END tcp OMIT

// START tlstype OMIT
// TLSProber performs a TLS handshake and fails if the leaf certificate
// expires within MinValidity. Expiring certificates are the single most
// common self-inflicted outage this tool can catch early.
type TLSProber struct {
	Dial        func(ctx context.Context, network, addr string) (net.Conn, error)
	MinValidity time.Duration
	Config      *tls.Config // optional; ServerName is derived from the target
	Now         func() time.Time
}

// END tlstype OMIT

// START tlsprobe OMIT
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
		return "", err
	}
	leaf := conn.ConnectionState().PeerCertificates[0]
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	left := leaf.NotAfter.Sub(now())
	detail := fmt.Sprintf("cert %q expires in %s",
		leaf.Subject.CommonName, humanDays(left))
	if left < p.MinValidity {
		return detail, fmt.Errorf(
			"certificate expires in %s (minimum %s)",
			humanDays(left), humanDays(p.MinValidity))
	}
	return detail, nil
}

// END tlsprobe OMIT

// START dnstype OMIT
// DNSProber resolves a name. It deliberately bypasses any cache: the point
// is to test resolution itself.
type DNSProber struct {
	Resolver *net.Resolver
}

// END dnstype OMIT

// START dnsprobe OMIT
func (p DNSProber) Probe(ctx context.Context, t Target) (string, error) {
	addrs, err := p.Resolver.LookupHost(ctx, t.URL.Hostname())
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d address(es): %s", len(addrs), addrs[0]), nil
}

// END dnsprobe OMIT

// START humandays OMIT
func humanDays(d time.Duration) string {
	days := d.Hours() / 24
	if days >= 2 || days <= -2 {
		return fmt.Sprintf("%.0fd", days)
	}
	return d.Round(time.Minute).String()
}

// END humandays OMIT
