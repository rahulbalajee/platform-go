package controller

import (
	"errors"
	"strings"
	"testing"

	"k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/alerting"
)

func TestFinalizerNamesTheBackend(t *testing.T) {
	if got := finalizerFor("datadog"); got != "watchtower.platformgo.dev/cleanup-datadog" {
		t.Errorf("finalizerFor(datadog) = %q", got)
	}
}

// TestFinalizeKeepsForeignFinalizer: an operator switched from Datadog to
// Prometheus can't delete the Datadog monitor, so it must not let the
// HealthCheck go.
func TestFinalizeKeepsForeignFinalizer(t *testing.T) {
	rec := events.NewFakeRecorder(10)
	r := &HealthCheckReconciler{Alerts: alerting.None{}, Recorder: rec} // no client
	foreign := finalizerFor("datadog")
	hc := &v1alpha1.HealthCheck{
		Namespace: "shop", Name: "payments", Finalizers: []string{foreign},
	}

	err := r.finalize(t.Context(), hc)
	if !errors.Is(err, ErrBackendMismatch) {
		t.Fatalf("err = %v, want ErrBackendMismatch", err)
	}
	if !controllerutil.ContainsFinalizer(hc, foreign) {
		t.Fatal("the datadog finalizer was removed by an operator that can't clean up")
	}
	select {
	case e := <-rec.Events:
		if !strings.Contains(e, "CleanupBlocked") || !strings.Contains(e, "datadog") {
			t.Errorf("event = %q, want reason CleanupBlocked naming datadog", e)
		}
	default:
		t.Fatal("no Event tells the user why deletion is blocked")
	}
}

// TestFinalizeRemovesOwnFinalizer: the backend that added a finalizer
// still cleans up and removes it.
func TestFinalizeRemovesOwnFinalizer(t *testing.T) {
	own := finalizerFor("none")
	hc := &v1alpha1.HealthCheck{
		Namespace: "shop", Name: "checkout", Finalizers: []string{own},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(hc).Build()
	r := &HealthCheckReconciler{
		Client: c, Alerts: alerting.None{}, Recorder: events.NewFakeRecorder(10),
	}
	if err := r.finalize(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	if controllerutil.ContainsFinalizer(hc, own) {
		t.Fatal("own finalizer still present after cleanup")
	}
}
