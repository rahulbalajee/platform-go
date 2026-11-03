package buildinfo_test

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"stamp/buildinfo"
)

var info = buildinfo.Info{
	Name: "sweep", Version: "v1.4.0", GoVersion: "go1.27.3", Platform: "linux/amd64",
}

// get sends a GET with the given User-Agent ("" for none) through client
// and returns the User-Agent the server saw.
func get(t *testing.T, client *http.Client, url, ua string) (string, *http.Request) {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	if ua != "" {
		req.Header.Set("User-Agent", ua)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body), req
}

func TestTransportSetsUserAgent(t *testing.T) {
	echo := func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, r.UserAgent())
	}
	srv := httptest.NewServer(http.HandlerFunc(echo))
	defer srv.Close()
	client := &http.Client{Transport: info.Transport(nil)}

	seen, req := get(t, client, srv.URL, "")
	if want := "sweep/v1.4.0 (go1.27.3; linux/amd64)"; seen != want {
		t.Errorf("server saw User-Agent %q, want %q", seen, want)
	}
	if ua := req.Header.Get("User-Agent"); ua != "" {
		t.Errorf("the caller's request was modified (User-Agent %q); "+
			"a RoundTripper must not change its argument", ua)
	}
	if seen, _ := get(t, client, srv.URL, "probe/1"); seen != "probe/1" {
		t.Errorf("a User-Agent set by the caller was replaced: server saw %q", seen)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestTransportUsesBase(t *testing.T) {
	var sent *http.Request
	base := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		sent = r
		resp := &http.Response{StatusCode: http.StatusNoContent, Body: http.NoBody}
		resp.Request = r
		return resp, nil
	})
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet,
		"http://fleet.invalid/", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := info.Transport(base).RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if sent == nil {
		t.Fatal("the base RoundTripper was not called")
	}
	if got := sent.Header.Get("User-Agent"); got != info.UserAgent() {
		t.Errorf("base saw User-Agent %q, want %q", got, info.UserAgent())
	}
	if sent.Context() != req.Context() {
		t.Error("the request sent lost the caller's context")
	}
}
