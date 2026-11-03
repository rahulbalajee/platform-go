// START fakehead OMIT

// Package ddfake is an in-memory fake of the slice of the Datadog Monitors
// API that watchtower uses, for tests (in the spirit of net/http/httptest).
package ddfake

import (
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// END fakehead OMIT

// START fake OMIT

// Server implements list (filtered by monitor_tags), create, update and
// delete for /api/v1/monitor, and rejects requests without both API keys.
type Server struct {
	*httptest.Server

	mu       sync.Mutex
	nextID   int64
	monitors map[int64]map[string]any
	creates  int
}

// New starts a fake that is shut down when the test ends.
func New(t testing.TB) *Server {
	s := &Server{monitors: map[int64]map[string]any{}}
	s.Server = httptest.NewServer(http.HandlerFunc(s.handle))
	t.Cleanup(s.Close)
	return s
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("DD-API-KEY") == "" || r.Header.Get("DD-APPLICATION-KEY") == "" {
		http.Error(w, `{"errors":["Forbidden"]}`, http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idStr := strings.TrimPrefix(r.URL.Path, "/api/v1/monitor/")
	id, _ := strconv.ParseInt(idStr, 10, 64)
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/api/v1/monitor":
		tag := r.URL.Query().Get("monitor_tags")
		out := []map[string]any{}
		for _, m := range s.monitors {
			for _, t := range m["tags"].([]any) {
				if t == tag {
					out = append(out, m)
				}
			}
		}
		_ = json.NewEncoder(w).Encode(out)
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/monitor":
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		s.nextID++
		s.creates++
		m["id"] = s.nextID
		s.monitors[s.nextID] = m
		_ = json.NewEncoder(w).Encode(m)
	case r.Method == http.MethodPut && s.monitors[id] != nil:
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		m["id"] = id
		s.monitors[id] = m
		_ = json.NewEncoder(w).Encode(m)
	case r.Method == http.MethodDelete && s.monitors[id] != nil:
		delete(s.monitors, id)
		_, _ = fmt.Fprintf(w, `{"deleted_monitor_id":%d}`, id)
	default:
		http.Error(w, `{"errors":["Monitor not found"]}`, http.StatusNotFound)
	}
}

// END fake OMIT

// START fakeapi OMIT

// Monitors returns a snapshot of the stored monitors keyed by ID.
func (s *Server) Monitors() map[int64]map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return maps.Clone(s.monitors)
}

// Creates is the number of POSTs served.
func (s *Server) Creates() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creates
}

// DeleteAll simulates someone deleting every monitor in the Datadog UI.
func (s *Server) DeleteAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	clear(s.monitors)
}

// END fakeapi OMIT
