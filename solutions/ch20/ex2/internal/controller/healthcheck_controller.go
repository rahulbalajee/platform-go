// START imports OMIT

// Package controller reconciles HealthCheck objects.
package controller

import (
	"context"
	"fmt"
	"math/rand/v2"
	"net"
	"slices"
	"strconv"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/probe"
)

// END imports OMIT

// START reconciler OMIT

// HealthCheckReconciler probes targets, reports health through status and
// metrics.
type HealthCheckReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder events.EventRecorder
	Prober   probe.Prober

	ClusterDomain           string // for Service targets, e.g. "cluster.local"
	MaxConcurrentReconciles int
}

// END reconciler OMIT

// START rbac OMIT

// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch

// END rbac OMIT

// START reconcile OMIT

// Reconcile is level-triggered: it never asks "what changed?", only "what
// should the world look like now?", and it is safe to run any number of
// times. Each call probes at most once and schedules the next probe.
func (r *HealthCheckReconciler) Reconcile(
	ctx context.Context, req ctrl.Request,
) (ctrl.Result, error) {
	var hc v1alpha1.HealthCheck
	if err := r.Get(ctx, req.NamespacedName, &hc); err != nil {
		if apierrors.IsNotFound(err) {
			// START gone OMIT
			forget(req.Namespace, req.Name) // gone: stop exporting its series
			// END gone OMIT
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	base := hc.DeepCopy()
	hc.Status.ObservedGeneration = hc.Generation
	next := r.reconcileHealth(ctx, &hc)

	// Write status only if something changed. A steadily healthy check
	// costs one GET from the cache and zero API writes per probe.
	if !equality.Semantic.DeepEqual(base.Status, hc.Status) {
		// The lock rejects the patch if hc is stale, for example because
		// our own previous write hasn't reached the cache yet.
		lock := client.MergeFromWithOptimisticLock{}
		err := r.Status().Patch(ctx, &hc, client.MergeFromWithOptions(base, lock))
		if apierrors.IsConflict(err) {
			return ctrl.Result{RequeueAfter: time.Second}, nil // re-read, retry
		}
		if err != nil {
			return ctrl.Result{}, err
		}
	}
	return ctrl.Result{RequeueAfter: next}, nil
}

// END reconcile OMIT

// START health OMIT

// reconcileHealth probes the target if a probe is due and returns how long
// to wait before the next reconcile.
func (r *HealthCheckReconciler) reconcileHealth(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) time.Duration {
	interval := hc.Spec.Interval.Duration
	if hc.Spec.Suspend {
		setHealthy(hc, metav1.ConditionUnknown,
			v1alpha1.ReasonSuspended, "probing is suspended")
		forget(hc.Namespace, hc.Name) // no stale up=0 while paused
		return interval
	}
	url, err := r.resolveURL(ctx, hc)
	if err != nil {
		hc.Status.ResolvedURL = ""
		setHealthy(hc, metav1.ConditionUnknown,
			v1alpha1.ReasonTargetUnresolved, err.Error())
		return interval
	}
	hc.Status.ResolvedURL = url
	res := r.Prober.Probe(ctx, probe.Spec{
		URL:         url,
		Timeout:     hc.Spec.Timeout.Duration,
		StatusCodes: hc.Spec.Expect.StatusCodes,
		MaxLatency:  durationOrZero(hc.Spec.Expect.MaxLatency),
	})
	// START observe OMIT
	observe(hc, res)

	switch applyProbe(hc, res) {
	case becameUnhealthy:
		r.Recorder.Eventf(hc, nil, corev1.EventTypeWarning,
			v1alpha1.ReasonProbeFailing, "Probe",
			"failed %d consecutive probes: %s",
			hc.Status.ConsecutiveFailures, res.Message)
	case recovered:
		r.Recorder.Eventf(hc, nil, corev1.EventTypeNormal, "Recovered",
			"Probe", "healthy again: %s", res.Message)
	}
	// END observe OMIT
	return jitter(interval)
}

// END health OMIT

// START resolve OMIT

// resolveURL returns the URL to probe. Service targets resolve to the
// Service's cluster DNS name, after checking that the Service and port
// exist so users get a precise reason instead of a DNS error.
func (r *HealthCheckReconciler) resolveURL(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) (string, error) {
	t := hc.Spec.Target
	if t.URL != "" {
		return t.URL, nil
	}
	s := t.Service
	var svc corev1.Service
	key := types.NamespacedName{Namespace: hc.Namespace, Name: s.Name}
	if err := r.Get(ctx, key, &svc); err != nil {
		if apierrors.IsNotFound(err) {
			return "", fmt.Errorf("service %q not found", s.Name)
		}
		return "", err
	}
	if !slices.ContainsFunc(svc.Spec.Ports, func(p corev1.ServicePort) bool {
		return p.Port == s.Port
	}) {
		return "", fmt.Errorf("service %q has no port %d", s.Name, s.Port)
	}
	host := fmt.Sprintf("%s.%s.svc.%s", s.Name, hc.Namespace, r.ClusterDomain)
	return fmt.Sprintf("%s://%s%s", s.Scheme,
		net.JoinHostPort(host, strconv.Itoa(int(s.Port))), s.Path), nil
}

// END resolve OMIT

// START setup OMIT

// SetupWithManager declares what the controller watches.
func (r *HealthCheckReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("healthcheck").
		// Status writes bump resourceVersion but not generation; ignoring
		// them stops the controller from reconciling its own writes.
		For(&v1alpha1.HealthCheck{},
			builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		WithOptions(controller.Options{
			MaxConcurrentReconciles: r.MaxConcurrentReconciles,
		}).
		Complete(r)
}

// END setup OMIT

// START jitter OMIT

// jitter returns d ±10%, so checks created together don't probe in lockstep.
func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	return d - d/10 + rand.N(d/5+1) //nolint:gosec // spread, not secrecy
}

func durationOrZero(d *metav1.Duration) time.Duration {
	if d == nil {
		return 0
	}
	return d.Duration
}

// END jitter OMIT
