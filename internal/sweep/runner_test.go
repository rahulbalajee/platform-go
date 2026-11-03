package sweep_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/rahulbalajee/platform-go/internal/sweep"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// START fixture OMIT
// fleet is a fake service with one path per behaviour we care about. It
// runs on httptest.NewTestServer's in-memory network (Go 1.27), so inside a
// synctest bubble every sleep and timeout happens in virtual time.
func fleet(t *testing.T, inFlight, peak *atomic.Int64) *httptest.Server {
	var flakyCalls atomic.Int64
	mux := http.NewServeMux()
	track := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			n := inFlight.Add(1)
			defer inFlight.Add(-1)
			for p := peak.Load(); n > p; p = peak.Load() {
				if peak.CompareAndSwap(p, n) {
					break
				}
			}
			h(w, r)
		}
	}
	mux.HandleFunc("/ok", track(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(50 * time.Millisecond)
	}))
	mux.HandleFunc("/flaky", track(func(w http.ResponseWriter, r *http.Request) {
		if flakyCalls.Add(1) < 3 {
			http.Error(w, "warming up", http.StatusBadGateway)
		}
	}))
	mux.HandleFunc("/slow", track(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(10 * time.Second):
		case <-r.Context().Done():
		}
	}))
	mux.HandleFunc("/missing", track(http.NotFound))
	return httptest.NewTestServer(t, mux)
}

// END fixture OMIT

func targets(t *testing.T, base string, paths ...string) []sweep.Target {
	t.Helper()
	var b strings.Builder
	for _, p := range paths {
		b.WriteString(base + p + "\n")
	}
	ts, err := sweep.ParseTargets(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return ts
}

// START test OMIT
func TestRunnerOutcomes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var inFlight, peak atomic.Int64
		srv := fleet(t, &inFlight, &peak)
		runner, err := sweep.NewRunner(sweep.Config{
			Concurrency: 8,
			PerHost:     8,
			Timeout:     2 * time.Second,
			Retry: retry.Policy{
				MaxAttempts: 3,
				BaseDelay:   100 * time.Millisecond,
			},
			Probers: map[sweep.Kind]sweep.Prober{
				sweep.KindHTTP: sweep.HTTPProber{Client: srv.Client()},
			},
		})
		if err != nil {
			t.Fatal(err)
		}

		start := time.Now()
		got := map[string]sweep.Result{}
		inv := targets(t, srv.URL, "/ok", "/flaky", "/slow", "/missing")
		for r := range runner.Run(t.Context(), inv) {
			got[strings.TrimPrefix(r.Target, srv.URL)] = r
		}

		want := map[string]struct {
			status   sweep.Status
			attempts int
			errHas   string
		}{
			"/ok":    {sweep.StatusUp, 1, ""},
			"/flaky": {sweep.StatusUp, 3, ""}, // 502, 502, 200
			// Timed out three times, then gave up.
			"/slow": {sweep.StatusDown, 3, "attempt timed out after 2s"},
			// 404 is permanent: no retry.
			"/missing": {sweep.StatusDown, 1, "404"},
		}
		for path, w := range want {
			r := got[path]
			if r.Status != w.status || r.Attempts != w.attempts ||
				!strings.Contains(r.Error, w.errHas) {
				t.Errorf("%s: got %s/%d/%q, want %s/%d/%q", path,
					r.Status, r.Attempts, r.Error, w.status, w.attempts, w.errHas)
			}
		}
		// Three 2s timeouts plus at most 100ms+200ms of jittered backoff.
		if el := time.Since(start); el < 6*time.Second || el > 6300*time.Millisecond {
			t.Errorf("sweep took %v of virtual time, want 6s-6.3s", el)
		}
	})
}

// END test OMIT

func TestRunnerRespectsPerHostLimit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var inFlight, peak atomic.Int64
		srv := fleet(t, &inFlight, &peak)
		runner, _ := sweep.NewRunner(sweep.Config{
			Concurrency: 50, // plenty of global capacity...
			PerHost:     3,  // ...but only 3 at a time against this host
			Timeout:     time.Second,
			Probers:     map[sweep.Kind]sweep.Prober{sweep.KindHTTP: sweep.HTTPProber{Client: srv.Client()}},
		})
		paths := make([]string, 30)
		for i := range paths {
			paths[i] = "/ok"
		}
		n := 0
		for range runner.Run(t.Context(), targets(t, srv.URL, paths...)) {
			n++
		}
		if n != 30 {
			t.Fatalf("got %d results, want 30", n)
		}
		if p := peak.Load(); p != 3 {
			t.Errorf("peak concurrent requests to one host = %d, want 3", p)
		}
	})
}

func TestRunnerCancellationMarksInFlightTargets(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var inFlight, peak atomic.Int64
		srv := fleet(t, &inFlight, &peak)
		runner, _ := sweep.NewRunner(sweep.Config{
			Concurrency: 2, PerHost: 2, Timeout: time.Minute,
			Probers: map[sweep.Kind]sweep.Prober{sweep.KindHTTP: sweep.HTTPProber{Client: srv.Client()}},
		})
		ctx, cancel := context.WithCancel(t.Context())
		time.AfterFunc(3*time.Second, cancel) // the user presses Ctrl-C

		var statuses []sweep.Status
		for r := range runner.Run(ctx, targets(t, srv.URL, "/slow", "/slow", "/slow", "/slow")) {
			statuses = append(statuses, r.Status)
		}
		if len(statuses) != 2 {
			t.Fatalf("got %d results, want only the 2 that had started", len(statuses))
		}
		for _, s := range statuses {
			if s != sweep.StatusCancelled {
				t.Errorf("status = %s, want cancelled", s)
			}
		}
	})
}

func TestUntrustedCertificateIsNotRetried(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer srv.Close()
	// A client that does NOT trust the test server's self-signed CA.
	runner, _ := sweep.NewRunner(sweep.Config{
		Concurrency: 1, PerHost: 1, Timeout: 5 * time.Second,
		Retry:   retry.Policy{MaxAttempts: 3, BaseDelay: time.Millisecond},
		Probers: map[sweep.Kind]sweep.Prober{sweep.KindHTTP: sweep.HTTPProber{Client: &http.Client{}}},
	})
	for r := range runner.Run(t.Context(), targets(t, srv.URL, "/")) {
		if r.Status != sweep.StatusDown || r.Attempts != 1 || !strings.Contains(r.Error, "certificate") {
			t.Errorf("got %+v, want down after exactly 1 attempt with a certificate error", r)
		}
	}
}

func TestParseTargetsReportsAllErrors(t *testing.T) {
	_, err := sweep.ParseTargets(strings.NewReader(`
# inventory
https://ok.example.com/healthz
ftp://files.example.com
tcp://db.example.com
dns://example.com
`))
	if err == nil {
		t.Fatal("want error")
	}
	for _, want := range []string{"line 4", "unsupported scheme", "line 5", "host:port"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err, want)
		}
	}
}
