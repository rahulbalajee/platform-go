package buildinfo

import "net/http"

// START transport OMIT

// Transport returns an http.RoundTripper that sends requests through base
// (http.DefaultTransport if base is nil) with User-Agent set to
// i.UserAgent(), unless the caller has already set one.
func (i Info) Transport(base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &userAgent{base: base, value: i.UserAgent()}
}

type userAgent struct {
	base  http.RoundTripper
	value string
}

// RoundTrip implements http.RoundTripper. A RoundTripper must not modify
// the request it is given, so the header goes on a clone.
func (u *userAgent) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Header.Get("User-Agent") != "" {
		return u.base.RoundTrip(req)
	}
	r := req.Clone(req.Context())
	r.Header.Set("User-Agent", u.value)
	return u.base.RoundTrip(r)
}

// END transport OMIT
