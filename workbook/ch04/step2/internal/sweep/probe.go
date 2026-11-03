package sweep

import (
	"context"
	"fmt"
	"io"
	"net/http"
)

// START http OMIT
// HTTPProber issues a GET and treats 2xx/3xx as healthy and anything else
// as down.
type HTTPProber struct {
	Client    *http.Client // must not set Timeout; deadlines come from ctx
	UserAgent string
}

// StatusError reports an unhealthy HTTP status.
type StatusError struct{ Code int }

func (e *StatusError) Error() string {
	return fmt.Sprintf("unhealthy status %d %s", e.Code, http.StatusText(e.Code))
}

func (p HTTPProber) Probe(ctx context.Context, t Target) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.URL.String(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", p.UserAgent)

	resp, err := p.Client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	// Read a bounded amount so the connection can be reused. (Go 1.27 also
	// drains on Close, but being explicit keeps behaviour version-independent.)
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))

	if resp.StatusCode >= 400 {
		return resp.Status, &StatusError{resp.StatusCode}
	}
	return resp.Status, nil
}

// END http OMIT
