// START errors OMIT

package platformapi

import (
	"errors"
	"fmt"
	"net/http"
	"time"
)

// Sentinel errors for the conditions callers branch on. Test with
// errors.Is; the *APIError in the chain carries the details.
var (
	ErrNotFound     = errors.New("platformapi: not found")    // 404
	ErrConflict     = errors.New("platformapi: conflict")     // 409
	ErrUnauthorized = errors.New("platformapi: unauthorized") // 401
	ErrRateLimited  = errors.New("platformapi: rate limited") // 429
)

// APIError is an error response from the platform API.
type APIError struct {
	StatusCode int           // HTTP status, e.g. 404
	Code       string        // stable machine-readable code, e.g. "not_found"
	Message    string        // human-readable; do not parse it
	RequestID  string        // quote this when asking the platform team
	Op         string        // the call, e.g. "GET /v1/deployments/d-9"
	RetryAfter time.Duration // from Retry-After, if the server sent one
}

func (e *APIError) Error() string {
	return fmt.Sprintf("%s: %d %s: %s (request %s)",
		e.Op, e.StatusCode, e.Code, e.Message, e.RequestID)
}

// Is makes errors.Is(err, ErrNotFound) and the other sentinels work for
// API errors without exposing a sentinel per status code.
func (e *APIError) Is(target error) bool {
	switch target {
	case ErrNotFound:
		return e.StatusCode == http.StatusNotFound
	case ErrConflict:
		return e.StatusCode == http.StatusConflict
	case ErrUnauthorized:
		return e.StatusCode == http.StatusUnauthorized
	case ErrRateLimited:
		return e.StatusCode == http.StatusTooManyRequests
	}
	return false
}

// END errors OMIT

// START operror OMIT

// OperationError reports that a long-running operation finished but
// failed, for example a rollout whose replicas failed health checks. The
// API calls themselves succeeded.
type OperationError struct {
	OperationID string `json:"-"`
	Code        string `json:"code"` // e.g. "rollout_failed", "cancelled"
	Message     string `json:"message"`
}

func (e *OperationError) Error() string {
	return fmt.Sprintf("operation %s failed: %s: %s",
		e.OperationID, e.Code, e.Message)
}

// END operror OMIT
