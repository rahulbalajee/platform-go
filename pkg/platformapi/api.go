package platformapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"iter"
	"net/http"
	"net/url"
)

// checkID rejects identifiers that would change the meaning of a URL path.
func checkID(kind, id string) error {
	if id == "" || id == "." || id == ".." {
		return fmt.Errorf("platformapi: invalid %s ID %q", kind, id)
	}
	return nil
}

// ListEnvironments returns an iterator over all environments.
func (c *Client) ListEnvironments(ctx context.Context,
	opts ...CallOption) iter.Seq2[Environment, error] {

	return c.list[Environment](ctx, nil, opts, "environments")
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

// ListServices returns an iterator over the services that match f.
func (c *Client) ListServices(ctx context.Context, f ServiceFilter,
	opts ...CallOption) iter.Seq2[Service, error] {

	q := url.Values{}
	if f.Team != "" {
		q.Set("team", f.Team)
	}
	return c.list[Service](ctx, q, opts, "services")
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

// START listdeployments OMIT

// ListDeployments returns an iterator over the deployments that match f,
// newest first. Pages are fetched as the loop consumes them:
//
//	for d, err := range client.ListDeployments(ctx, f) {
//		if err != nil {
//			return err
//		}
//		fmt.Println(d.ID, d.State)
//	}
func (c *Client) ListDeployments(ctx context.Context, f DeploymentFilter,
	opts ...CallOption) iter.Seq2[Deployment, error] {

	q := url.Values{}
	for k, v := range map[string]string{
		"service": f.Service, "environment": f.Environment, "state": string(f.State),
	} {
		if v != "" {
			q.Set(k, v)
		}
	}
	return c.list[Deployment](ctx, q, opts, "deployments")
}

// END listdeployments OMIT

// GetDeployment returns deployment id. The error matches ErrNotFound if it
// does not exist.
func (c *Client) GetDeployment(ctx context.Context, id string,
	opts ...CallOption) (*Deployment, error) {

	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	return c.call[*Deployment](ctx, newRequest("GET", opts, "deployments", id))
}

// START create OMIT

// CreateDeployment starts rolling out req.Version of req.Service to
// req.Environment and returns the long-running operation; use Wait or Poll
// to follow it. The error matches ErrConflict if the service is already
// being deployed to that environment.
//
// Every attempt carries the same Idempotency-Key, so a retry after a lost
// response cannot start a second rollout. See IdempotencyKey.
func (c *Client) CreateDeployment(ctx context.Context, req CreateDeploymentRequest,
	opts ...CallOption) (*Operation[Deployment], error) {

	var missing []error
	for _, f := range [...]struct{ name, value string }{
		{"Service", req.Service}, {"Environment", req.Environment}, {"Version", req.Version},
	} {
		if f.value == "" {
			missing = append(missing, fmt.Errorf("%s is required", f.name))
		}
	}
	if err := errors.Join(missing...); err != nil {
		return nil, fmt.Errorf("platformapi: CreateDeployment: %w", err)
	}
	r := newRequest(http.MethodPost, opts, "deployments")
	r.body, r.needsKey, r.idempotent = req, true, true
	return c.call[*Operation[Deployment]](ctx, r)
}

// END create OMIT

// CancelDeployment asks the platform to stop deployment id and returns its
// new state. Cancelling a cancelled deployment succeeds; cancelling a
// finished one fails with an error matching ErrConflict.
func (c *Client) CancelDeployment(ctx context.Context, id string,
	opts ...CallOption) (*Deployment, error) {

	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	r := newRequest(http.MethodPost, opts, "deployments", id, "cancel")
	r.idempotent = true // cancelling twice is harmless
	return c.call[*Deployment](ctx, r)
}

// START logs OMIT

// DeploymentLogs streams the rollout log of deployment id. The caller must
// close the returned reader. Returning an io.ReadCloser instead of a
// []byte or []string lets callers copy, scan, or tee a log of any size in
// constant memory.
func (c *Client) DeploymentLogs(ctx context.Context, id string,
	opts ...CallOption) (io.ReadCloser, error) {

	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	resp, err := c.do(ctx, newRequest("GET", opts, "deployments", id, "logs"))
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// END logs OMIT
