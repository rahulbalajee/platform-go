// START head OMIT

// Package sweep checks many network targets concurrently: HTTP endpoints,
// TCP ports, TLS certificates and DNS names.
package sweep

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
)

// Kind identifies which prober handles a target.
type Kind string

const (
	KindHTTP Kind = "http" // http:// and https:// URLs
	KindTCP  Kind = "tcp"  // tcp://host:port
	KindTLS  Kind = "tls"  // tls://host:port, checks certificate validity
	KindDNS  Kind = "dns"  // dns://name
)

// Target is one parsed line of input.
type Target struct {
	Index int    // position in the input; used to restore input order
	Raw   string // the line as written
	Kind  Kind
	URL   *url.URL
}

// Host returns the host[:port] used for per-host concurrency limits.
func (t Target) Host() string { return t.URL.Host }

// END head OMIT

// START parse OMIT

// ParseTargets reads one target per line. Blank lines and lines starting with
// # are ignored. All syntax errors are reported together, with line numbers,
// so a user can fix an inventory file in one pass.
func ParseTargets(r io.Reader) ([]Target, error) {
	var (
		targets []Target
		errs    []string
		line    int
	)
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line++
		raw := strings.TrimSpace(sc.Text())
		if raw == "" || strings.HasPrefix(raw, "#") {
			continue
		}
		t, err := parseTarget(raw)
		if err != nil {
			errs = append(errs, fmt.Sprintf("line %d: %v", line, err))
			continue
		}
		t.Index = len(targets)
		targets = append(targets, t)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("reading targets: %w", err)
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("invalid targets:\n  %s", strings.Join(errs, "\n  "))
	}
	return targets, nil
}

// END parse OMIT

// START parse1 OMIT

func parseTarget(raw string) (Target, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return Target{}, err
	}
	t := Target{Raw: raw, URL: u}
	switch u.Scheme {
	case "http", "https":
		t.Kind = KindHTTP
	case "tcp", "tls":
		t.Kind = Kind(u.Scheme)
		if _, port, err := net.SplitHostPort(u.Host); err != nil || port == "" {
			return Target{}, fmt.Errorf("%q: %s targets need host:port",
				raw, u.Scheme)
		}
	case "dns":
		t.Kind = KindDNS
	default:
		return Target{}, fmt.Errorf(
			"%q: unsupported scheme %q (want http, https, tcp, tls, dns)",
			raw, u.Scheme)
	}
	if u.Hostname() == "" {
		return Target{}, fmt.Errorf("%q: missing host", raw)
	}
	// START port OMIT
	// url.Parse only checks that a port is all digits. Reject what no dialer
	// accepts, so the error carries a line number instead of surfacing later
	// as a "down" target that was retried three times.
	if p := u.Port(); p != "" {
		if n, err := strconv.ParseUint(p, 10, 16); err != nil || n == 0 {
			return Target{}, fmt.Errorf("%q: invalid port %q (want 1-65535)", raw, p)
		}
	}
	// END port OMIT
	return t, nil
}

// END parse1 OMIT
