// START imports OMIT

package platformapi

import (
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
)

// END imports OMIT

// START getjson OMIT

// getJSON sends GET /v1/<path...> and decodes the JSON response into out,
// which must be a pointer.
func (c *Client) getJSON(ctx context.Context, out any, path ...string) error {
	u := c.url(path)
	call := "GET " + u.EscapedPath()
	if c.limiter != nil {
		if err := c.limiter.Wait(ctx); err != nil {
			return fmt.Errorf("platformapi: %s: %w", call, err)
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fmt.Errorf("platformapi: %w", err)
	}
	req.Header.Set("User-Agent", c.userAgent)
	req.Header.Set("Accept", "application/json")
	if c.tokens != nil {
		token, err := c.tokens.Token(ctx)
		if err != nil {
			return fmt.Errorf("platformapi: getting token: %w", err)
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}
	start := time.Now()
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("platformapi: %s: %w", call, err)
	}
	c.log.LogAttrs(ctx, slog.LevelDebug, "request", slog.String("call", call),
		slog.Int("status", resp.StatusCode),
		slog.Duration("took", time.Since(start).Round(time.Millisecond)))
	if resp.StatusCode >= 300 {
		return decodeError(resp, call) // closes the body
	}
	defer drain(resp)
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("platformapi: %s: decoding response: %w", call, err)
	}
	return nil
}

// END getjson OMIT

// url builds base + /v1/ + path. Each segment is escaped on its own, so
// an ID such as "../environments/prod" stays one segment.
func (c *Client) url(path []string) *url.URL {
	u := c.base.Clone() // URL.Clone is new in Go 1.27
	esc := make([]string, len(path))
	for i, s := range path {
		esc[i] = url.PathEscape(s)
	}
	u.Path = c.base.Path + "/v1/" + strings.Join(path, "/")
	u.RawPath = c.base.EscapedPath() + "/v1/" + strings.Join(esc, "/")
	return u
}

// drain reads and closes a response body we are discarding, so the
// connection can be reused.
func drain(resp *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
}

// START decode OMIT

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

// END decode OMIT
