// START head OMIT

package platformapi_test

import (
	"bufio"
	"context"
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

// END head OMIT

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
			if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
				apiErr.StatusCode != http.StatusUnauthorized {
				t.Errorf("err = %v, want a 401", err)
			}
			continue // the iterator must end by itself after an error
		}
		if items++; items == 3 { // credentials rotate: the next fetch fails
			fake.RequireToken("rotated")
		}
	}
	if items != 3 || errs != 1 {
		t.Errorf("got %d items and %d errors, want 3 and 1", items, errs)
	}
}

// END errtest OMIT

// START collecttest OMIT
func TestCollectReturnsPartialResults(t *testing.T) {
	calls := 0
	expiring := platformapi.TokenSourceFunc(func(context.Context) (string, error) {
		if calls++; calls > 1 {
			return "expired", nil
		}
		return "test-token", nil
	})
	client, _ := newClient(t, platformapi.WithTokenSource(expiring))
	got, err := platformapi.Collect(client.ListDeployments(t.Context(),
		platformapi.DeploymentFilter{}, platformapi.PageSize(3)))
	if len(got) != 3 || err == nil {
		t.Errorf("got %d items, err %v; want the first page and a 401", len(got), err)
	}
}

func TestBadPageSizeIsAnAPIError(t *testing.T) {
	client, _ := newClient(t)
	envs, err := platformapi.Collect(client.ListEnvironments(t.Context(),
		platformapi.PageSize(500)))
	if apiErr, ok := errors.AsType[*platformapi.APIError](err); !ok ||
		apiErr.Code != "invalid_argument" || len(envs) != 0 {
		t.Errorf("got %d environments, err %v; want invalid_argument", len(envs), err)
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

// END collecttest OMIT

// START logstest OMIT
func TestDeploymentLogsStream(t *testing.T) {
	client, _ := newClient(t)
	logs, err := client.DeploymentLogs(t.Context(), "d-8")
	if err != nil {
		t.Fatal(err)
	}
	defer logs.Close()
	var lines []string
	sc := bufio.NewScanner(logs) // any io.Reader will do
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if len(lines) != 6 || lines[0] != "d-8 rollout of checkout v1.4.1 to staging" ||
		lines[5] != "d-8 state: succeeded" {
		t.Errorf("log =\n%s", strings.Join(lines, "\n"))
	}
}

// END logstest OMIT
