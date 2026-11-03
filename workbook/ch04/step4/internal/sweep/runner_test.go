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

	"sweep/internal/sweep"
)

// fleet is a fake service with one path per behaviour we care about. It
// runs on httptest.NewTestServer's in-memory network (Go 1.27), so inside a
// synctest bubble every sleep and timeout happens in virtual time. peak
// records the most requests the fleet ever served at once.
func fleet(t *testing.T, peak *atomic.Int64) *httptest.Server {
	var inFlight, flakyCalls atomic.Int64
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
	mux := http.NewServeMux()
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

// START helpers OMIT
// newRunner builds a Runner whose HTTP checks go to srv. Tests set the
// knobs they care about; the others get roomy defaults.
func newRunner(t *testing.T, srv *httptest.Server, cfg sweep.Config) *sweep.Runner {
	t.Helper()
	if cfg.Concurrency == 0 {
		cfg.Concurrency = 8
	}
	cfg.Probers = map[sweep.Kind]sweep.Prober{
		sweep.KindHTTP: sweep.HTTPProber{Client: srv.Client()},
	}
	runner, err := sweep.NewRunner(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return runner
}

// END helpers OMIT

// targets parses one target per path on base, as an inventory would list them.
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

func TestRunnerOutcomes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var peak atomic.Int64
		srv := fleet(t, &peak)
		runner := newRunner(t, srv, sweep.Config{Timeout: 2 * time.Second})

		start := time.Now()
		got := map[string]sweep.Result{}
		inv := targets(t, srv.URL, "/ok", "/flaky", "/slow", "/missing")
		for r := range runner.Run(t.Context(), inv) {
			got[strings.TrimPrefix(r.Target, srv.URL)] = r
		}

		want := map[string]struct {
			status sweep.Status
			errHas string
		}{
			"/ok":      {sweep.StatusUp, ""},
			"/flaky":   {sweep.StatusDown, "502 Bad Gateway"},
			"/slow":    {sweep.StatusDown, "attempt timed out after 2s"},
			"/missing": {sweep.StatusDown, "404 Not Found"},
		}
		for path, w := range want {
			r := got[path]
			if r.Status != w.status || !strings.Contains(r.Error, w.errHas) {
				t.Errorf("%s: got %s/%q, want %s/%q", path,
					r.Status, r.Error, w.status, w.errHas)
			}
		}
		// The checks ran at the same time, so the sweep took as long as the
		// slowest one, not the 2.05s the four add up to.
		if el := time.Since(start); el != 2*time.Second {
			t.Errorf("sweep took %v of virtual time, want exactly 2s", el)
		}
	})
}

func TestRunnerCancellationMarksInFlightTargets(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var peak atomic.Int64
		srv := fleet(t, &peak)
		runner := newRunner(t, srv, sweep.Config{
			Concurrency: 2,
			Timeout:     time.Minute,
		})
		ctx, cancel := context.WithCancel(t.Context())
		time.AfterFunc(3*time.Second, cancel) // the user presses Ctrl-C

		var statuses []sweep.Status
		inv := targets(t, srv.URL, "/slow", "/slow", "/slow", "/slow")
		for r := range runner.Run(ctx, inv) {
			statuses = append(statuses, r.Status)
		}
		if len(statuses) != 2 {
			t.Fatalf("got %d results, want only the 2 that had started",
				len(statuses))
		}
		for _, s := range statuses {
			if s != sweep.StatusCancelled {
				t.Errorf("status = %s, want cancelled", s)
			}
		}
	})
}

func TestRunnerRespectsConcurrencyLimit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var peak atomic.Int64
		srv := fleet(t, &peak)
		runner := newRunner(t, srv, sweep.Config{
			Concurrency: 3,
			Timeout:     time.Second,
		})
		paths := make([]string, 30)
		for i := range paths {
			paths[i] = "/ok"
		}

		start, n := time.Now(), 0
		for range runner.Run(t.Context(), targets(t, srv.URL, paths...)) {
			n++
		}
		if n != 30 {
			t.Fatalf("got %d results, want 30", n)
		}
		if p := peak.Load(); p != 3 {
			t.Errorf("peak concurrent requests = %d, want 3", p)
		}
		// 30 checks of 50ms, three at a time: ten rounds.
		if el := time.Since(start); el != 500*time.Millisecond {
			t.Errorf("sweep took %v, want 500ms", el)
		}
	})
}

// START parse OMIT
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
	wants := []string{"line 4", "unsupported scheme", "line 5", "host:port"}
	for _, want := range wants {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err, want)
		}
	}
}

// END parse OMIT
