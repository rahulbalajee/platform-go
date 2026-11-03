package probe_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/probe"
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

	for name, tc := range map[string]struct {
		spec   probe.Spec
		ok     bool
		msgHas string
	}{
		"2xx is healthy":       {probe.Spec{URL: srv.URL + "/ok", Timeout: time.Second}, true, "HTTP 200"},
		"418 is not":           {probe.Spec{URL: srv.URL + "/teapot", Timeout: time.Second}, false, "unexpected status 418"},
		"explicit codes":       {probe.Spec{URL: srv.URL + "/teapot", Timeout: time.Second, StatusCodes: []int32{418}}, true, "HTTP 418"},
		"timeout":              {probe.Spec{URL: srv.URL + "/slow", Timeout: 50 * time.Millisecond}, false, "timed out after 50ms"},
		"latency budget":       {probe.Spec{URL: srv.URL + "/slow", Timeout: time.Second, MaxLatency: 100 * time.Millisecond}, false, "slower than maxLatency"},
		"connection refused":   {probe.Spec{URL: "http://127.0.0.1:1/", Timeout: time.Second}, false, "dial"},
		"unresolvable service": {probe.Spec{URL: "http://no-such-svc.invalid/", Timeout: time.Second}, false, "DNS lookup failed"},
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
