package sweep_test

import (
	"crypto/tls"
	"net"
	"strings"
	"testing"
	"time"

	"sweep/internal/sweep"
	"sweep/internal/sweep/sweeptest"
	"sweep/retry"
)

// TestTLSProberAgainstShortLivedCertificates checks certificate expiry
// against real TLS servers whose certificates expire when the test says.
func TestTLSProberAgainstShortLivedCertificates(t *testing.T) {
	tests := map[string]struct {
		left   time.Duration
		status sweep.Status
		text   string
	}{
		"expires in 3 days":  {72 * time.Hour, sweep.StatusDown, "expires in 3d (minimum 14d)"},
		"expires in 30 days": {30 * 24 * time.Hour, sweep.StatusUp, "expires in 30d"},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			srv, roots := sweeptest.NewTLSServer(t, time.Now().Add(tc.left))
			var d net.Dialer
			runner, err := sweep.NewRunner(sweep.Config{
				Concurrency: 1, PerHost: 1, Timeout: 5 * time.Second,
				Retry: retry.Policy{MaxAttempts: 3, BaseDelay: time.Millisecond},
				Probers: map[sweep.Kind]sweep.Prober{sweep.KindTLS: sweep.TLSProber{
					Dial:        d.DialContext,
					MinValidity: 14 * 24 * time.Hour,
					Config:      &tls.Config{RootCAs: roots},
				}},
			})
			if err != nil {
				t.Fatal(err)
			}
			inv := "tls://" + srv.Listener.Addr().String()
			targets, err := sweep.ParseTargets(strings.NewReader(inv))
			if err != nil {
				t.Fatal(err)
			}
			for r := range runner.Run(t.Context(), targets) {
				// One attempt either way: an expiring certificate is permanent.
				if r.Status != tc.status || r.Attempts != 1 ||
					!strings.Contains(r.Detail+" "+r.Error, tc.text) {
					t.Errorf("got %s after %d attempts (%q, %q); want %s, 1, %q",
						r.Status, r.Attempts, r.Detail, r.Error, tc.status, tc.text)
				}
			}
		})
	}
}
