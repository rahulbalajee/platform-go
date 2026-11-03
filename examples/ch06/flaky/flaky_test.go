//go:build flakydemo

package flaky

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// START order OMIT
// Both tests pass in source order. Run them in the other order (-shuffle)
// or twice (-count=2) and they fail, because they share the registry.
func TestRegistryStartsEmpty(t *testing.T) {
	if n := Len(); n != 0 {
		t.Fatalf("registry has %d checks, want 0", n)
	}
}

func TestRegister(t *testing.T) {
	if err := Register("api", "https://api.example.com/healthz"); err != nil {
		t.Fatal(err)
	}
}

// END order OMIT

// START defer OMIT
// The parallel subtests run after this function returns, and by then the
// deferred Close has shut the server down. t.Cleanup(srv.Close) waits for
// the subtests; defer does not.
func TestEndpoints(t *testing.T) {
	ok := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})
	srv := httptest.NewServer(ok)
	defer srv.Close() // BUG: use t.Cleanup(srv.Close)
	for _, path := range []string{"/healthz", "/readyz"} {
		t.Run(path, func(t *testing.T) {
			t.Parallel()
			resp, err := srv.Client().Get(srv.URL + path)
			if err != nil {
				t.Fatalf("GET %s: %v", path, errors.Unwrap(err))
			}
			resp.Body.Close()
		})
	}
}

// END defer OMIT

// START setenv OMIT
// Environment variables belong to the whole process, so the testing
// package refuses to set them in a parallel test.
func TestProxyFromEnvironment(t *testing.T) {
	t.Parallel()
	t.Setenv("HTTPS_PROXY", "http://proxy.internal:3128")
}

// END setenv OMIT
