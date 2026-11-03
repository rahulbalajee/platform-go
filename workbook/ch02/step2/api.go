// START api OMIT

package platformapi

import (
	"context"
	"fmt"
)

// checkID rejects identifiers that would change the meaning of a URL path.
func checkID(kind, id string) error {
	if id == "" || id == "." || id == ".." {
		return fmt.Errorf("platformapi: invalid %s ID %q", kind, id)
	}
	return nil
}

// GetEnvironment returns the named environment.
func (c *Client) GetEnvironment(ctx context.Context,
	name string) (*Environment, error) {

	if err := checkID("environment", name); err != nil {
		return nil, err
	}
	var env Environment
	if err := c.getJSON(ctx, &env, "environments", name); err != nil {
		return nil, err
	}
	return &env, nil
}

// GetService returns the named service.
func (c *Client) GetService(ctx context.Context, name string) (*Service, error) {
	if err := checkID("service", name); err != nil {
		return nil, err
	}
	var svc Service
	if err := c.getJSON(ctx, &svc, "services", name); err != nil {
		return nil, err
	}
	return &svc, nil
}

// GetDeployment returns deployment id.
func (c *Client) GetDeployment(ctx context.Context, id string) (*Deployment, error) {
	if err := checkID("deployment", id); err != nil {
		return nil, err
	}
	var d Deployment
	if err := c.getJSON(ctx, &d, "deployments", id); err != nil {
		return nil, err
	}
	return &d, nil
}

// END api OMIT
