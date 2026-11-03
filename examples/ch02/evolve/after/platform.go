// Package platform is a later release of the platform SDK's deployment
// API, with a mix of compatible and breaking changes for apidiff to find.
// Method bodies are stubs: apidiff looks only at the exported API.
package platform

import (
	"context"
	"errors"
	"iter"
	"time"
)

var errStub = errors.New("stub")

// DefaultPollInterval is how often Wait polls an operation.
const DefaultPollInterval = 5 * time.Second

// START tokensource OMIT

// TokenSource supplies bearer tokens.
type TokenSource interface {
	Token(ctx context.Context) (string, error)
	InvalidateToken(rejected string) // breaks every existing implementation
}

// END tokensource OMIT

// State is the lifecycle state of a deployment.
type State string

// Deployment is one rollout of a service version.
type Deployment struct {
	ID        string
	Service   string
	Version   string
	State     State             // replaces Status string
	CreatedBy string            // new field: compatible
	Labels    map[string]string // new field: Deployment is no longer comparable
}

// Client calls the platform API.
type Client struct{ baseURL string }

// An Option configures a Client.
type Option func(*Client)

// A CallOption configures one call.
type CallOption func()

// NewClient returns a Client for the API at baseURL.
func NewClient(baseURL string, opts ...Option) *Client {
	c := &Client{baseURL: baseURL}
	for _, o := range opts {
		o(c)
	}
	return c
}

// CreateDeployment starts rolling out version of service.
func (c *Client) CreateDeployment(ctx context.Context, service, version string,
	opts ...CallOption) (*Deployment, error) {

	return nil, errStub
}

// ListDeployments returns every deployment of service.
//
// Deprecated: Use Deployments, which fetches pages on demand.
func (c *Client) ListDeployments(ctx context.Context,
	service string) ([]Deployment, error) {

	return nil, errStub
}

// Deployments returns an iterator over the deployments of service.
func (c *Client) Deployments(ctx context.Context,
	service string) iter.Seq2[Deployment, error] {

	return func(yield func(Deployment, error) bool) { yield(Deployment{}, errStub) }
}
