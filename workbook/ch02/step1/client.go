// START client OMIT

package platformapi

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// Client calls the platform API. Create it with New; the zero value is not
// usable. A Client is safe for concurrent use and should be reused: it
// holds no per-call state, and its *http.Client pools connections.
type Client struct {
	base *url.URL
	hc   *http.Client
}

// New returns a Client for the API at baseURL, for example
// "https://platform.internal". New performs no I/O.
func New(baseURL string) (*Client, error) {
	base, err := parseBaseURL(baseURL)
	if err != nil {
		return nil, fmt.Errorf("platformapi.New: %w", err)
	}
	return &Client{
		base: base,
		hc:   &http.Client{}, // no Client.Timeout: contexts own deadlines
	}, nil
}

// END client OMIT

// START parse OMIT

func parseBaseURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	switch {
	case err != nil:
		return nil, fmt.Errorf("base URL: %w", err)
	case u.Scheme != "http" && u.Scheme != "https":
		return nil, fmt.Errorf("base URL %q: scheme must be http or https", raw)
	case u.Host == "":
		return nil, fmt.Errorf("base URL %q: missing host", raw)
	case u.RawQuery != "" || u.Fragment != "":
		return nil, fmt.Errorf("base URL %q: must not have a query or fragment", raw)
	}
	u.Path = strings.TrimSuffix(u.Path, "/")
	return u, nil
}

// END parse OMIT
