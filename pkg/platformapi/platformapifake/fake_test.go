package platformapifake_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
)

func get(t *testing.T, url string, header map[string]string) (*http.Response, map[string]any) {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return resp, body
}

func TestRejectsBadPageTokensAndSizes(t *testing.T) {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	for _, q := range []string{"page_token=not-a-token", "page_size=0", "page_size=101"} {
		resp, body := get(t, srv.URL+"/v1/deployments?"+q, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", q, resp.StatusCode)
		}
		if e, _ := body["error"].(map[string]any); e["code"] != "invalid_argument" {
			t.Errorf("%s: body %v, want invalid_argument", q, body)
		}
	}
}

func TestEchoesRequestIDAndChecksToken(t *testing.T) {
	fake := platformapifake.New()
	fake.RequireToken("t1")
	srv := httptest.NewServer(fake)
	defer srv.Close()

	resp, _ := get(t, srv.URL+"/v1/environments", map[string]string{"X-Request-Id": "abc"})
	if resp.StatusCode != http.StatusUnauthorized || resp.Header.Get("X-Request-Id") != "abc" {
		t.Errorf("no token: status %d, request ID %q", resp.StatusCode,
			resp.Header.Get("X-Request-Id"))
	}
	resp, body := get(t, srv.URL+"/v1/environments",
		map[string]string{"Authorization": "Bearer t1"})
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(
		resp.Header.Get("X-Request-Id"), "srv-") {
		t.Errorf("with token: status %d, request ID %q", resp.StatusCode,
			resp.Header.Get("X-Request-Id"))
	}
	if items, _ := body["items"].([]any); len(items) != 3 {
		t.Errorf("got %d environments, want 3", len(items))
	}
	if n := len(fake.Requests()); n != 2 {
		t.Errorf("recorded %d requests, want 2", n)
	}
}
