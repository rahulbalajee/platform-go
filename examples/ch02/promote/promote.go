// Package promote is a small consumer of platformapi, written the way the
// ship CLI uses it: it declares the narrow interface it needs.
package promote

import (
	"context"
	"fmt"
	"iter"

	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// START platform OMIT

// Platform is the part of the platform API that Promote needs. It is
// declared here, by the consumer, not by platformapi, so it lists only
// what this package calls, and tests can satisfy it with a small stub.
type Platform interface {
	ListDeployments(ctx context.Context, f platformapi.DeploymentFilter,
		opts ...platformapi.CallOption) iter.Seq2[platformapi.Deployment, error]
	CreateDeployment(ctx context.Context, req platformapi.CreateDeploymentRequest,
		opts ...platformapi.CallOption,
	) (*platformapi.Operation[platformapi.Deployment], error)
	WaitDeployment(ctx context.Context,
		op *platformapi.Operation[platformapi.Deployment],
	) (*platformapi.Deployment, error)
}

// END platform OMIT

// START adapter OMIT

// Client adapts *platformapi.Client to Platform. Client.Wait is a generic
// method, and a generic method cannot satisfy an interface method, so
// the adapter supplies an instantiated one.
type Client struct{ *platformapi.Client }

// WaitDeployment waits for a deployment operation.
func (c Client) WaitDeployment(ctx context.Context,
	op *platformapi.Operation[platformapi.Deployment],
) (*platformapi.Deployment, error) {
	return c.Wait(ctx, op)
}

// END adapter OMIT

// START promote OMIT

// Promote deploys to env "to" the version of service that most recently
// succeeded in env "from", and waits for the rollout.
func Promote(ctx context.Context, p Platform,
	service, from, to string) (*platformapi.Deployment, error) {

	f := platformapi.DeploymentFilter{
		Service: service, Environment: from, State: platformapi.StateSucceeded,
	}
	var version string
	for d, err := range p.ListDeployments(ctx, f, platformapi.PageSize(1)) {
		if err != nil {
			return nil, fmt.Errorf("finding the %s version in %s: %w", service, from, err)
		}
		version = d.Version
		break // newest first: the first item is all we need
	}
	if version == "" {
		return nil, fmt.Errorf("%s has no successful deployment in %s", service, from)
	}
	op, err := p.CreateDeployment(ctx, platformapi.CreateDeploymentRequest{
		Service: service, Environment: to, Version: version,
		Reason: "promoted from " + from,
	})
	if err != nil {
		return nil, fmt.Errorf("promoting %s %s to %s: %w", service, version, to, err)
	}
	return p.WaitDeployment(ctx, op)
}

// END promote OMIT
