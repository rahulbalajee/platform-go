package controller

import (
	"context"
	"fmt"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/alerting"
)

// limitedBackend is an external backend whose API is always rate limited.
type limitedBackend struct{}

func (limitedBackend) Name() string   { return "datadog" }
func (limitedBackend) External() bool { return true }

func (limitedBackend) Ensure(context.Context, *v1alpha1.HealthCheck) (string, error) {
	return "", fmt.Errorf("creating monitor: %w",
		&alerting.RateLimitedError{RetryAfter: 7 * time.Second})
}

func (limitedBackend) Remove(context.Context, *v1alpha1.HealthCheck) error { return nil }

// TestRateLimitedSyncIsRetriedAfterTheReset: no error backoff, no hot
// loop: come back when Datadog says the limit resets.
func TestRateLimitedSyncIsRetriedAfterTheReset(t *testing.T) {
	r := &HealthCheckReconciler{Alerts: limitedBackend{}}
	hc := &v1alpha1.HealthCheck{
		Namespace: "shop", Name: "payments", Generation: 1,
		Spec: v1alpha1.HealthCheckSpec{Alert: &v1alpha1.AlertSpec{}},
	}
	if retry := r.reconcileAlerting(t.Context(), hc); retry != 7*time.Second {
		t.Errorf("retry hint = %s, want 7s", retry)
	}
	c := meta.FindStatusCondition(hc.Status.Conditions,
		v1alpha1.ConditionAlertingReady)
	if c == nil || c.Status != metav1.ConditionFalse ||
		c.Reason != v1alpha1.ReasonRateLimited {
		t.Fatalf("AlertingReady = %+v, want False/RateLimited", c)
	}
}

func TestOtherOutcomesGiveNoRetryHint(t *testing.T) {
	r := &HealthCheckReconciler{Alerts: alerting.None{}}
	hc := &v1alpha1.HealthCheck{
		Namespace: "shop", Name: "checkout", Generation: 1,
		Spec: v1alpha1.HealthCheckSpec{Alert: &v1alpha1.AlertSpec{}},
	}
	if retry := r.reconcileAlerting(t.Context(), hc); retry != 0 {
		t.Errorf("retry hint = %s, want 0", retry)
	}
}
