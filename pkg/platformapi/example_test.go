// START head OMIT

package platformapi_test

import (
	"context"
	"errors"
	"fmt"
	"net/http/httptest"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
)

// END head OMIT

// START example OMIT

// Deploy a new version to staging and wait for the rollout to finish.
func Example() {
	fake := platformapifake.New() // stands in for https://platform.internal
	srv := httptest.NewServer(fake)
	defer srv.Close()

	ctx := context.Background()
	client, err := platformapi.New(srv.URL,
		platformapi.WithUserAgent("example/1.0"),
		platformapi.WithPollInterval(10*time.Millisecond),
	)
	if err != nil {
		fmt.Println(err)
		return
	}
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "checkout", Environment: "staging", Version: "v1.5.0",
	})
	if err != nil {
		fmt.Println(err)
		return
	}
	d, err := client.Wait(ctx, op)
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Println(d.ID, d.Service, d.Version, d.State)
	// Output: d-9 checkout v1.5.0 succeeded
}

// END example OMIT

// START examplelist OMIT

// Show the three most recent staging deployments. The loop stops after
// three items, so only the first page is fetched.
func ExampleClient_ListDeployments() {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	client, err := platformapi.New(srv.URL)
	if err != nil {
		fmt.Println(err)
		return
	}

	f := platformapi.DeploymentFilter{Service: "checkout", Environment: "staging"}
	n := 0
	for d, err := range client.ListDeployments(context.Background(), f) {
		if err != nil {
			fmt.Println(err)
			return
		}
		fmt.Println(d.ID, d.Version, d.State)
		if n++; n == 3 {
			break
		}
	}
	// Output:
	// d-8 v1.4.1 succeeded
	// d-6 v1.4.0 succeeded
	// d-4 v1.3.1 succeeded
}

// END examplelist OMIT

// START poll OMIT

// Follow a rollout's progress with Poll.
func ExampleClient_Poll() {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	ctx := context.Background()
	client, err := platformapi.New(srv.URL,
		platformapi.WithPollInterval(10*time.Millisecond))
	if err != nil {
		fmt.Println(err)
		return
	}
	op, err := client.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: "ledger", Environment: "dev", Version: "v2.0.1",
	})
	if err != nil {
		fmt.Println(err)
		return
	}
	for snap, err := range client.Poll(ctx, op) {
		if err != nil {
			fmt.Println(err)
			return
		}
		fmt.Printf("%s %s\n", snap.ID, snap.Message)
	}
	// Output:
	// op-9 rolling out v2.0.1: 1/2 replicas updated
	// op-9 rolling out v2.0.1: 2/2 replicas updated
}

// END poll OMIT

// START apierror OMIT

// Check for a missing deployment with errors.Is, and read the details
// from the *APIError.
func ExampleAPIError() {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	client, err := platformapi.New(srv.URL)
	if err != nil {
		fmt.Println(err)
		return
	}

	_, err = client.GetDeployment(context.Background(), "d-404",
		platformapi.RequestID("req-1234"))
	if errors.Is(err, platformapi.ErrNotFound) {
		apiErr, _ := errors.AsType[*platformapi.APIError](err)
		fmt.Println(apiErr.StatusCode, apiErr.Code, apiErr.RequestID)
	}
	// Output: 404 not_found req-1234
}

// END apierror OMIT
