// START types OMIT

package platformapifake

import (
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"time"
)

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

// END types OMIT

// START seed OMIT

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

// END seed OMIT

// START get OMIT

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

// END get OMIT
