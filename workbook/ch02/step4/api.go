// START gets OMIT

package platformapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
)

// checkID rejects identifiers that would change the meaning of a URL path.
func checkID(kind, id string) error {
	if id == "" || id == "." || id == ".." {
		return fmt.Errorf("platformapi: invalid %s ID %q", kind, id)
	}
	return nil
}

// GetEnvironment returns the named environment. The error matches
// ErrNotFound if it does not exist.
func (c *Client) GetEnvironment(ctx context.Context, name string,
	opts ...CallOption) (*Environment, error) {

	if err := checkID("environment", name); err != nil {
		return nil, err
	}
	return c.call[*Environment](ctx, newRequest("GET", opts, "environments", name))
}

// GetService returns the named service. The error matches ErrNotFound if
// it does not exist.
func (c *Client) GetService(ctx context.Context, name string,
	opts ...CallOption) (*Service, error) {

	if err := checkID("service", name); err != nil {
		return nil, err
	}
	return c.call[*Service](ctx, newRequest("GET", opts, "services", name))
}

// GetDeployment returns deployment id. The error matches ErrNotFound if it
// does not exist.
func (c *Client) GetDeployment(ctx context.Context, id string,
	opts ...CallOption) (*Deployment, error) {

	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	return c.call[*Deployment](ctx, newRequest("GET", opts, "deployments", id))
}

// END gets OMIT

// START create OMIT

// CreateDeployment starts rolling out req.Version of req.Service to
// req.Environment and returns the long-running operation. The error
// matches ErrConflict if the service is already being deployed to that
// environment.
//
// Every attempt carries the same Idempotency-Key, so a retry after a lost
// response cannot start a second rollout. See IdempotencyKey.
func (c *Client) CreateDeployment(ctx context.Context, req CreateDeploymentRequest,
	opts ...CallOption) (*Operation[Deployment], error) {

	var missing []error
	for _, f := range [...]struct{ name, value string }{
		{"Service", req.Service},
		{"Environment", req.Environment},
		{"Version", req.Version},
	} {
		if f.value == "" {
			missing = append(missing, fmt.Errorf("%s is required", f.name))
		}
	}
	if err := errors.Join(missing...); err != nil {
		return nil, fmt.Errorf("platformapi: CreateDeployment: %w", err)
	}
	r := newRequest(http.MethodPost, opts, "deployments")
	r.body, r.needsKey = req, true
	return c.call[*Operation[Deployment]](ctx, r)
}

// END create OMIT

// START cancel OMIT

// CancelDeployment asks the platform to stop deployment id and returns its
// new state. Cancelling a cancelled deployment succeeds; cancelling a
// finished one fails with an error matching ErrConflict.
func (c *Client) CancelDeployment(ctx context.Context, id string,
	opts ...CallOption) (*Deployment, error) {

	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	r := newRequest(http.MethodPost, opts, "deployments", id, "cancel")
	return c.call[*Deployment](ctx, r)
}

// END cancel OMIT
