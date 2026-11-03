// START imports OMIT
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// END imports OMIT

// START client OMIT
// Client talks to the deployment API.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// END client OMIT
// START do OMIT
// do sends one API call and decodes the answer into out, if out isn't nil.
func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err // already says which request and why
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: %s", method, path, resp.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// END do OMIT
// START deploycall OMIT
// Deploy asks the API to roll service@version out to target.
func (c *Client) Deploy(ctx context.Context, target, service, version string) error {
	in := map[string]string{"service": service, "version": version}
	return c.do(ctx, http.MethodPost, "/v1/deploy/"+target, in, nil)
}

// newClient builds the API client from the config and the environment.
func newClient(cfg Config, getenv func(string) string) *Client {
	return &Client{
		BaseURL: cfg.API,
		Token:   getenv("DEPLOYCTL_TOKEN"),
		HTTP:    &http.Client{}, // no Timeout: deadlines come from the context
	}
}

// END deploycall OMIT
