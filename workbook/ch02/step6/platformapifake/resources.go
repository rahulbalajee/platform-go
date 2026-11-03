// START imports OMIT

package platformapifake

import (
	"cmp"
	"encoding/base64"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
)

// END imports OMIT

// The fake's own copies of the wire types. It does not import platformapi,
// so a wrong JSON tag in the SDK fails a test instead of being mirrored.

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

// seed adds three environments, five services, and eight past
// deployments of checkout: four versions, each to dev and then staging.
func (s *Server) seed() {
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

func (s *Server) findService(name string) *service {
	i := slices.IndexFunc(s.services, func(v service) bool { return v.Name == name })
	if i < 0 {
		return nil
	}
	return &s.services[i]
}

func (s *Server) findDeployment(id string) *deployment {
	i := slices.IndexFunc(s.deployments, func(d *deployment) bool {
		return d.ID == id
	})
	if i < 0 {
		return nil
	}
	return s.deployments[i]
}

// START paginate OMIT

// paginate serves one page of items. The page token is opaque to
// clients; here it is an offset, base64-encoded so nobody relies on it.
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
		token := "off:" + strconv.Itoa(end)
		next = base64.RawURLEncoding.EncodeToString([]byte(token))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items": items[off:end], "next_page_token": next,
	})
}

// END paginate OMIT

// START lists OMIT

func (s *Server) listEnvironments(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	envs := slices.Clone(s.envs)
	s.mu.Unlock()
	paginate(w, r, envs)
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

// END lists OMIT

// START logs OMIT

// deploymentLogs streams a plain-text log of the rollout so far.
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
	fmt.Fprintf(w, "%s rollout of %s %s to %s\n",
		cp.ID, cp.Service, cp.Version, cp.Environment)
	for i := range cp.UpdatedReplicas {
		fmt.Fprintf(w, "%s replica %d/%d updated, health check passed\n",
			cp.ID, i+1, cp.Replicas)
	}
	fmt.Fprintf(w, "%s state: %s\n", cp.ID, cmp.Or(cp.State, "unknown"))
}

// END logs OMIT
