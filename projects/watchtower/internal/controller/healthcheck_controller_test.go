// START imports OMIT

package controller

import (
	"context"
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
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting/ddfake"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/probe"
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

// START ruletest OMIT
func ruleFor(t *testing.T, name string) (*unstructured.Unstructured, error) {
	t.Helper()
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(alerting.PrometheusRuleGVK)
	key := client.ObjectKey{Namespace: managedNS, Name: "watchtower-" + name}
	return u, k8s.Get(t.Context(), key, u)
}

// exprOf returns the expression of the rule's only alert.
func exprOf(u *unstructured.Unstructured) string {
	groups, _, _ := unstructured.NestedSlice(u.Object, "spec", "groups")
	if len(groups) == 0 {
		return ""
	}
	rules, _, _ := unstructured.NestedSlice(groups[0].(map[string]any), "rules")
	if len(rules) == 0 {
		return ""
	}
	expr, _, _ := unstructured.NestedString(rules[0].(map[string]any), "expr")
	return expr
}

// TestPrometheusRuleLifecycle: the rule is created, owned, repaired after
// manual edits and deletes, and removed when alerting is turned off.
func TestPrometheusRuleLifecycle(t *testing.T) {
	requireEnv(t)
	name := uniq("orders")
	hc := newCheck(managedNS, name, v1alpha1.Target{URL: "https://example.com"})
	hc.Spec.Suspend = true // this test is about alerting, not probing
	hc.Spec.Alert = &v1alpha1.AlertSpec{Severity: "critical"}
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}

	// 1. The rule appears, controlled by its HealthCheck.
	eventually(t, 10*time.Second, func() (bool, string) {
		got := get(t, managedNS, name)
		return meta.IsStatusConditionTrue(got.Status.Conditions,
			v1alpha1.ConditionAlertingReady), fmt.Sprintf("%+v", got.Status)
	})
	rule, err := ruleFor(t, name)
	if err != nil {
		t.Fatal(err)
	}
	owner := metav1.GetControllerOf(rule)
	if owner == nil || owner.Kind != "HealthCheck" || owner.Name != name {
		t.Fatalf("controller of the rule = %+v, want HealthCheck %s", owner, name)
	}
	// START edit OMIT

	// 2. Someone edits the alert expression: server-side apply takes the
	// field back from the other field manager.
	edit := []byte(`[{"op": "replace", "value": "vector(0)",
		"path": "/spec/groups/0/rules/0/expr"}]`)
	err = k8s.Patch(t.Context(), rule, client.RawPatch(types.JSONPatchType, edit),
		client.FieldOwner("kubectl-edit"))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, 5*time.Second, func() (bool, string) {
		got, err := ruleFor(t, name)
		expr := exprOf(got)
		return err == nil && strings.Contains(expr, "healthcheck_up"), expr
	})
	// END edit OMIT

	// 3. Someone deletes the rule: the Owns() watch restores it.
	if err := k8s.Delete(t.Context(), rule); err != nil {
		t.Fatal(err)
	}
	eventually(t, 5*time.Second, func() (bool, string) {
		_, err := ruleFor(t, name)
		return err == nil, fmt.Sprintf("rule still missing: %v", err)
	})

	// 4. Turn alerting off: the rule and the condition go away.
	latest := get(t, managedNS, name)
	latest.Spec.Alert = nil
	if err := k8s.Update(t.Context(), latest); err != nil {
		t.Fatal(err)
	}
	eventually(t, 10*time.Second, func() (bool, string) {
		_, err := ruleFor(t, name)
		got := get(t, managedNS, name)
		cond := meta.FindStatusCondition(got.Status.Conditions,
			v1alpha1.ConditionAlertingReady)
		return apierrors.IsNotFound(err) && cond == nil && got.Status.Alerting == nil,
			fmt.Sprintf("rule err=%v, condition=%v", err, cond)
	})
}

// END ruletest OMIT

// START finalizertest OMIT

// TestDatadogFinalizer drives Reconcile by hand (in a namespace the manager
// ignores) to check the external-resource lifecycle step by step.
func TestDatadogFinalizer(t *testing.T) {
	requireEnv(t)
	fake := ddfake.New(t)
	r := &HealthCheckReconciler{
		Client:   k8s,
		Scheme:   scheme,
		Recorder: events.NewFakeRecorder(10),
		Prober: probe.ProberFunc(func(context.Context, probe.Spec) probe.Result {
			return probe.Result{OK: true, Code: 200, Message: "HTTP 200"}
		}),
		Alerts: &alerting.Datadog{BaseURL: fake.URL, APIKey: "k", AppKey: "a",
			HTTP: fake.Client()},
		ClusterDomain: "cluster.local",
	}
	name := uniq("payments")
	target := v1alpha1.Target{URL: "https://payments.example.com"}
	hc := newCheck(manualNS, name, target)
	hc.Spec.Alert = &v1alpha1.AlertSpec{Severity: "critical"}
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	req := ctrl.Request{NamespacedName: client.ObjectKeyFromObject(hc)}

	for range 3 { // repeated reconciles must not repeat the external work
		if _, err := r.Reconcile(t.Context(), req); err != nil {
			t.Fatal(err)
		}
	}
	got := get(t, manualNS, name)
	if !controllerutil.ContainsFinalizer(got, finalizerName) {
		t.Fatal("finalizer not added before creating the external monitor")
	}
	if a := got.Status.Alerting; fake.Creates() != 1 || a == nil || a.Ref != "1" {
		t.Fatalf("creates=%d alerting=%+v; want one monitor, ref 1",
			fake.Creates(), got.Status.Alerting)
	}

	// Delete: the object lingers (finalizer) until Reconcile cleans up.
	if err := k8s.Delete(t.Context(), got); err != nil {
		t.Fatal(err)
	}
	if get(t, manualNS, name).DeletionTimestamp.IsZero() {
		t.Fatal("expected deletionTimestamp while the finalizer is present")
	}
	if _, err := r.Reconcile(t.Context(), req); err != nil {
		t.Fatal(err)
	}
	if n := len(fake.Monitors()); n != 0 {
		t.Fatalf("%d monitors left after deletion", n)
	}
	err := k8s.Get(t.Context(), req.NamespacedName, &v1alpha1.HealthCheck{})
	if !apierrors.IsNotFound(err) {
		t.Fatalf("HealthCheck still present after finalizer removal: %v", err)
	}
}

// END finalizertest OMIT

// START cadencetest OMIT

// TestReconcileKeepsProbeCadence: reconciles triggered by watch events
// between timer ticks must not probe early.
func TestReconcileKeepsProbeCadence(t *testing.T) {
	requireEnv(t)
	var probes atomic.Int32
	r := &HealthCheckReconciler{
		Client: k8s, Scheme: scheme, Recorder: events.NewFakeRecorder(10),
		Prober: probe.ProberFunc(func(context.Context, probe.Spec) probe.Result {
			probes.Add(1)
			return probe.Result{OK: true, Code: 200, Message: "HTTP 200"}
		}),
		Alerts: alerting.None{},
	}
	name := uniq("cadence")
	hc := newCheck(manualNS, name, v1alpha1.Target{URL: "https://example.com"})
	hc.Spec.Interval.Duration = time.Minute
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	req := ctrl.Request{NamespacedName: client.ObjectKeyFromObject(hc)}

	res, _ := r.Reconcile(t.Context(), req) // probes: nothing recorded yet
	for range 3 {                           // e.g. owned-object events
		res, _ = r.Reconcile(t.Context(), req)
	}
	if n := probes.Load(); n != 1 {
		t.Fatalf("%d probes, want 1: early reconciles must not probe", n)
	}
	if res.RequeueAfter < 50*time.Second || res.RequeueAfter > time.Minute {
		t.Errorf("RequeueAfter = %s, want the rest of the interval",
			res.RequeueAfter)
	}

	latest := get(t, manualNS, name) // a spec change makes a probe due at once
	latest.Spec.FailureThreshold = 2
	if err := k8s.Update(t.Context(), latest); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Reconcile(t.Context(), req); err != nil {
		t.Fatal(err)
	}
	if n := probes.Load(); n != 2 {
		t.Errorf("%d probes after a spec change, want 2", n)
	}
}

// END cadencetest OMIT
