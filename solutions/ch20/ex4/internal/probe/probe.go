// START types OMIT

// Package probe performs single HTTP health probes. It knows nothing about
// Kubernetes, which keeps it trivially testable and reusable.
package probe

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"slices"
	"time"
)

// Spec describes one probe.
type Spec struct {
	URL         string
	Timeout     time.Duration
	StatusCodes []int32       // healthy codes; empty means 2xx and 3xx
	MaxLatency  time.Duration // 0 means no latency requirement
}

// Result is the outcome of one probe.
//
// Message is deliberately free of measurements (no latencies, no
// timestamps): it ends up in the object's status, and a message that changes
// on every probe would turn every probe into an API write.
type Result struct {
	OK      bool
	Code    int
	Latency time.Duration
	Message string
}

// Prober runs probes. Implementations must honour ctx and Spec.Timeout.
type Prober interface {
	Probe(ctx context.Context, s Spec) Result
}

// ProberFunc adapts a function to Prober, like http.HandlerFunc.
type ProberFunc func(ctx context.Context, s Spec) Result

// Probe implements Prober.
func (f ProberFunc) Probe(ctx context.Context, s Spec) Result { return f(ctx, s) }

// END types OMIT

// START http OMIT

// HTTP probes with GET requests.
type HTTP struct {
	Client    *http.Client // no Client.Timeout: Spec.Timeout bounds each probe
	UserAgent string
}

// Probe implements Prober.
func (p HTTP) Probe(ctx context.Context, s Spec) Result {
	ctx, cancel := context.WithTimeout(ctx, s.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.URL, nil)
	if err != nil {
		return Result{Message: "invalid URL: " + err.Error()}
	}
	req.Header.Set("User-Agent", p.UserAgent)

	start := time.Now()
	resp, err := p.Client.Do(req)
	latency := time.Since(start)
	if err != nil {
		return Result{Latency: latency, Message: describe(err, s.Timeout)}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))

	res := Result{Code: resp.StatusCode, Latency: latency}
	switch {
	case !healthyCode(resp.StatusCode, s.StatusCodes):
		res.Message = fmt.Sprintf("unexpected status %d", resp.StatusCode)
	case s.MaxLatency > 0 && latency > s.MaxLatency:
		res.Message = fmt.Sprintf("slower than maxLatency %s", s.MaxLatency)
	default:
		res.OK = true
		res.Message = fmt.Sprintf("HTTP %d", resp.StatusCode)
	}
	return res
}

// END http OMIT

// START helpers OMIT
func healthyCode(code int, want []int32) bool {
	if len(want) == 0 {
		return code >= 200 && code < 400
	}
	return slices.Contains(want, int32(code)) //nolint:gosec // HTTP codes fit
}

// describe turns transport errors into short, stable messages.
func describe(err error, timeout time.Duration) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Sprintf("timed out after %s", timeout)
	}
	if dnsErr, ok := errors.AsType[*net.DNSError](err); ok {
		return "DNS lookup failed for " + dnsErr.Name
	}
	if opErr, ok := errors.AsType[*net.OpError](err); ok {
		return fmt.Sprintf("%s: %v", opErr.Op, opErr.Err)
	}
	return err.Error()
}

// END helpers OMIT
