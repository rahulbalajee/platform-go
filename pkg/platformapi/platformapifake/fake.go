// Package platformapifake is an in-memory implementation of the platform
// API for tests and demos, in the spirit of net/http/httptest.
//
// A Server is an http.Handler. Serve it with httptest.NewTestServer inside a
// testing/synctest bubble, with httptest.NewServer in ordinary tests and
// examples, or with any http.Server.
//
// The fake deliberately does not import platformapi: it speaks the wire
// protocol with its own types, so a wrong JSON tag in the SDK fails a test
// instead of being mirrored by the fake.
//
// Rollouts are deterministic: every GET of an operation advances its
// deployment by one replica, so tests control progress by polling.
package platformapifake

import (
	"cmp"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Request is one request the fake received, for assertions in tests.
type Request struct {
	Method         string
	Path           string // path and query
	RequestID      string
	IdempotencyKey string
	UserAgent      string
	Authorization  string
}

type environment struct {
	Name      string    `json:"name"`
	Region    string    `json:"region"`
	Protected bool      `json:"protected"`
	CreatedAt time.Time `json:"created_at"`
}

type service struct {
	Name     string `json:"name"`
	Team     string `json:"team"`
	Repo     string `json:"repo"`
	Replicas int    `json:"replicas"`
}

type deployment struct {
	ID              string    `json:"id"`
	Service         string    `json:"service"`
	Environment     string    `json:"environment"`
	Version         string    `json:"version"`
	State           string    `json:"state"`
	Replicas        int       `json:"replicas"`
	UpdatedReplicas int       `json:"updated_replicas"`
	Reason          string    `json:"reason,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
}

type opError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type operation struct {
	ID      string   `json:"id"`
	Kind    string   `json:"kind"`
	Done    bool     `json:"done"`
	Message string   `json:"message"`
	Error   *opError `json:"error,omitempty"`

	deploymentID string
}

// operationJSON is the wire form: the operation plus its deployment.
type operationJSON struct {
	*operation
	Result *deployment `json:"result"`
}

type createRequest struct {
	Service     string `json:"service"`
	Environment string `json:"environment"`
	Version     string `json:"version"`
	Reason      string `json:"reason"`
}

type idempotent struct {
	body string
	opID string
}

type failure struct {
	status     int
	retryAfter time.Duration
}

// Server is the fake platform API. Its methods are safe for concurrent use.
type Server struct {
	mux *http.ServeMux

	mu          sync.Mutex
	token       string
	envs        []environment
	services    []service
	deployments []*deployment
	ops         map[string]*operation
	keys        map[string]idempotent
	broken      map[string]bool
	failures    []failure
	requests    []Request
	nextID      int
	nextReq     int
}

// New returns a fake seeded with three environments, five services and a
// short deployment history.
func New() *Server {
	s := &Server{
		ops:    map[string]*operation{},
		keys:   map[string]idempotent{},
		broken: map[string]bool{},
	}
	epoch := time.Date(2026, 9, 1, 9, 0, 0, 0, time.UTC)
	s.envs = []environment{
		{"dev", "eu-west-1", false, epoch},
		{"staging", "eu-west-1", false, epoch},
		{"prod", "eu-west-1", true, epoch},
	}
	s.services = []service{
		{"checkout", "payments", "github.com/acme/checkout", 4},
		{"inventory", "fulfilment", "github.com/acme/inventory", 3},
		{"ledger", "payments", "github.com/acme/ledger", 2},
		{"notifier", "comms", "github.com/acme/notifier", 2},
		{"search", "discovery", "github.com/acme/search", 6},
	}
	for i, v := range []string{"v1.3.0", "v1.3.1", "v1.4.0", "v1.4.1"} {
		for j, env := range []string{"dev", "staging"} {
			s.nextID++
			at := epoch.Add(time.Duration(i*24+j) * time.Hour)
			s.deployments = append(s.deployments, &deployment{
				ID: "d-" + strconv.Itoa(s.nextID), Service: "checkout",
				Environment: env, Version: v, State: "succeeded",
				Replicas: 4, UpdatedReplicas: 4, CreatedAt: at,
			})
		}
	}
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

// BreakVersion makes rollouts of version fail halfway through.
func (s *Server) BreakVersion(version string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.broken[version] = true
}

// Requests returns a copy of every request received so far.
func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.requests)
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

// ServeHTTP records the request, applies authentication and injected
// failures, and dispatches to the API handlers.
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
		writeError(w, http.StatusUnauthorized, "unauthenticated", "invalid or expired token")
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	type body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	writeJSON(w, status, map[string]body{"error": {code, msg}})
}

// paginate serves one page of items using an opaque offset token.
func paginate[T any](w http.ResponseWriter, r *http.Request, items []T) {
	size := 20
	if v := r.URL.Query().Get("page_size"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 100 {
			writeError(w, http.StatusBadRequest, "invalid_argument",
				"page_size must be between 1 and 100")
			return
		}
		size = n
	}
	off := 0
	if tok := r.URL.Query().Get("page_token"); tok != "" {
		raw, err := base64.RawURLEncoding.DecodeString(tok)
		if err == nil {
			off, err = strconv.Atoi(strings.TrimPrefix(string(raw), "off:"))
		}
		if err != nil || off < 0 || off > len(items) {
			writeError(w, http.StatusBadRequest, "invalid_argument", "bad page_token")
			return
		}
	}
	end := min(off+size, len(items))
	next := ""
	if end < len(items) {
		next = base64.RawURLEncoding.EncodeToString([]byte("off:" + strconv.Itoa(end)))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items": items[off:end], "next_page_token": next,
	})
}

func (s *Server) listEnvironments(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	envs := slices.Clone(s.envs)
	s.mu.Unlock()
	paginate(w, r, envs)
}

func (s *Server) getEnvironment(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name := r.PathValue("name")
	i := slices.IndexFunc(s.envs, func(e environment) bool { return e.Name == name })
	if i < 0 {
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("environment %q not found", name))
		return
	}
	writeJSON(w, http.StatusOK, s.envs[i])
}

func (s *Server) listServices(w http.ResponseWriter, r *http.Request) {
	team := r.URL.Query().Get("team")
	s.mu.Lock()
	var out []service
	for _, svc := range s.services {
		if team == "" || svc.Team == team {
			out = append(out, svc)
		}
	}
	s.mu.Unlock()
	paginate(w, r, out)
}

func (s *Server) getService(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if svc := s.findService(r.PathValue("name")); svc != nil {
		writeJSON(w, http.StatusOK, svc)
		return
	}
	writeError(w, http.StatusNotFound, "not_found",
		fmt.Sprintf("service %q not found", r.PathValue("name")))
}

func (s *Server) findService(name string) *service {
	i := slices.IndexFunc(s.services, func(v service) bool { return v.Name == name })
	if i < 0 {
		return nil
	}
	return &s.services[i]
}

func (s *Server) findDeployment(id string) *deployment {
	i := slices.IndexFunc(s.deployments, func(d *deployment) bool { return d.ID == id })
	if i < 0 {
		return nil
	}
	return s.deployments[i]
}

// listDeployments returns newest first, filtered by service, environment
// and state.
func (s *Server) listDeployments(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	s.mu.Lock()
	var out []deployment
	for _, d := range s.deployments {
		if (q.Get("service") == "" || d.Service == q.Get("service")) &&
			(q.Get("environment") == "" || d.Environment == q.Get("environment")) &&
			(q.Get("state") == "" || d.State == q.Get("state")) {
			out = append(out, *d)
		}
	}
	s.mu.Unlock()
	slices.SortStableFunc(out, func(a, b deployment) int {
		return b.CreatedAt.Compare(a.CreatedAt)
	})
	paginate(w, r, out)
}

func (s *Server) getDeployment(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d := s.findDeployment(r.PathValue("id")); d != nil {
		writeJSON(w, http.StatusOK, d)
		return
	}
	writeError(w, http.StatusNotFound, "not_found",
		fmt.Sprintf("deployment %q not found", r.PathValue("id")))
}

func (s *Server) createDeployment(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	raw, err := readBody(r)
	if err == nil {
		err = json.Unmarshal(raw, &req)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_argument", "malformed JSON body")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	key := r.Header.Get("Idempotency-Key")
	if prev, ok := s.keys[key]; ok && key != "" {
		if prev.body != string(raw) {
			writeError(w, http.StatusUnprocessableEntity, "idempotency_mismatch",
				"idempotency key reused with a different request")
			return
		}
		w.Header().Set("Idempotent-Replayed", "true")
		s.writeOperation(w, http.StatusAccepted, s.ops[prev.opID])
		return
	}

	svc := s.findService(req.Service)
	envOK := slices.ContainsFunc(s.envs, func(e environment) bool {
		return e.Name == req.Environment
	})
	switch {
	case svc == nil:
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("service %q not found", req.Service))
		return
	case !envOK:
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("environment %q not found", req.Environment))
		return
	case req.Version == "":
		writeError(w, http.StatusBadRequest, "invalid_argument", "version is required")
		return
	}
	for _, d := range s.deployments {
		if d.Service == req.Service && d.Environment == req.Environment &&
			(d.State == "pending" || d.State == "in_progress") {
			writeError(w, http.StatusConflict, "conflict", fmt.Sprintf(
				"%s is already deploying %s to %s", d.ID, d.Version, d.Environment))
			return
		}
	}

	s.nextID++
	d := &deployment{
		ID: "d-" + strconv.Itoa(s.nextID), Service: req.Service,
		Environment: req.Environment, Version: req.Version, State: "pending",
		Replicas: svc.Replicas, Reason: req.Reason,
		CreatedAt: time.Now().UTC().Truncate(time.Second),
	}
	s.deployments = append(s.deployments, d)
	op := &operation{
		ID: "op-" + strconv.Itoa(s.nextID), Kind: "deployment.create",
		Message: "queued", deploymentID: d.ID,
	}
	s.ops[op.ID] = op
	if key != "" {
		s.keys[key] = idempotent{body: string(raw), opID: op.ID}
	}
	s.writeOperation(w, http.StatusAccepted, op)
}

func readBody(r *http.Request) ([]byte, error) {
	return io.ReadAll(io.LimitReader(r.Body, 1<<20))
}

func (s *Server) writeOperation(w http.ResponseWriter, status int, op *operation) {
	writeJSON(w, status, operationJSON{op, s.findDeployment(op.deploymentID)})
}

// getOperation advances the rollout by one replica per poll.
func (s *Server) getOperation(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	op, ok := s.ops[r.PathValue("id")]
	if !ok {
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("operation %q not found", r.PathValue("id")))
		return
	}
	d := s.findDeployment(op.deploymentID)
	if !op.Done {
		s.advance(op, d)
	}
	s.writeOperation(w, http.StatusOK, op)
}

func (s *Server) advance(op *operation, d *deployment) {
	switch d.State {
	case "cancelled":
		op.Done = true
		op.Message = "cancelled"
		op.Error = &opError{"cancelled", "deployment " + d.ID + " was cancelled"}
		return
	case "pending":
		d.State = "in_progress"
	}
	d.UpdatedReplicas++
	op.Message = fmt.Sprintf("rolling out %s: %d/%d replicas updated",
		d.Version, d.UpdatedReplicas, d.Replicas)
	if s.broken[d.Version] && d.UpdatedReplicas*2 >= d.Replicas {
		d.State = "failed"
		op.Done = true
		op.Message = "rollout failed"
		op.Error = &opError{"rollout_failed", fmt.Sprintf(
			"%d/%d replicas failed health checks", d.UpdatedReplicas, d.Replicas)}
		return
	}
	if d.UpdatedReplicas == d.Replicas {
		d.State = "succeeded"
		op.Done = true
	}
}

func (s *Server) cancelDeployment(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.findDeployment(r.PathValue("id"))
	switch {
	case d == nil:
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("deployment %q not found", r.PathValue("id")))
	case d.State == "cancelled":
		writeJSON(w, http.StatusOK, d) // cancelling twice is not an error
	case d.State != "pending" && d.State != "in_progress":
		writeError(w, http.StatusConflict, "conflict",
			fmt.Sprintf("deployment %s already %s", d.ID, d.State))
	default:
		d.State = "cancelled"
		writeJSON(w, http.StatusOK, d)
	}
}

func (s *Server) deploymentLogs(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	d := s.findDeployment(r.PathValue("id"))
	var cp deployment
	if d != nil {
		cp = *d
	}
	s.mu.Unlock()
	if d == nil {
		writeError(w, http.StatusNotFound, "not_found",
			fmt.Sprintf("deployment %q not found", r.PathValue("id")))
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "%s rollout of %s %s to %s\n", cp.ID, cp.Service, cp.Version, cp.Environment)
	for i := range cp.UpdatedReplicas {
		fmt.Fprintf(w, "%s replica %d/%d updated, health check passed\n",
			cp.ID, i+1, cp.Replicas)
	}
	fmt.Fprintf(w, "%s state: %s\n", cp.ID, cmp.Or(cp.State, "unknown"))
}
