// START operation OMIT

package platformapi

// Operation is a long-running server-side operation acting on a T, such as
// the rollout started by CreateDeployment. It is plain data: a program can
// store its ID and look the operation up again later.
type Operation[T any] struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`    // e.g. "deployment.create"
	Done    bool   `json:"done"`    // no further changes
	Message string `json:"message"` // progress, for humans
	Result  *T     `json:"result"`  // latest state of the resource
}

// END operation OMIT
