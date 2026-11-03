// START imports OMIT

package controller

import (
	"fmt"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/probe"
)

// END imports OMIT

// START transition OMIT

// transition is a change in health worth telling humans about.
type transition int

const (
	noTransition transition = iota
	becameUnhealthy
	recovered
)

// END transition OMIT

// START apply OMIT

// applyProbe folds one probe result into hc.Status and reports whether the
// check crossed between healthy and unhealthy. It is a pure function of
// (status, spec, result): no clients, no clocks beyond what
// meta.SetStatusCondition stamps, which makes the state machine easy to
// test exhaustively.
func applyProbe(hc *v1alpha1.HealthCheck, res probe.Result) transition {
	st := &hc.Status
	prev := meta.FindStatusCondition(st.Conditions, v1alpha1.ConditionHealthy)
	wasFailing := prev != nil && prev.Status == metav1.ConditionFalse
	threshold := max(hc.Spec.FailureThreshold, 1)

	if res.OK {
		st.ConsecutiveFailures = 0
		setHealthy(hc, metav1.ConditionTrue,
			v1alpha1.ReasonProbeSucceeded, res.Message)
		if wasFailing {
			return recovered
		}
		return noTransition
	}

	st.LastFailure = res.Message
	if st.ConsecutiveFailures < threshold { // saturate: no write per probe
		st.ConsecutiveFailures++
	}
	switch {
	case st.ConsecutiveFailures >= threshold:
		setHealthy(hc, metav1.ConditionFalse,
			v1alpha1.ReasonProbeFailing, res.Message)
		if !wasFailing {
			return becameUnhealthy
		}
	case prev == nil || prev.Status == metav1.ConditionUnknown:
		setHealthy(hc, metav1.ConditionUnknown, v1alpha1.ReasonProbePending,
			fmt.Sprintf("%d of %d consecutive failures before unhealthy",
				st.ConsecutiveFailures, threshold))
	}
	// A healthy check below the threshold stays healthy: blips are absorbed.
	return noTransition
}

// END apply OMIT

// START sethealthy OMIT

// setHealthy sets the Healthy condition. meta.SetStatusCondition only moves
// lastTransitionTime when the status itself changes.
func setHealthy(
	hc *v1alpha1.HealthCheck, s metav1.ConditionStatus, reason, msg string,
) {
	meta.SetStatusCondition(&hc.Status.Conditions, metav1.Condition{
		Type:               v1alpha1.ConditionHealthy,
		Status:             s,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: hc.Generation,
	})
}

// END sethealthy OMIT
