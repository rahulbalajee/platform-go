// START fake OMIT

// Package platformapifake is an in-memory implementation of the platform
// API for tests and demos, in the spirit of net/http/httptest. A Server is
// an http.Handler: serve it with httptest.NewServer or any http.Server.
package platformapifake

import (
	"encoding/json"
	"net/http"
	"sync"
)

// Server is the fake platform API. Its methods are safe for concurrent use.
type Server struct {
	mux *http.ServeMux

	mu          sync.Mutex // guards the fields below
	envs        []environment
	services    []service
	deployments []*deployment
	nextID      int
}

// New returns a fake seeded with three environments, five services and a
// short deployment history.
func New() *Server {
	s := &Server{}
	s.seed()
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux = http.NewServeMux()
	s.mux.HandleFunc("GET /v1/environments/{name}", s.getEnvironment)
	s.mux.HandleFunc("GET /v1/services/{name}", s.getService)
	s.mux.HandleFunc("GET /v1/deployments/{id}", s.getDeployment)
}

// ServeHTTP dispatches to the API handlers. Having this method is what
// makes *Server an http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

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

// END fake OMIT
