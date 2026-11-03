// START imports OMIT

// Package platformapifake is an in-memory implementation of the platform
// API for tests and demos, in the spirit of net/http/httptest. A Server is
// an http.Handler: serve it with httptest.NewServer or any http.Server.
package platformapifake

import (
	"cmp"
	"encoding/json"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"
)

// END imports OMIT

// Request is one request the fake received, for assertions in tests.
type Request struct {
	Method         string
	Path           string // path and query
	RequestID      string
	IdempotencyKey string
	UserAgent      string
	Authorization  string
}

// START server OMIT

type failure struct {
	status     int
	retryAfter time.Duration
}

// Server is the fake platform API. Its methods are safe for concurrent use.
type Server struct {
	mux *http.ServeMux

	mu          sync.Mutex // guards the fields below
	token       string
	envs        []environment
	services    []service
	deployments []*deployment
	ops         map[string]*operation
	keys        map[string]idempotent // by Idempotency-Key
	broken      map[string]bool       // versions whose rollouts fail
	failures    []failure             // injected by FailNext, oldest first
	requests    []Request
	nextID      int
	nextReq     int
}

// END server OMIT

// New returns a fake seeded with three environments, five services and a
// short deployment history.
func New() *Server {
	s := &Server{
		ops:    map[string]*operation{},
		keys:   map[string]idempotent{},
		broken: map[string]bool{},
	}
	s.seed()
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux = http.NewServeMux()
	s.mux.HandleFunc("GET /v1/environments", s.listEnvironments)
	s.mux.HandleFunc("GET /v1/environments/{name}", s.getEnvironment)
	s.mux.HandleFunc("GET /v1/services", s.listServices)
	s.mux.HandleFunc("GET /v1/services/{name}", s.getService)
	s.mux.HandleFunc("GET /v1/deployments", s.listDeployments)
	s.mux.HandleFunc("POST /v1/deployments", s.createDeployment)
	s.mux.HandleFunc("GET /v1/deployments/{id}", s.getDeployment)
	s.mux.HandleFunc("POST /v1/deployments/{id}/cancel", s.cancelDeployment)
	s.mux.HandleFunc("GET /v1/deployments/{id}/logs", s.deploymentLogs)
	s.mux.HandleFunc("GET /v1/operations/{id}", s.getOperation)
}

// START failnext OMIT

// RequireToken makes the fake reject requests whose Authorization header is
// not "Bearer " + token. Changing it simulates a credential rotation.
func (s *Server) RequireToken(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token = token
}

// FailNext makes the next n requests fail with status. A non-zero
// retryAfter is sent as a Retry-After header (whole seconds, rounded up).
func (s *Server) FailNext(n, status int, retryAfter time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for range n {
		s.failures = append(s.failures, failure{status, retryAfter})
	}
}

// END failnext OMIT

// BreakVersion makes rollouts of version fail halfway through.
func (s *Server) BreakVersion(version string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.broken[version] = true
}

// DeploymentState reports the state of deployment id ("" if unknown).
func (s *Server) DeploymentState(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d := s.findDeployment(id); d != nil {
		return d.State
	}
	return ""
}

// Requests returns a copy of every request received so far.
func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.requests)
}

// START serve OMIT

// ServeHTTP records the request, applies authentication and injected
// failures, and dispatches to the API handlers. Having this method makes
// *Server an http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.nextReq++
	rid := r.Header.Get("X-Request-Id")
	if rid == "" {
		rid = "srv-" + strconv.Itoa(s.nextReq)
	}
	s.requests = append(s.requests, Request{
		Method: r.Method, Path: r.URL.RequestURI(), RequestID: rid,
		IdempotencyKey: r.Header.Get("Idempotency-Key"),
		UserAgent:      r.Header.Get("User-Agent"),
		Authorization:  r.Header.Get("Authorization"),
	})
	token := s.token
	var fail *failure
	if len(s.failures) > 0 {
		fail = &s.failures[0]
		s.failures = s.failures[1:]
	}
	s.mu.Unlock()

	w.Header().Set("X-Request-Id", rid)
	switch {
	case token != "" && r.Header.Get("Authorization") != "Bearer "+token:
		writeError(w, http.StatusUnauthorized, "unauthenticated",
			"invalid or expired token")
	case fail != nil:
		if fail.retryAfter > 0 {
			secs := int((fail.retryAfter + time.Second - 1) / time.Second)
			w.Header().Set("Retry-After", strconv.Itoa(secs))
		}
		code := map[int]string{
			http.StatusTooManyRequests:     "rate_limited",
			http.StatusInternalServerError: "internal",
			http.StatusBadGateway:          "bad_gateway",
			http.StatusServiceUnavailable:  "unavailable",
			http.StatusGatewayTimeout:      "timeout",
		}[fail.status]
		writeError(w, fail.status, cmp.Or(code, "injected"), "injected failure")
	default:
		s.mux.ServeHTTP(w, r)
	}
}

// END serve OMIT

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError sends the API's error shape:
// {"error": {"code": "not_found", "message": "..."}}.
func writeError(w http.ResponseWriter, status int, code, msg string) {
	type body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	writeJSON(w, status, map[string]body{"error": {code, msg}})
}
