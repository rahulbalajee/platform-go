// START imports OMIT
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
)

// END imports OMIT

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
// START retryerror OMIT
// RetryError is the error after every attempt failed. It wraps the last
// attempt's error, so errors.Is and errors.AsType still find the cause.
type RetryError struct {
	Attempts int   // how many times the call was tried
	Err      error // what the last attempt returned
}

func (e *RetryError) Error() string {
	return fmt.Sprintf("%d attempts, last: %v", e.Attempts, e.Err)
}

// Unwrap makes the last attempt's error part of the chain.
func (e *RetryError) Unwrap() error { return e.Err }

// END retryerror OMIT
// START client OMIT
// Client talks to the deployment API.
type Client struct {
	BaseURL  string
	Token    clierr.Secret // never printed, never logged
	HTTP     *http.Client
	Attempts int           // tries per call when a failure is temporary
	Backoff  time.Duration // pause before the second try; doubles after
	Log      *slog.Logger
}

// END client OMIT
// START do OMIT
// do sends one API call. A temporary failure is tried again, up to
// c.Attempts times with a doubling pause; anything else returns at once.
func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	delay := c.Backoff
	for attempt := 1; ; attempt++ {
		again, err := c.send(ctx, method, path, in, out)
		if err == nil || !again || ctx.Err() != nil {
			return err
		}
		if attempt >= c.Attempts {
			return &RetryError{Attempts: attempt, Err: err}
		}
		select {
		case <-time.After(delay):
			delay *= 2
		case <-ctx.Done():
			return err
		}
	}
}

// END do OMIT
// START send OMIT
// send makes one attempt and says whether another could succeed. Only this
// function knows the protocol, so it classifies its own failures.
func (c *Client) send(ctx context.Context, method, path string,
	in, out any) (again bool, err error) {

	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return false, err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, body)
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+string(c.Token))
	c.Log.DebugContext(ctx, "api call", "method", method, "path", path,
		"token", c.Token) // logs [REDACTED]

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return true, err // no answer (refused, reset, timed out): try again
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		apiErr := &APIError{Status: resp.StatusCode,
			RequestID: resp.Header.Get("X-Request-Id")}
		var problem struct{ Error string }
		_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&problem)
		apiErr.Message = problem.Error
		return apiErr.Temporary(), apiErr
	}
	if out == nil {
		return false, nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return false, fmt.Errorf("decode %s response: %w", path, err)
	}
	return false, nil
}

// END send OMIT
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
// START deploycall OMIT
// Deploy asks the API to roll service@version out to target.
func (c *Client) Deploy(ctx context.Context, target, service, version string) error {
	in := map[string]string{"service": service, "version": version}
	return c.do(ctx, http.MethodPost, "/v1/deploy/"+target, in, nil)
}

// newClient builds the API client from the config and the environment.
func newClient(cfg Config, getenv func(string) string, log *slog.Logger) *Client {
	return &Client{
		BaseURL:  cfg.API,
		Token:    clierr.Secret(getenv("DEPLOYCTL_TOKEN")),
		HTTP:     &http.Client{}, // no Timeout: deadlines come from the context
		Attempts: 3,
		Backoff:  100 * time.Millisecond,
		Log:      log,
	}
}

// END deploycall OMIT
