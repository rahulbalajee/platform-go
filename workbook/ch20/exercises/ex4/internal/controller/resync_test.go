package controller

import (
	"context"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	v1alpha1 "watchtower/api/v1alpha1"
)

// countingBackend is an external backend that counts Ensure calls.
type countingBackend struct{ ensures atomic.Int32 }

func (*countingBackend) Name() string   { return "counting" }
func (*countingBackend) External() bool { return true }

func (b *countingBackend) Ensure(context.Context, *v1alpha1.HealthCheck) (string, error) {
	b.ensures.Add(1)
	return "ref-1", nil
}

func (*countingBackend) Remove(context.Context, *v1alpha1.HealthCheck) error { return nil }

func alertingCheck() *v1alpha1.HealthCheck {
	return &v1alpha1.HealthCheck{
		Namespace: "shop", Name: uniq("resync"), Generation: 1,
		Spec: v1alpha1.HealthCheckSpec{
			Alert: &v1alpha1.AlertSpec{Severity: "warning"},
		},
	}
}

// TestExternalRulesAreResynced runs in a synctest bubble, so the half hour
// below passes in virtual time.
func TestExternalRulesAreResynced(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		b := &countingBackend{}
		r := &HealthCheckReconciler{Alerts: b, AlertResync: 30 * time.Minute}
		hc := alertingCheck()
		want := func(n int32, when string) {
			t.Helper()
			if got := b.ensures.Load(); got != n {
				t.Fatalf("%s: %d Ensure calls, want %d", when, got, n)
			}
		}

		r.reconcileAlerting(t.Context(), hc)
		r.reconcileAlerting(t.Context(), hc)
		want(1, "right after the first sync")

		time.Sleep(29 * time.Minute)
		r.reconcileAlerting(t.Context(), hc)
		want(1, "after 29 minutes")

		time.Sleep(2 * time.Minute)
		r.reconcileAlerting(t.Context(), hc)
		want(2, "after 31 minutes")
		r.reconcileAlerting(t.Context(), hc)
		want(2, "right after the resync")
	})
}

func TestResyncIsOffByDefault(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		b := &countingBackend{}
		r := &HealthCheckReconciler{Alerts: b}
		hc := alertingCheck()
		r.reconcileAlerting(t.Context(), hc)
		time.Sleep(24 * time.Hour)
		r.reconcileAlerting(t.Context(), hc)
		if got := b.ensures.Load(); got != 1 {
			t.Fatalf("%d Ensure calls with AlertResync unset, want 1", got)
		}
	})
}
