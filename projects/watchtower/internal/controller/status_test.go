package controller

import (
	"testing"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/probe"
)

// START statetest OMIT
// TestApplyProbeStateMachine feeds a sequence of probe results through
// applyProbe and checks the condition, counter and events after each step.
func TestApplyProbeStateMachine(t *testing.T) {
	ok := probe.Result{OK: true, Code: 200, Message: "HTTP 200"}
	bad := probe.Result{Message: "unexpected status 503"}

	type step struct {
		res      probe.Result
		status   metav1.ConditionStatus
		reason   string
		failures int32
		event    transition
	}
	const (
		unknown   = metav1.ConditionUnknown
		up        = metav1.ConditionTrue
		down      = metav1.ConditionFalse
		pending   = v1alpha1.ReasonProbePending
		succeeded = v1alpha1.ReasonProbeSucceeded
		failing   = v1alpha1.ReasonProbeFailing
	)
	steps := []step{
		{bad, unknown, pending, 1, noTransition},
		{ok, up, succeeded, 0, noTransition},
		{bad, up, succeeded, 1, noTransition}, // blip absorbed
		{bad, up, succeeded, 2, noTransition},
		{bad, down, failing, 3, becameUnhealthy},
		{bad, down, failing, 3, noTransition}, // saturated
		{ok, up, succeeded, 0, recovered},
	}

	hc := &v1alpha1.HealthCheck{Spec: v1alpha1.HealthCheckSpec{FailureThreshold: 3}}
	for i, s := range steps {
		got := applyProbe(hc, s.res)
		c := meta.FindStatusCondition(hc.Status.Conditions, v1alpha1.ConditionHealthy)
		if c.Status != s.status || c.Reason != s.reason ||
			hc.Status.ConsecutiveFailures != s.failures || got != s.event {
			t.Fatalf("step %d: got %s/%s failures=%d event=%d; want %s/%s %d %d",
				i, c.Status, c.Reason, hc.Status.ConsecutiveFailures, got,
				s.status, s.reason, s.failures, s.event)
		}
	}
}

// END statetest OMIT

func TestSaturatedFailureCausesNoStatusChange(t *testing.T) {
	hc := &v1alpha1.HealthCheck{Spec: v1alpha1.HealthCheckSpec{FailureThreshold: 2}}
	bad := probe.Result{Message: "timed out after 5s"}
	applyProbe(hc, bad)
	applyProbe(hc, bad)
	before := hc.Status.DeepCopy()
	applyProbe(hc, bad) // the outage continues
	if !equalStatus(before, &hc.Status) {
		t.Fatalf("status changed during a steady outage:\n%+v\n%+v", before, hc.Status)
	}
}

func equalStatus(a, b *v1alpha1.HealthCheckStatus) bool {
	if a.ConsecutiveFailures != b.ConsecutiveFailures || a.LastFailure != b.LastFailure ||
		len(a.Conditions) != len(b.Conditions) {
		return false
	}
	for i := range a.Conditions {
		x, y := a.Conditions[i], b.Conditions[i]
		if x.Status != y.Status || x.Reason != y.Reason || x.Message != y.Message ||
			!x.LastTransitionTime.Equal(&y.LastTransitionTime) {
			return false
		}
	}
	return true
}
