// START imports OMIT

package controller

import (
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
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
