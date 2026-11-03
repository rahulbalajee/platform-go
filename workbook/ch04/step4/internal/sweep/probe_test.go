// START head OMIT

package sweep_test

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"syscall"
	"testing"
	"time"

	"sweep/internal/sweep"
)

// END head OMIT

// START parse1 OMIT
// target parses a single inventory line.
func target(t *testing.T, line string) sweep.Target {
	t.Helper()
	ts, err := sweep.ParseTargets(strings.NewReader(line))
	if err != nil || len(ts) != 1 {
		t.Fatalf("ParseTargets(%q) = %v, %v", line, ts, err)
	}
	return ts[0]
}

// END parse1 OMIT

// START tcp OMIT
func TestTCPProber(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var d net.Dialer
	p := sweep.TCPProber{Dial: d.DialContext}
	tg := target(t, "tcp://"+l.Addr().String())

	detail, err := p.Probe(t.Context(), tg)
	if err != nil || !strings.HasPrefix(detail, "connected to 127.0.0.1:") {
		t.Errorf("open port: got %q, %v; want connected", detail, err)
	}
	l.Close()
	if _, err := p.Probe(t.Context(), tg); !errors.Is(err, syscall.ECONNREFUSED) {
		t.Errorf("closed port: err = %v, want connection refused", err)
	}
}

// END tcp OMIT

// START tls OMIT
func TestTLSProberChecksExpiry(t *testing.T) {
	srv := httptest.NewTLSServer(http.NotFoundHandler())
	defer srv.Close()
	roots := x509.NewCertPool()
	roots.AddCert(srv.Certificate()) // trust the test server's own CA
	notAfter := srv.Certificate().NotAfter

	var d net.Dialer
	p := sweep.TLSProber{
		Dial:        d.DialContext,
		MinValidity: 14 * 24 * time.Hour,
		Config:      &tls.Config{RootCAs: roots},
		// Pretend it is ten days before the certificate expires.
		Now: func() time.Time { return notAfter.Add(-10 * 24 * time.Hour) },
	}
	tg := target(t, "tls://"+srv.Listener.Addr().String())

	detail, err := p.Probe(t.Context(), tg)
	if !strings.HasSuffix(detail, "expires in 10d") {
		t.Errorf("detail = %q, want the days left", detail)
	}
	if err == nil || !strings.Contains(err.Error(), "(minimum 14d)") {
		t.Errorf("err = %v, want a too-close-to-expiry error", err)
	}

	p.MinValidity = 7 * 24 * time.Hour
	if _, err := p.Probe(t.Context(), tg); err != nil {
		t.Errorf("with a 7d minimum: err = %v, want nil", err)
	}
}

// END tls OMIT

// START dns OMIT
func TestDNSProberResolvesLocalhost(t *testing.T) {
	p := sweep.DNSProber{Resolver: net.DefaultResolver}
	detail, err := p.Probe(t.Context(), target(t, "dns://localhost"))
	if err != nil || !strings.Contains(detail, "address(es)") {
		t.Errorf("got %q, %v; want localhost's addresses", detail, err)
	}
}

// END dns OMIT

// START dispatch OMIT
func TestRunnerDispatchesByKind(t *testing.T) {
	up := sweep.ProberFunc(func(context.Context, sweep.Target) (string, error) {
		return "fake connect", nil
	})
	servfail := sweep.ProberFunc(func(context.Context, sweep.Target) (string, error) {
		return "", errors.New("SERVFAIL")
	})
	runner, err := sweep.NewRunner(sweep.Config{
		Concurrency: 2,
		Timeout:     time.Second,
		Probers: map[sweep.Kind]sweep.Prober{
			sweep.KindTCP: up,
			sweep.KindDNS: servfail,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	inv := "tcp://db:5432\ndns://example.com\ntls://example.com:443\n"
	ts, err := sweep.ParseTargets(strings.NewReader(inv))
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]string{}
	for r := range runner.Run(t.Context(), ts) {
		got[r.Target] = string(r.Status) + " " + r.Detail + r.Error
	}
	want := map[string]string{
		"tcp://db:5432":         "up fake connect",
		"dns://example.com":     "down SERVFAIL",
		"tls://example.com:443": `down no prober for kind "tls"`,
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: got %q, want %q", k, got[k], w)
		}
	}
}

// END dispatch OMIT
