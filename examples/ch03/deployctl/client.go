package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/rahulbalajee/platform-go/pkg/clierr"
	"github.com/rahulbalajee/platform-go/pkg/retry"
)

// START apierror OMIT
// APIError is a non-2xx answer from the deployment API. It keeps what the
// API said and the request ID, which is what the API's owners need to
// find the request in their logs.
type APIError struct {
	Status    int    // HTTP status code
	Message   string // the API's own explanation
	RequestID string // X-Request-Id
}

// Error includes the request ID so it reaches operator logs.
func (e *APIError) Error() string {
	return fmt.Sprintf("HTTP %d: %s (request %s)", e.Status, e.Message, e.RequestID)
}

// Temporary reports whether retrying could help: 429 and 5xx.
func (e *APIError) Temporary() bool {
	return e.Status == http.StatusTooManyRequests || e.Status >= 500
}

// END apierror OMIT

// Client talks to the deployment API.
type Client struct {
	BaseURL string
	Token   clierr.Secret // never printed, never logged
	HTTP    *http.Client
	Retry   retry.Policy
	Log     *slog.Logger
}

// START do OMIT
// do sends one API call with retries. Transport errors and temporary API
// errors are retried; everything else is wrapped in retry.Permanent, which
// stays transparent to errors.Is/As.
func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	return c.Retry.Do(ctx, func(ctx context.Context) error {
		var body io.Reader
		if in != nil {
			b, err := json.Marshal(in)
			if err != nil {
				return retry.Permanent(err)
			}
			body = bytes.NewReader(b)
		}
		req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
		if err != nil {
			return retry.Permanent(err)
		}
		req.Header.Set("Authorization", "Bearer "+string(c.Token))
		c.Log.DebugContext(ctx, "api call", "method", method, "path", path,
			"token", c.Token) // logs [REDACTED]

		resp, err := c.HTTP.Do(req)
		if err != nil {
			return err // dial, TLS, timeout: worth another attempt
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			apiErr := &APIError{Status: resp.StatusCode,
				RequestID: resp.Header.Get("X-Request-Id")}
			var problem struct{ Error string }
			_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&problem)
			apiErr.Message = problem.Error
			if apiErr.Temporary() {
				return apiErr
			}
			return retry.Permanent(apiErr)
		}
		if out == nil {
			return nil
		}
		return retry.Permanent(json.NewDecoder(resp.Body).Decode(out))
	})
}

// END do OMIT

// START auth OMIT
// checkAuth asks the API who we are before doing anything else, so a bad
// token fails once, up front, instead of once per target halfway through
// a rollout.
func (c *Client) checkAuth(ctx context.Context) error {
	if c.Token == "" {
		return &clierr.Error{Code: clierr.ExitNoPerm, ID: "DPL-AUTH",
			Message: "no API token: DEPLOYCTL_TOKEN is not set",
			Hint:    "export DEPLOYCTL_TOKEN with a token from the platform portal",
			Docs:    docs + "#dpl-auth"}
	}
	err := c.do(ctx, http.MethodGet, "/v1/whoami", nil, nil)
	apiErr, ok := errors.AsType[*APIError](err)
	if !ok || (apiErr.Status != 401 && apiErr.Status != 403) {
		return err // nil, or not an auth problem: let the caller classify it
	}
	msg := "the deploy API rejected your token"
	if apiErr.Status == http.StatusForbidden {
		msg = "your token is not allowed to deploy"
	}
	return &clierr.Error{
		Code:    clierr.ExitNoPerm,
		ID:      "DPL-AUTH",
		Message: fmt.Sprintf("%s (HTTP %d)", msg, apiErr.Status),
		Hint: fmt.Sprintf("export a fresh DEPLOYCTL_TOKEN; quote %s if you "+
			"ask for help", apiErr.RequestID),
		Docs: docs + "#dpl-auth",
		Err:  err,
	}
}

// END auth OMIT

// Deploy asks the API to roll service@version out to target.
func (c *Client) Deploy(ctx context.Context, target, service, version string) error {
	in := map[string]string{"service": service, "version": version}
	return c.do(ctx, http.MethodPost, "/v1/deploy/"+target, in, nil)
}

// newClient builds the API client from the config and the environment.
func newClient(cfg Config, getenv func(string) string, log *slog.Logger) *Client {
	return &Client{
		BaseURL: cfg.API,
		Token:   clierr.Secret(getenv("DEPLOYCTL_TOKEN")),
		// No Client.Timeout: deadlines come from the context.
		HTTP: &http.Client{},
		Retry: retry.Policy{
			MaxAttempts: 3,
			BaseDelay:   100 * time.Millisecond,
			MaxDelay:    time.Second,
		},
		Log: log,
	}
}
