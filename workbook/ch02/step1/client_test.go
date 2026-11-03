// START fixture OMIT

package platformapi_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"platformapi"
	"platformapi/platformapifake"
)

// newClient starts a fake platform on a local port and returns a client
// for it. The server stops when the test ends.
func newClient(t *testing.T) (*platformapi.Client, *platformapifake.Server) {
	t.Helper()
	fake := platformapifake.New()
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	client, err := platformapi.New(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	return client, fake
}

// END fixture OMIT

// START newtests OMIT
func TestNewRejectsBadBaseURLs(t *testing.T) {
	for _, raw := range []string{
		"ftp://platform.internal", // wrong scheme
		"platform.internal",       // no scheme at all
		"https://",                // no host
		"https://platform.internal/?env=prod",
	} {
		if _, err := platformapi.New(raw); err == nil {
			t.Errorf("New(%q) succeeded", raw)
		}
	}
}

func TestNewAcceptsBaseURLWithPathPrefix(t *testing.T) {
	fake := platformapifake.New()
	mux := http.NewServeMux()
	mux.Handle("/api/", http.StripPrefix("/api", fake))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	client, err := platformapi.New(srv.URL + "/api/")
	if err != nil {
		t.Fatal(err)
	}
	env, err := client.GetEnvironment(t.Context(), "prod")
	if err != nil {
		t.Fatal(err)
	}
	if !env.Protected {
		t.Errorf("prod environment = %+v, want Protected", env)
	}
}

// END newtests OMIT

// START gettests OMIT
func TestGetEnvironment(t *testing.T) {
	client, _ := newClient(t)
	env, err := client.GetEnvironment(t.Context(), "staging")
	if err != nil {
		t.Fatal(err)
	}
	if env.Name != "staging" || env.Region != "eu-west-1" || env.Protected {
		t.Errorf("staging = %+v", env)
	}
}

func TestGetDeploymentDecodesEveryField(t *testing.T) {
	client, _ := newClient(t)
	d, err := client.GetDeployment(t.Context(), "d-2")
	if err != nil {
		t.Fatal(err)
	}
	want := platformapi.Deployment{
		ID: "d-2", Service: "checkout", Environment: "staging",
		Version: "v1.3.0", State: platformapi.StateSucceeded,
		Replicas: 4, UpdatedReplicas: 4,
		CreatedAt: time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC),
	}
	if *d != want {
		t.Errorf("GetDeployment(d-2) =\n%+v\nwant\n%+v", *d, want)
	}
}

func TestMissingResourceIsAnError(t *testing.T) {
	client, _ := newClient(t)
	svc, err := client.GetService(t.Context(), "billing")
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("GetService(billing) = %+v, %v; want a 404 error", svc, err)
	}
	if svc != nil {
		t.Errorf("got a service along with the error: %+v", svc)
	}
}

func TestInvalidIDsAreRejected(t *testing.T) {
	client, _ := newClient(t)
	for _, id := range []string{"", ".", ".."} {
		if _, err := client.GetDeployment(t.Context(), id); err == nil {
			t.Errorf("GetDeployment(%q) succeeded", id)
		}
	}
}

// END gettests OMIT
