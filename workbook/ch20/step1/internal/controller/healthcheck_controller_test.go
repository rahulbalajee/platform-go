// START imports OMIT

package controller

import (
	"testing"

	"sigs.k8s.io/controller-runtime/pkg/client"

	v1alpha1 "watchtower/api/v1alpha1"
)

// END imports OMIT

// START served OMIT

// TestHealthCheckKindIsServed checks the plumbing: the CRD is installed and
// the client's scheme knows the Go types.
func TestHealthCheckKindIsServed(t *testing.T) {
	requireEnv(t)
	var list v1alpha1.HealthCheckList
	err := k8s.List(t.Context(), &list, client.InNamespace(manualNS))
	if err != nil {
		t.Fatalf("listing HealthChecks: %v", err)
	}
}

// END served OMIT
