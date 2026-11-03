// START imports OMIT

package controller

import (
	"fmt"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	eventsv1 "k8s.io/api/events/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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

// START newcheck OMIT

// uniq returns prefix plus a short random suffix, so tests can run with
// -count=N against the same API server.
func uniq(prefix string) string {
	return fmt.Sprintf("%s-%04d", prefix, rand.N(10000))
}

func newCheck(ns, name string, target v1alpha1.Target) *v1alpha1.HealthCheck {
	return &v1alpha1.HealthCheck{
		Namespace: ns, Name: name, // promoted from ObjectMeta (Go 1.27)
		Spec: v1alpha1.HealthCheckSpec{
			Target:           target,
			Interval:         metav1.Duration{Duration: 5 * time.Second},
			Timeout:          metav1.Duration{Duration: time.Second},
			FailureThreshold: 1,
		},
	}
}

// END newcheck OMIT

// START validation OMIT
func TestCRDValidationRejectsBadSpecs(t *testing.T) {
	requireEnv(t)
	for name, tc := range map[string]struct {
		mutate func(*v1alpha1.HealthCheck)
		want   string
	}{
		"both url and service": {func(hc *v1alpha1.HealthCheck) {
			hc.Spec.Target.Service = &v1alpha1.ServiceTarget{Name: "api", Port: 80}
		}, "exactly one of url or service must be set"},
		"interval too short": {func(hc *v1alpha1.HealthCheck) {
			hc.Spec.Interval.Duration = 2 * time.Second
		}, "interval must be at least 5s"},
		"timeout >= interval": {func(hc *v1alpha1.HealthCheck) {
			hc.Spec.Timeout.Duration = 10 * time.Second
		}, "timeout must be shorter than interval"},
		"not a URL": {func(hc *v1alpha1.HealthCheck) {
			hc.Spec.Target.URL = "ftp://example.com"
		}, "spec.target.url"},
	} {
		t.Run(name, func(t *testing.T) {
			target := v1alpha1.Target{URL: "https://example.com"}
			hc := newCheck(manualNS, "invalid", target)
			tc.mutate(hc)
			err := k8s.Create(t.Context(), hc)
			if !apierrors.IsInvalid(err) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v; want Invalid containing %q", err, tc.want)
			}
		})
	}
}

// END validation OMIT

// START defaults OMIT

// TestCRDAppliesDefaults: fields left out get the schema's defaults. Create
// updates hc with the object as the API server stored it.
func TestCRDAppliesDefaults(t *testing.T) {
	requireEnv(t)
	hc := &v1alpha1.HealthCheck{
		Namespace: manualNS, Name: uniq("defaults"),
		Spec: v1alpha1.HealthCheckSpec{Target: v1alpha1.Target{
			Service: &v1alpha1.ServiceTarget{Name: "api", Port: 8080},
		}},
	}
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	s, svc := hc.Spec, hc.Spec.Target.Service
	if s.Interval.Duration != 30*time.Second || s.Timeout.Duration != 5*time.Second ||
		s.FailureThreshold != 3 || svc.Path != "/healthz" || svc.Scheme != "http" {
		t.Errorf("defaults not applied: %+v, service %+v", s, *svc)
	}
}

// END defaults OMIT

// START gethelpers OMIT
func healthy(hc *v1alpha1.HealthCheck) *metav1.Condition {
	return meta.FindStatusCondition(hc.Status.Conditions, v1alpha1.ConditionHealthy)
}

func get(t *testing.T, ns, name string) *v1alpha1.HealthCheck {
	t.Helper()
	var hc v1alpha1.HealthCheck
	key := client.ObjectKey{Namespace: ns, Name: name}
	if err := k8s.Get(t.Context(), key, &hc); err != nil {
		t.Fatalf("get %s/%s: %v", ns, name, err)
	}
	return &hc
}

// END gethelpers OMIT

// START lifecycle OMIT

// TestHealthCheckLifecycle runs the real controller in a manager against a
// target we can break and fix on demand.
func TestHealthCheckLifecycle(t *testing.T) {
	requireEnv(t)
	var failing atomic.Bool
	h := func(w http.ResponseWriter, _ *http.Request) {
		if failing.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}
	target := httptest.NewServer(http.HandlerFunc(h))
	defer target.Close()

	name := uniq("checkout")
	hc := newCheck(managedNS, name, v1alpha1.Target{URL: target.URL + "/healthz"})
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	isHealthy := func(want metav1.ConditionStatus) func() (bool, string) {
		return func() (bool, string) {
			c := healthy(get(t, managedNS, name))
			return c != nil && c.Status == want, fmt.Sprintf("Healthy: %+v", c)
		}
	}

	// 1. Healthy.
	eventually(t, 10*time.Second, isHealthy(metav1.ConditionTrue))

	// 2. Break the target: unhealthy within one interval.
	failing.Store(true)
	eventually(t, 10*time.Second, isHealthy(metav1.ConditionFalse))
	// START event OMIT
	eventually(t, 5*time.Second, func() (bool, string) {
		var evs eventsv1.EventList
		_ = k8s.List(t.Context(), &evs, client.InNamespace(managedNS))
		for _, e := range evs.Items {
			if e.Regarding.Name == name && e.Reason == v1alpha1.ReasonProbeFailing {
				return true, ""
			}
		}
		return false, fmt.Sprintf("%d events, none ProbeFailing", len(evs.Items))
	})
	// END event OMIT

	// 3. Fix it: healthy again.
	failing.Store(false)
	eventually(t, 10*time.Second, isHealthy(metav1.ConditionTrue))
}

// END lifecycle OMIT

// START servicetest OMIT
func TestServiceTargetResolvesWhenServiceAppears(t *testing.T) {
	requireEnv(t)
	name := uniq("api")
	hc := newCheck(managedNS, name, v1alpha1.Target{Service: &v1alpha1.ServiceTarget{
		Name: name, Port: 8080, Path: "/healthz", Scheme: "http",
	}})
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	eventually(t, 5*time.Second, func() (bool, string) {
		c := healthy(get(t, managedNS, name))
		return c != nil && c.Reason == v1alpha1.ReasonTargetUnresolved,
			fmt.Sprintf("%+v", c)
	})

	svc := &corev1.Service{
		Namespace: managedNS, Name: name,
		Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{{Port: 8080}}},
	}
	if err := k8s.Create(t.Context(), svc); err != nil {
		t.Fatal(err)
	}
	// Well inside the 5s interval: the Service watch, not the requeue timer,
	// triggered this reconcile.
	want := "http://" + name + ".wt-managed.svc.cluster.local:8080/healthz"
	eventually(t, 3*time.Second, func() (bool, string) {
		got := get(t, managedNS, name)
		c := healthy(got)
		return c.Status == metav1.ConditionTrue && got.Status.ResolvedURL == want,
			fmt.Sprintf("Healthy=%s url=%q", c.Status, got.Status.ResolvedURL)
	})
}

// END servicetest OMIT
