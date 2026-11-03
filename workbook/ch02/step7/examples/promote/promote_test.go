// START head OMIT

package promote

import (
	"context"
	"errors"
	"iter"
	"net/http/httptest"
	"testing"
	"time"

	"platformapi"
	"platformapi/platformapifake"
)

// END head OMIT

// START stub OMIT

// stub implements promote.Platform in a few lines, because the interface
// has three methods rather than the SDK's eleven.
type stub struct {
	history []platformapi.Deployment
	created []platformapi.CreateDeploymentRequest
}

func (s *stub) ListDeployments(context.Context, platformapi.DeploymentFilter,
	...platformapi.CallOption) iter.Seq2[platformapi.Deployment, error] {

	return func(yield func(platformapi.Deployment, error) bool) {
		for _, d := range s.history {
			if !yield(d, nil) {
				return
			}
		}
	}
}

func (s *stub) CreateDeployment(_ context.Context,
	req platformapi.CreateDeploymentRequest, _ ...platformapi.CallOption,
) (*platformapi.Operation[platformapi.Deployment], error) {
	s.created = append(s.created, req)
	return &platformapi.Operation[platformapi.Deployment]{ID: "op-1"}, nil
}

func (s *stub) WaitDeployment(context.Context,
	*platformapi.Operation[platformapi.Deployment]) (*platformapi.Deployment, error) {

	return &platformapi.Deployment{State: platformapi.StateSucceeded}, nil
}

// END stub OMIT

// START stubtest OMIT
func TestPromotePicksNewestSuccessfulVersion(t *testing.T) {
	s := &stub{history: []platformapi.Deployment{
		{Version: "v1.4.1"}, {Version: "v1.4.0"}, // newest first
	}}
	_, err := Promote(t.Context(), s, "checkout", "staging", "prod")
	if err != nil {
		t.Fatal(err)
	}
	if len(s.created) != 1 || s.created[0].Version != "v1.4.1" {
		t.Errorf("created %+v, want one deployment of v1.4.1", s.created)
	}
}

// END stubtest OMIT

// START faketest OMIT
func TestPromoteWithoutHistoryFails(t *testing.T) {
	s := &stub{}
	if _, err := Promote(t.Context(), s, "checkout", "staging", "prod"); err == nil {
		t.Fatal("promoted a service with no successful deployment")
	}
	if len(s.created) != 0 {
		t.Errorf("created %+v", s.created)
	}
}

// The same function against the real client and the fake platform.
func TestPromoteAgainstFakePlatform(t *testing.T) {
	srv := httptest.NewServer(platformapifake.New())
	defer srv.Close()
	client, err := platformapi.New(srv.URL,
		platformapi.WithPollInterval(time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	d, err := Promote(t.Context(), Client{Client: client},
		"checkout", "staging", "prod")
	if err != nil {
		t.Fatal(err)
	}
	if d.Environment != "prod" || d.Version != "v1.4.1" ||
		d.State != platformapi.StateSucceeded {
		t.Errorf("deployment = %+v", d)
	}
	_, err = Promote(t.Context(), Client{Client: client}, "ledger", "staging", "prod")
	if err == nil || errors.Is(err, platformapi.ErrNotFound) {
		t.Errorf("ledger has never been deployed: err = %v", err)
	}
}

// END faketest OMIT
