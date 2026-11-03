package probe_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"watchtower/internal/probe"
)

func TestHTTPProbe(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ok", func(http.ResponseWriter, *http.Request) {})
	mux.HandleFunc("/teapot", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(300 * time.Millisecond):
		case <-r.Context().Done():
		}
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	p := probe.HTTP{Client: srv.Client()}
	spec := func(path string, timeout time.Duration) probe.Spec {
		return probe.Spec{URL: srv.URL + path, Timeout: timeout}
	}
	codes := spec("/teapot", time.Second)
	codes.StatusCodes = []int32{418}
	budget := spec("/slow", time.Second)
	budget.MaxLatency = 100 * time.Millisecond

	for name, tc := range map[string]struct {
		spec   probe.Spec
		ok     bool
		msgHas string
	}{
		"2xx is healthy": {spec("/ok", time.Second), true, "HTTP 200"},
		"418 is not": {spec("/teapot", time.Second), false,
			"unexpected status 418"},
		"explicit codes": {codes, true, "HTTP 418"},
		"timeout": {spec("/slow", 50*time.Millisecond), false,
			"timed out after 50ms"},
		"latency budget": {budget, false, "slower than maxLatency"},
		"connection refused": {probe.Spec{URL: "http://127.0.0.1:1/",
			Timeout: time.Second}, false, "dial"},
		"unresolvable service": {probe.Spec{URL: "http://no-such-svc.invalid/",
			Timeout: time.Second}, false, "DNS lookup failed"},
	} {
		t.Run(name, func(t *testing.T) {
			res := p.Probe(t.Context(), tc.spec)
			if res.OK != tc.ok || !strings.Contains(res.Message, tc.msgHas) {
				t.Errorf("got ok=%v msg=%q; want ok=%v msg containing %q",
					res.OK, res.Message, tc.ok, tc.msgHas)
			}
		})
	}
}
