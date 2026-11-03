// START imports OMIT

package platformapi

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"uuid"
)

// END imports OMIT

// START calloption OMIT

// A CallOption changes a single call. Call options and client options
// are different types, so passing one where the other belongs does not
// compile.
type CallOption func(*callConfig)

type callConfig struct {
	requestID      string
	idempotencyKey string
}

// IdempotencyKey sets the Idempotency-Key of a create call. By default
// each call gets a random key, which makes the client's own retries safe.
// Derive the key from something stable, such as a CI run ID, to make a
// create safe to repeat after your process restarts.
func IdempotencyKey(key string) CallOption {
	return func(c *callConfig) { c.idempotencyKey = key }
}

// RequestID sets the X-Request-Id sent with every attempt of the call.
// By default each call gets a new UUIDv7. Pass your own ID to correlate
// the platform's logs with yours.
func RequestID(id string) CallOption {
	return func(c *callConfig) { c.requestID = id }
}

// END calloption OMIT

// START request OMIT

// request describes one logical API call. It may take several attempts.
type request struct {
	method   string
	path     []string // segments after /v1/, escaped individually
	body     any      // JSON-encoded when non-nil
	needsKey bool     // send an Idempotency-Key
	call     callConfig
}

func newRequest(method string, opts []CallOption, path ...string) request {
	r := request{method: method, path: path}
	for _, o := range opts {
		o(&r.call)
	}
	return r
}

// url builds base + /v1/ + path. Each segment is escaped on its own, so
// an ID such as "../environments/prod" stays one segment.
func (c *Client) url(r request) *url.URL {
	u := c.base.Clone() // URL.Clone is new in Go 1.27
	esc := make([]string, len(r.path))
	for i, s := range r.path {
		esc[i] = url.PathEscape(s)
	}
	u.Path = c.base.Path + "/v1/" + strings.Join(r.path, "/")
	u.RawPath = c.base.EscapedPath() + "/v1/" + strings.Join(esc, "/")
	return u
}

// END request OMIT

// START do OMIT

// do sends r and returns a response with a 2xx status. The caller must
// close the response body.
func (c *Client) do(ctx context.Context, r request) (*http.Response, error) {
	var body []byte
	if r.body != nil {
		b, err := json.Marshal(r.body)
		if err != nil {
			return nil, fmt.Errorf("platformapi: encoding request: %w", err)
		}
		body = b
	}
	// One request ID and one idempotency key per call, shared by every
	// attempt: the server can de-duplicate, and its logs line up with ours.
	r.call.requestID = cmp.Or(r.call.requestID, uuid.NewV7().String())
	if r.needsKey {
		r.call.idempotencyKey = cmp.Or(r.call.idempotencyKey, uuid.New().String())
	}
	u := c.url(r)
	call := r.method + " " + u.EscapedPath()
	return c.attempt(ctx, r, u, call, body)
}

// END do OMIT

// START attempt OMIT

// attempt makes one attempt at r. A response with a 2xx status is
// returned as it is; any other status becomes an *APIError.
func (c *Client) attempt(ctx context.Context, r request, u *url.URL,
	call string, body []byte) (*http.Response, error) {

	if c.limiter != nil {
		if err := c.limiter.Wait(ctx); err != nil {
			return nil, fmt.Errorf("platformapi: %s: %w", call, err)
		}
	}
	start := time.Now()
	resp, err := c.send(ctx, r, u, body)
	if err != nil {
		return nil, err
	}
	c.log.LogAttrs(ctx, slog.LevelDebug, "request", slog.String("call", call),
		slog.Int("status", resp.StatusCode),
		slog.Duration("took", time.Since(start).Round(time.Millisecond)),
		slog.String("request_id", r.call.requestID))
	if resp.StatusCode < 300 {
		return resp, nil
	}
	apiErr := decodeError(resp, call)
	// A proxy may have dropped the header; we know the ID we sent.
	apiErr.RequestID = cmp.Or(apiErr.RequestID, r.call.requestID)
	return nil, apiErr
}

// END attempt OMIT

// START send OMIT

// send performs one HTTP exchange.
func (c *Client) send(ctx context.Context, r request, u *url.URL,
	body []byte) (*http.Response, error) {

	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, r.method, u.String(), rd)
	if err != nil {
		return nil, fmt.Errorf("platformapi: %w", err)
	}
	req.Header.Set("User-Agent", c.userAgent)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Request-Id", r.call.requestID)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if r.call.idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", r.call.idempotencyKey)
	}
	if c.tokens != nil {
		token, err := c.tokens.Token(ctx)
		if err != nil {
			return nil, fmt.Errorf("platformapi: getting token: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("platformapi: %s %s: %w",
			r.method, u.EscapedPath(), err)
	}
	return resp, nil
}

// END send OMIT

// drain reads and closes a response body we are discarding, so the
// connection can be reused.
func drain(resp *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
}

// decodeError turns a non-2xx response into an *APIError and closes the
// body. Servers and proxies do not always send the API's JSON error shape,
// so it falls back to the status text.
func decodeError(resp *http.Response, call string) *APIError {
	defer drain(resp)
	e := &APIError{
		StatusCode: resp.StatusCode,
		Op:         call,
		RequestID:  resp.Header.Get("X-Request-Id"),
	}
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var wire struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(data, &wire) == nil && wire.Error.Code != "" {
		e.Code, e.Message = wire.Error.Code, wire.Error.Message
	} else {
		text := http.StatusText(resp.StatusCode)
		e.Code = strings.ToLower(strings.ReplaceAll(text, " ", "_"))
		body := strings.TrimSpace(string(data[:min(len(data), 200)]))
		e.Message = cmp.Or(body, text)
	}
	if ra := resp.Header.Get("Retry-After"); ra != "" {
		if secs, err := strconv.Atoi(ra); err == nil && secs >= 0 {
			e.RetryAfter = time.Duration(secs) * time.Second
		} else if t, err := http.ParseTime(ra); err == nil {
			e.RetryAfter = max(time.Until(t), 0)
		}
	}
	return e
}

// START call OMIT

// call sends r and decodes the JSON response into a T. It is a generic
// method (Go 1.27): the result type varies per endpoint, the client does
// not, and the helper needs the client's configuration.
func (c *Client) call[T any](ctx context.Context, r request) (T, error) {
	var out T
	resp, err := c.do(ctx, r)
	if err != nil {
		return out, err
	}
	defer drain(resp)
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return out, fmt.Errorf("platformapi: %s %s: decoding response: %w",
			r.method, c.url(r).EscapedPath(), err)
	}
	return out, nil
}

// END call OMIT
