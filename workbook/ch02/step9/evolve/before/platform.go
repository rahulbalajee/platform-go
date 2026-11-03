// Package platform is the first release of the platform SDK's deployment
// API, kept so apidiff can compare it with ../after. Method bodies are
// stubs: apidiff looks only at the exported API.
package platform

import (
	"context"
	"errors"
	"time"
)

var errStub = errors.New("stub")

// DefaultPollInterval is how often Wait polls an operation.
const DefaultPollInterval = 2 * time.Second

// TokenSource supplies bearer tokens.
type TokenSource interface {
	Token(ctx context.Context) (string, error)
}

// Deployment is one rollout of a service version.
type Deployment struct {
	ID      string
	Service string
	Version string
	Status  string
}

// Client calls the platform API.
type Client struct{ baseURL string }

// NewClient returns a Client for the API at baseURL.
func NewClient(baseURL string) *Client { return &Client{baseURL: baseURL} }

// CreateDeployment starts rolling out version of service.
func (c *Client) CreateDeployment(ctx context.Context,
	service, version string) (*Deployment, error) {

	return nil, errStub
}

// ListDeployments returns every deployment of service.
func (c *Client) ListDeployments(ctx context.Context,
	service string) ([]Deployment, error) {

	return nil, errStub
}
