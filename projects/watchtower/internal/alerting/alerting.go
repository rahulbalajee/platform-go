// START head OMIT

// Package alerting keeps an alert rule in sync with each HealthCheck, in
// whichever monitoring stack the cluster uses. Backends are selected once,
// at operator start-up, so the controller is stack-agnostic.
package alerting

import (
	"context"
	"errors"
	"fmt"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
)

// END head OMIT

// START backend OMIT

// Backend implements alert rules for HealthChecks in one monitoring system.
type Backend interface {
	// Name identifies the backend in status, e.g. "prometheus".
	Name() string

	// External reports whether rules live outside the cluster. External
	// rules are not garbage-collected by Kubernetes, so the controller
	// protects them with a finalizer and deletes them explicitly.
	External() bool

	// Ensure creates or updates the rule for hc and returns a reference to
	// it. It must be idempotent: calling it twice creates one rule.
	Ensure(ctx context.Context, hc *v1alpha1.HealthCheck) (ref string, err error)

	// Remove deletes the rule for hc. Removing a rule that doesn't exist is
	// not an error.
	Remove(ctx context.Context, hc *v1alpha1.HealthCheck) error
}

// ErrUnavailable means the backend can't be used right now for reasons the
// user must fix (a missing CRD, missing credentials), as opposed to a
// transient failure. The controller reports it in a condition and doesn't
// hot-loop on it.
var ErrUnavailable = errors.New("alerting backend unavailable")

// END backend OMIT

// START none OMIT

// None is the backend for clusters without alerting: probes and metrics only.
type None struct{}

// Name implements Backend.
func (None) Name() string { return "none" }

// External implements Backend.
func (None) External() bool { return false }

// Ensure implements Backend. There is nothing to create.
func (None) Ensure(context.Context, *v1alpha1.HealthCheck) (string, error) {
	return "", nil
}

// Remove implements Backend. There is nothing to delete.
func (None) Remove(context.Context, *v1alpha1.HealthCheck) error { return nil }

// ruleSummary is the human-readable alert summary for hc.
func ruleSummary(hc *v1alpha1.HealthCheck) string {
	if hc.Spec.Alert != nil && hc.Spec.Alert.Summary != "" {
		return hc.Spec.Alert.Summary
	}
	return fmt.Sprintf("HealthCheck %s/%s is failing", hc.Namespace, hc.Name)
}

// END none OMIT
