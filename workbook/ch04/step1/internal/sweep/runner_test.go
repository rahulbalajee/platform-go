package sweep_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"sweep/internal/sweep"
)

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
	mux := http.NewServeMux()
	mux.HandleFunc("/ok", func(http.ResponseWriter, *http.Request) {})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(10 * time.Second):
		case <-r.Context().Done(): // the client gave up
		}
	})
	mux.HandleFunc("/missing", http.NotFound)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	runner, err := sweep.NewRunner(sweep.Config{
		Timeout: 200 * time.Millisecond,
		HTTP:    sweep.HTTPProber{Client: srv.Client()},
	})
	if err != nil {
		t.Fatal(err)
	}
	inv := targets(t, srv.URL, "/ok", "/slow", "/missing")
	results := runner.Run(t.Context(), inv)

	want := []struct {
		status sweep.Status
		errHas string
	}{
		{sweep.StatusUp, ""},
		{sweep.StatusDown, "context deadline exceeded"},
		{sweep.StatusDown, "404 Not Found"},
	}
	if len(results) != len(want) {
		t.Fatalf("got %d results, want %d", len(results), len(want))
	}
	for i, w := range want {
		r := results[i]
		if r.Status != w.status || !strings.Contains(r.Error, w.errHas) {
			t.Errorf("%s: got %s/%q, want %s/%q",
				r.Target, r.Status, r.Error, w.status, w.errHas)
		}
	}
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
	wants := []string{"line 4", "unsupported scheme", "line 5", "line 6"}
	for _, want := range wants {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q missing %q", err, want)
		}
	}
}

// END parse OMIT
