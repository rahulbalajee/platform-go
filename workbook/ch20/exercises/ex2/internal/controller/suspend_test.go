package controller

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/probe"
)

// TestSuspendedCheckStopsExporting: a suspended check must not keep an old
// up=0 series alive, or the alert on it fires for as long as it is paused.
func TestSuspendedCheckStopsExporting(t *testing.T) {
	hc := &v1alpha1.HealthCheck{Namespace: "shop", Name: uniq("suspended")}
	hc.Spec.Interval = metav1.Duration{Duration: 30 * time.Second}
	observe(hc, probe.Result{Message: "unexpected status 503"}) // up = 0

	hc.Spec.Suspend = true
	r := &HealthCheckReconciler{} // a suspended check needs no client
	if next := r.reconcileHealth(t.Context(), hc); next != 30*time.Second {
		t.Errorf("next reconcile in %s, want the interval", next)
	}
	if c := healthy(hc); c == nil || c.Reason != v1alpha1.ReasonSuspended {
		t.Errorf("Healthy = %+v, want reason Suspended", c)
	}
	if checkUp.DeleteLabelValues(hc.Namespace, hc.Name) {
		t.Error("watchtower_healthcheck_up is still exported for a suspended check")
	}
	if probesTotal.DeleteLabelValues(hc.Namespace, hc.Name, "failure") {
		t.Error("watchtower_healthcheck_probes_total is still exported " +
			"for a suspended check")
	}
}
