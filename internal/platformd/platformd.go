// START head OMIT

// Package platformd assembles the development platform that `platformd`
// serves and plat's tests run against: the in-memory platform API
// (platformapifake), the dev OpenID Connect provider (devidp) on the same
// origin, and an authentication middleware in front of the API.
package platformd

// END head OMIT
// START imports OMIT

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"

	"github.com/rahulbalajee/platform-go/pkg/devidp"
	"github.com/rahulbalajee/platform-go/pkg/platformapi/platformapifake"
)

// END imports OMIT
// START options OMIT

// Audience is the "aud" that access tokens for the platform API carry.
const Audience = "platform"

// Options configure a Server.
type Options struct {
	Issuer      string        // the server's own URL; tokens' "iss"
	Auth        string        // "oidc" (default), "token" or "none"
	Token       string        // the static token for Auth "token"
	AutoApprove string        // approve every login as this user
	Interval    int           // device polling interval, seconds (default 5)
	TokenTTL    time.Duration // access token lifetime (default 10m)

	// GitHub also accepts GitHub user access tokens, checked against the
	// GitHub API (GitHubAPI, default https://api.github.com).
	GitHub    bool
	GitHubAPI string

	HTTPClient *http.Client // for JWKS and GitHub calls; default http.DefaultClient
	Log        *slog.Logger // request log; default discards
}

// END options OMIT
// START server OMIT

// Server is the development platform. It is an http.Handler.
type Server struct {
	API *platformapifake.Server
	IDP *devidp.Provider

	opts     Options
	mux      *http.ServeMux
	verifier *oidc.IDTokenVerifier
	github   *githubCache
}

// New returns a Server for opts.
func New(opts Options) (*Server, error) {
	if opts.Issuer == "" {
		return nil, errors.New("platformd: Issuer is required")
	}
	if opts.HTTPClient == nil {
		opts.HTTPClient = http.DefaultClient
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	if opts.GitHubAPI == "" {
		opts.GitHubAPI = "https://api.github.com"
	}
	s := &Server{
		API: platformapifake.New(),
		IDP: &devidp.Provider{Issuer: opts.Issuer, Audience: Audience,
			AccessTTL: opts.TokenTTL, Interval: opts.Interval,
			AutoApprove: opts.AutoApprove},
		opts:   opts,
		mux:    http.NewServeMux(),
		github: &githubCache{entries: map[[32]byte]githubEntry{}},
	}
	// The verifier fetches the provider's keys over HTTP, as any resource
	// server would, and caches them; it only runs once the server serves.
	ctx := oidc.ClientContext(context.Background(), opts.HTTPClient)
	keys := oidc.NewRemoteKeySet(ctx, opts.Issuer+devidp.JWKSPath)
	s.verifier = oidc.NewVerifier(opts.Issuer, keys,
		&oidc.Config{ClientID: Audience})

	switch opts.Auth {
	case "", "oidc", "token", "none":
	default:
		return nil, fmt.Errorf("platformd: unknown auth mode %q", opts.Auth)
	}
	s.mux.Handle("/v1/", s.authenticate(s.API))
	s.mux.Handle("/", s.IDP)
	return s, nil
}

// ServeHTTP serves the API and the identity provider, logging each request.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	s.mux.ServeHTTP(w, r)
	s.opts.Log.Info("request", "method", r.Method, "path", r.URL.Path,
		"took", time.Since(start).Round(time.Microsecond))
}

// END server OMIT
// START authenticate OMIT

// authenticate admits a request whose bearer token is valid, and answers
// 401 in the API's own error format otherwise, so the SDK reports it like
// any other API error.
func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.opts.Auth == "none" {
			next.ServeHTTP(w, r)
			return
		}
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			unauthorized(w, "missing bearer token")
			return
		}
		who, err := s.identify(r.Context(), token)
		if err != nil {
			unauthorized(w, err.Error())
			return
		}
		s.opts.Log.Debug("authenticated", "subject", who, "path", r.URL.Path)
		next.ServeHTTP(w, r)
	})
}

// identify returns who token belongs to. A JWT must be one this server's
// provider signed for the platform audience and not yet expired; with
// GitHub enabled, anything else is tried as a GitHub user token.
func (s *Server) identify(ctx context.Context, token string) (string, error) {
	if s.opts.Auth == "token" {
		if token != s.opts.Token {
			return "", errors.New("invalid token")
		}
		return "static-token", nil
	}
	if strings.Count(token, ".") == 2 { // header.payload.signature
		t, err := s.verifier.Verify(ctx, token)
		if err != nil {
			return "", fmt.Errorf("invalid token: %w", err)
		}
		return t.Subject, nil
	}
	if s.opts.GitHub {
		return s.githubUser(ctx, token)
	}
	return "", errors.New("invalid token: not a JWT from this platform")
}

func unauthorized(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("WWW-Authenticate", `Bearer realm="platform"`)
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]map[string]string{
		"error": {"code": "unauthenticated", "message": msg}})
}

// END authenticate OMIT
// START github OMIT

// githubCache remembers which GitHub tokens were valid, keyed by their
// SHA-256 so the tokens themselves are never kept, for five minutes: long
// enough that a deploy's polling doesn't call GitHub every second, short
// enough that a revoked token stops working soon.
type githubCache struct {
	mu      sync.Mutex
	entries map[[32]byte]githubEntry
}

type githubEntry struct {
	login   string
	expires time.Time
}

// githubUser asks GitHub whose token this is (GET /user). This is how a
// platform can accept "log in with GitHub" without issuing tokens itself.
func (s *Server) githubUser(ctx context.Context, token string) (string, error) {
	key := sha256.Sum256([]byte(token))
	s.github.mu.Lock()
	e, ok := s.github.entries[key]
	s.github.mu.Unlock()
	if ok && time.Now().Before(e.expires) {
		return e.login, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		s.opts.GitHubAPI+"/user", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := s.opts.HTTPClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("checking the token with GitHub: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub rejected the token (%s)", resp.Status)
	}
	var u struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&u); err != nil {
		return "", fmt.Errorf("unexpected answer from GitHub: %w", err)
	}
	if u.Login == "" {
		return "", errors.New("unexpected answer from GitHub: no login")
	}
	who := "github:" + u.Login
	s.github.mu.Lock()
	s.github.entries[key] = githubEntry{who, time.Now().Add(5 * time.Minute)}
	s.github.mu.Unlock()
	return who, nil
}

// END github OMIT
