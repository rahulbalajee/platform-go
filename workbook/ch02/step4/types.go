// START resources OMIT

package platformapi

import "time"

// Environment is a deployment target such as "staging" or "prod".
type Environment struct {
	Name      string    `json:"name"`
	Region    string    `json:"region"`
	Protected bool      `json:"protected"` // deployments need an approval
	CreatedAt time.Time `json:"created_at"`
}

// Service is a deployable unit owned by a team.
type Service struct {
	Name     string `json:"name"`
	Team     string `json:"team"`
	Repo     string `json:"repo"`
	Replicas int    `json:"replicas"`
}

// END resources OMIT

// START state OMIT

// DeploymentState is the lifecycle state of a deployment. New states may
// be added; treat unknown values as "not finished".
type DeploymentState string

// Deployment states.
const (
	StatePending    DeploymentState = "pending"
	StateInProgress DeploymentState = "in_progress"
	StateSucceeded  DeploymentState = "succeeded"
	StateFailed     DeploymentState = "failed"
	StateCancelled  DeploymentState = "cancelled"
)

// Done reports whether s is a terminal state.
func (s DeploymentState) Done() bool {
	return s == StateSucceeded || s == StateFailed || s == StateCancelled
}

// END state OMIT

// START deployment OMIT

// Deployment is one rollout of a service version to an environment.
type Deployment struct {
	ID              string          `json:"id"`
	Service         string          `json:"service"`
	Environment     string          `json:"environment"`
	Version         string          `json:"version"`
	State           DeploymentState `json:"state"`
	Replicas        int             `json:"replicas"`
	UpdatedReplicas int             `json:"updated_replicas"`
	Reason          string          `json:"reason,omitempty"`
	CreatedAt       time.Time       `json:"created_at"`
}

// END deployment OMIT

// START create OMIT

// CreateDeploymentRequest asks for version of Service to be rolled out to
// Environment. Service, Environment and Version are required.
type CreateDeploymentRequest struct {
	Service     string `json:"service"`
	Environment string `json:"environment"`
	Version     string `json:"version"`
	Reason      string `json:"reason,omitempty"` // shown in the audit log
}

// END create OMIT
