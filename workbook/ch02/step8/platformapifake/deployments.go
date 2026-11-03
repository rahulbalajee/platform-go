// START types OMIT

package platformapifake

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"time"
)

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

// idempotent remembers what an Idempotency-Key was first used for.
type idempotent struct {
	body string
	opID string
}

// END types OMIT

func (s *Server) createDeployment(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err == nil {
		err = json.Unmarshal(raw, &req)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_argument",
			"malformed JSON body")
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
		writeError(w, http.StatusBadRequest, "invalid_argument",
			"version is required")
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

func (s *Server) writeOperation(w http.ResponseWriter, status int, op *operation) {
	writeJSON(w, status, operationJSON{op, s.findDeployment(op.deploymentID)})
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

// START advance OMIT

// getOperation advances the rollout by one replica per poll, so a test
// controls progress by polling and never has to sleep.
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

// END advance OMIT
