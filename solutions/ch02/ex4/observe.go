// START observe OMIT

package platformapi

import (
	"errors"
	"time"
)

// Attempt describes one HTTP exchange made for a call. A call that is
// retried produces several attempts with the same Call and RequestID.
type Attempt struct {
	Call      string        // e.g. "GET /v1/environments/dev"
	Attempt   int           // 1 for the first try
	Status    int           // HTTP status; 0 if no response arrived
	RequestID string        // the call's X-Request-Id
	Duration  time.Duration // time spent in this attempt
	Err       error         // nil if the attempt succeeded
}

// WithObserver calls f after every attempt, retries included, for
// metrics and tracing. f runs on the goroutine that made the call, so it
// must be quick and, since a Client is shared, safe for concurrent use.
func WithObserver(f func(Attempt)) Option {
	return func(c *config) error {
		if f == nil {
			return errors.New("WithObserver: nil function")
		}
		c.observe = f
		return nil
	}
}

// END observe OMIT
