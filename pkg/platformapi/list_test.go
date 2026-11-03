package platformapi_test

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

func TestListDeploymentsFollowsPageTokens(t *testing.T) {
	client, fake := newClient(t)
	f := platformapi.DeploymentFilter{Service: "checkout"}
	got, err := platformapi.Collect(
		client.ListDeployments(t.Context(), f, platformapi.PageSize(3)))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 8 {
		t.Fatalf("got %d deployments, want 8", len(got))
	}
	for i := 1; i < len(got); i++ {
		if got[i].CreatedAt.After(got[i-1].CreatedAt) {
			t.Errorf("deployments not newest first at %d", i)
		}
	}
	reqs := fake.Requests()
	if len(reqs) != 3 {
		t.Fatalf("made %d requests for 8 items in pages of 3, want 3", len(reqs))
	}
	if !strings.Contains(reqs[2].Path, "page_token=") {
		t.Errorf("third request %q has no page_token", reqs[2].Path)
	}
}

// START breaktest OMIT
func TestBreakStopsFetchingPages(t *testing.T) {
	client, fake := newClient(t)
	var seen []string
	for d, err := range client.ListDeployments(t.Context(),
		platformapi.DeploymentFilter{}, platformapi.PageSize(3)) {
		if err != nil {
			t.Fatal(err)
		}
		if seen = append(seen, d.ID); len(seen) == 4 {
			break
		}
	}
	// Four items need two pages of three. The third page is never fetched.
	if n := len(fake.Requests()); n != 2 {
		t.Errorf("made %d requests, want 2", n)
	}
}

// END breaktest OMIT

// START errtest OMIT
func TestListErrorEndsIteration(t *testing.T) {
	client, fake := newClient(t)
	var items, errs int
	for _, err := range client.ListDeployments(t.Context(),
		platformapi.DeploymentFilter{}, platformapi.PageSize(3)) {
		if err != nil {
			errs++
			if !strings.Contains(err.Error(), "500") {
				t.Errorf("err = %v, want the injected 500", err)
			}
			continue // the iterator must end by itself after an error
		}
		if items++; items == 3 { // the next fetch will fail
			fake.FailNext(1, http.StatusInternalServerError, 0)
		}
	}
	if items != 3 || errs != 1 {
		t.Errorf("got %d items and %d errors, want 3 and 1", items, errs)
	}
}

// END errtest OMIT

func TestCollectReturnsPartialResultsOnError(t *testing.T) {
	client, _ := newClient(t)
	envs, err := platformapi.Collect(client.ListEnvironments(t.Context(),
		platformapi.PageSize(500)))
	if len(envs) != 0 {
		t.Errorf("got %d environments, want none", len(envs))
	}
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
		apiErr.Code != "invalid_argument" {
		t.Errorf("err = %v, want invalid_argument for page_size 500", err)
	}
}

func TestListServicesFiltersByTeam(t *testing.T) {
	client, _ := newClient(t)
	svcs, err := platformapi.Collect(client.ListServices(t.Context(),
		platformapi.ServiceFilter{Team: "payments"}))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, s := range svcs {
		names = append(names, s.Name)
	}
	if got := strings.Join(names, ","); got != "checkout,ledger" {
		t.Errorf("payments services = %s, want checkout,ledger", got)
	}
}
