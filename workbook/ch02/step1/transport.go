// START transport OMIT

package platformapi

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// getJSON sends GET /v1/<path...> and decodes the JSON response into out,
// which must be a pointer.
func (c *Client) getJSON(ctx context.Context, out any, path ...string) error {
	u := c.url(path)
	call := "GET " + u.EscapedPath()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fmt.Errorf("platformapi: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("platformapi: %s: %w", call, err)
	}
	defer drain(resp)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("platformapi: %s: %s", call, resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("platformapi: %s: decoding response: %w", call, err)
	}
	return nil
}

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

// END transport OMIT
