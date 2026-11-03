// START faketest OMIT

package platformapifake_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"platformapi/platformapifake"
)

// get sends a GET with the given headers and decodes the JSON body.
func get(t *testing.T, url string, header map[string]string) (
	*http.Response, map[string]any) {

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

func TestEchoesRequestIDAndChecksToken(t *testing.T) {
	fake := platformapifake.New()
	fake.RequireToken("t1")
	srv := httptest.NewServer(fake)
	defer srv.Close()
	url := srv.URL + "/v1/environments/dev"

	resp, _ := get(t, url, map[string]string{"X-Request-Id": "abc"})
	id := resp.Header.Get("X-Request-Id")
	if resp.StatusCode != http.StatusUnauthorized || id != "abc" {
		t.Errorf("no token: status %d, request ID %q", resp.StatusCode, id)
	}
	resp, body := get(t, url, map[string]string{"Authorization": "Bearer t1"})
	id = resp.Header.Get("X-Request-Id")
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(id, "srv-") {
		t.Errorf("with token: status %d, request ID %q", resp.StatusCode, id)
	}
	if body["name"] != "dev" {
		t.Errorf("body = %v, want the dev environment", body)
	}
	if n := len(fake.Requests()); n != 2 {
		t.Errorf("recorded %d requests, want 2", n)
	}
}

// END faketest OMIT

// START pagetest OMIT
func TestRejectsBadPageTokensAndSizes(t *testing.T) {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	for _, q := range []string{
		"page_token=not-a-token", "page_size=0", "page_size=101",
	} {
		resp, body := get(t, srv.URL+"/v1/deployments?"+q, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", q, resp.StatusCode)
		}
		if e, _ := body["error"].(map[string]any); e["code"] != "invalid_argument" {
			t.Errorf("%s: body %v, want invalid_argument", q, body)
		}
	}
}

// END pagetest OMIT
