// START head OMIT

package platformapi_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

func TestNotFoundIsAnAPIError(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.GetDeployment(t.Context(), "d-404")
	t.Log(err)
	if !errors.Is(err, platformapi.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	if errors.Is(err, platformapi.ErrConflict) {
		t.Error("a 404 must not match ErrConflict")
	}
	apiErr, ok := errors.AsType[*platformapi.APIError](err)
	if !ok {
		t.Fatalf("err = %T, want *APIError in the chain", err)
	}
	want := platformapi.APIError{
		StatusCode: http.StatusNotFound, Code: "not_found",
		Message:   `deployment "d-404" not found`,
		RequestID: fake.Requests()[0].RequestID,
		Op:        "GET /v1/deployments/d-404",
	}
	if *apiErr != want {
		t.Errorf("APIError =\n%+v\nwant\n%+v", *apiErr, want)
	}
}

// END head OMIT

// START escape OMIT

func TestIDsCannotEscapeTheirPath(t *testing.T) {
	client, fake := newClient(t)
	_, err := client.GetDeployment(t.Context(), "../environments/prod")
	if !errors.Is(err, platformapi.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
	const want = "/v1/deployments/..%2Fenvironments%2Fprod"
	if got := fake.Requests()[0].Path; got != want {
		t.Errorf("path = %q, want the ID escaped as one segment", got)
	}
}

func TestErrorsFromProxiesKeepTheirText(t *testing.T) {
	// A firewall in front of the API answers in plain text, not JSON.
	waf := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "blocked by policy 1137", http.StatusForbidden)
	})
	srv := httptest.NewServer(waf)
	defer srv.Close()
	client, err := platformapi.New(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.GetEnvironment(t.Context(), "dev")
	apiErr, ok := errors.AsType[*platformapi.APIError](err)
	if !ok || apiErr.Code != "forbidden" ||
		apiErr.Message != "blocked by policy 1137" {
		t.Errorf("err = %v, want a forbidden *APIError with the proxy's text", err)
	}
}

// END escape OMIT
