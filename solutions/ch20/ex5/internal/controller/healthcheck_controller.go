// START imports OMIT

// Package controller reconciles HealthCheck objects.
package controller

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/alerting"
	"watchtower/internal/probe"
)

// END imports OMIT

// START consts OMIT
const (
	// finalizerPrefix plus a backend name guards that backend's external
	// rules until they are deleted.
	finalizerPrefix = "watchtower.platformgo.dev/cleanup-"
	// serviceNameField indexes HealthChecks by the Service they probe.
	serviceNameField = ".spec.target.service.name"
)

// END consts OMIT

// START finalizerfor OMIT

// ErrBackendMismatch means a HealthCheck carries the finalizer of another
// alerting backend, whose rule this operator can't delete.
var ErrBackendMismatch = errors.New("finalizer belongs to another alerting backend")

// finalizerFor is the finalizer that guards backend's external rules.
func finalizerFor(backend string) string { return finalizerPrefix + backend }

// END finalizerfor OMIT

// START reconciler OMIT

// HealthCheckReconciler probes targets, reports health through status and
// metrics, and keeps an alert rule in sync with each HealthCheck.
type HealthCheckReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder events.EventRecorder
	Prober   probe.Prober
	Alerts   alerting.Backend

	ClusterDomain           string // for Service targets, e.g. "cluster.local"
	MaxConcurrentReconciles int
	WatchRules              bool // watch owned PrometheusRules (CRD present)

	// lastProbe remembers when each check was last probed (key ->
	// probeRecord). Reconciles are also triggered by watch events, and
	// without this gate each one would probe early. It is deliberately in
	// memory: losing it on restart costs at most one early probe.
	lastProbe sync.Map
}

type probeRecord struct {
	at         time.Time
	generation int64
}

// END reconciler OMIT

// START rbac OMIT

// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=monitoring.coreos.com,resources=prometheusrules,verbs=get;list;watch;create;update;patch;delete

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
			r.lastProbe.Delete(req.NamespacedName)
			// END gone OMIT
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}
	// START deleting OMIT

	if !hc.DeletionTimestamp.IsZero() {
		return ctrl.Result{}, r.finalize(ctx, &hc)
	}

	// An external rule must be protected by a finalizer *before* it exists;
	// otherwise a delete racing with creation leaks the rule.
	if r.Alerts.External() && hc.Spec.Alert != nil &&
		controllerutil.AddFinalizer(&hc, finalizerFor(r.Alerts.Name())) {
		if err := r.Update(ctx, &hc); err != nil {
			return ctrl.Result{}, err
		}
	}
	// END deleting OMIT

	base := hc.DeepCopy()
	hc.Status.ObservedGeneration = hc.Generation
	next := r.reconcileHealth(ctx, &hc)
	r.reconcileAlerting(ctx, &hc)

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
	// START due OMIT

	// Woken early by a watch event (an owned rule changed, say)? Keep the
	// cadence, so failureThreshold x interval means what the user wrote.
	if wait := r.untilDue(hc); wait > 0 {
		return wait
	}
	// END due OMIT
	res := r.Prober.Probe(ctx, probe.Spec{
		URL:         url,
		Timeout:     hc.Spec.Timeout.Duration,
		StatusCodes: hc.Spec.Expect.StatusCodes,
		MaxLatency:  durationOrZero(hc.Spec.Expect.MaxLatency),
	})
	// START record OMIT
	r.lastProbe.Store(client.ObjectKeyFromObject(hc),
		probeRecord{at: time.Now(), generation: hc.Generation})
	// END record OMIT
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

// START untildue OMIT

// untilDue returns zero if hc should be probed now, or how long until it
// should. A spec change (new generation) always makes a probe due.
func (r *HealthCheckReconciler) untilDue(
	hc *v1alpha1.HealthCheck,
) time.Duration {
	v, ok := r.lastProbe.Load(client.ObjectKeyFromObject(hc))
	if !ok {
		return 0
	}
	last := v.(probeRecord)
	interval := hc.Spec.Interval.Duration
	elapsed := time.Since(last.at)
	// Timer-driven reconciles arrive at interval +-10%, so anything sooner
	// than half an interval was triggered by something else.
	if last.generation != hc.Generation || elapsed >= interval/2 {
		return 0
	}
	return interval - elapsed
}

// END untildue OMIT

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

// START alerting OMIT

// reconcileAlerting keeps the alert rule for hc in sync with its spec and
// reports the outcome in the AlertingReady condition.
func (r *HealthCheckReconciler) reconcileAlerting(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) {
	if hc.Spec.Alert == nil { // alerting turned off (or never on)
		if hc.Status.Alerting != nil {
			if err := r.Alerts.Remove(ctx, hc); err != nil {
				setAlerting(hc, metav1.ConditionFalse,
					v1alpha1.ReasonSyncFailed, err.Error())
				return
			}
			hc.Status.Alerting = nil
		}
		meta.RemoveStatusCondition(&hc.Status.Conditions,
			v1alpha1.ConditionAlertingReady)
		return
	}
	if _, ok := r.Alerts.(alerting.None); ok {
		hc.Status.Alerting = &v1alpha1.AlertingStatus{Backend: "none"}
		setAlerting(hc, metav1.ConditionFalse, v1alpha1.ReasonAlertingDisabled,
			"the operator runs with --alert-backend=none")
		return
	}
	// START gate OMIT
	// External APIs are slow, rate-limited and sometimes billed per call:
	// push only when the spec changed. In-cluster rules are compared against
	// the informer cache on every pass, which also repairs manual edits.
	if r.Alerts.External() && alertingSynced(hc, r.Alerts.Name()) {
		return
	}
	// END gate OMIT

	ref, err := r.Alerts.Ensure(ctx, hc)
	switch {
	case errors.Is(err, alerting.ErrUnavailable):
		setAlerting(hc, metav1.ConditionFalse,
			v1alpha1.ReasonBackendUnavailable, err.Error())
	case err != nil:
		logf.FromContext(ctx).Error(err, "syncing alert rule",
			"backend", r.Alerts.Name())
		setAlerting(hc, metav1.ConditionFalse,
			v1alpha1.ReasonSyncFailed, err.Error())
	default:
		hc.Status.Alerting = &v1alpha1.AlertingStatus{
			Backend: r.Alerts.Name(), Ref: ref, ObservedGeneration: hc.Generation,
		}
		setAlerting(hc, metav1.ConditionTrue, v1alpha1.ReasonRuleSynced,
			fmt.Sprintf("%s rule %s is up to date", r.Alerts.Name(), ref))
	}
}

// END alerting OMIT

// START finalize OMIT

// finalize runs while the HealthCheck is being deleted. Kubernetes keeps the
// object (with deletionTimestamp set) until every finalizer is removed, so
// the external rule is guaranteed a cleanup attempt, retried with backoff
// until it succeeds.
func (r *HealthCheckReconciler) finalize(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) error {
	forget(hc.Namespace, hc.Name)
	// START forgetprobe OMIT
	r.lastProbe.Delete(client.ObjectKeyFromObject(hc))
	// END forgetprobe OMIT
	own := finalizerFor(r.Alerts.Name())
	for _, f := range hc.Finalizers {
		backend, ours := strings.CutPrefix(f, finalizerPrefix)
		if ours && f != own {
			r.Recorder.Eventf(hc, nil, corev1.EventTypeWarning, "CleanupBlocked",
				"DeleteAlertRule", "the %s rule can only be deleted by an "+
					"operator running with --alert-backend=%s", backend, backend)
			return fmt.Errorf("%w: %s", ErrBackendMismatch, f) // keep retrying
		}
	}
	if !controllerutil.ContainsFinalizer(hc, own) {
		return nil
	}
	if err := r.Alerts.Remove(ctx, hc); err != nil {
		r.Recorder.Eventf(hc, nil, corev1.EventTypeWarning, "CleanupFailed",
			"DeleteAlertRule", "deleting %s rule: %v", r.Alerts.Name(), err)
		return err // requeued with exponential backoff
	}
	controllerutil.RemoveFinalizer(hc, own)
	return r.Update(ctx, hc)
}

// END finalize OMIT

// START setup OMIT

// SetupWithManager declares what the controller watches.
func (r *HealthCheckReconciler) SetupWithManager(
	ctx context.Context, mgr ctrl.Manager,
) error {
	// START index OMIT
	// Index HealthChecks by target Service, so a Service event maps to the
	// checks that probe it with an indexed cache lookup, not a full scan.
	err := mgr.GetFieldIndexer().IndexField(ctx,
		&v1alpha1.HealthCheck{}, serviceNameField,
		func(o client.Object) []string {
			if s := o.(*v1alpha1.HealthCheck).Spec.Target.Service; s != nil {
				return []string{s.Name}
			}
			return nil
		})
	if err != nil {
		return err
	}
	// END index OMIT

	b := ctrl.NewControllerManagedBy(mgr).
		Named("healthcheck").
		// Status writes bump resourceVersion but not generation; ignoring
		// them stops the controller from reconciling its own writes.
		For(&v1alpha1.HealthCheck{},
			builder.WithPredicates(predicate.GenerationChangedPredicate{})).
		// START watches OMIT
		// A Service appearing, disappearing or changing ports re-resolves
		// the checks that target it immediately, not at the next interval.
		Watches(&corev1.Service{},
			handler.EnqueueRequestsFromMapFunc(r.checksForService),
			builder.WithPredicates(servicePortsChanged)).
		// END watches OMIT
		WithOptions(controller.Options{
			MaxConcurrentReconciles: r.MaxConcurrentReconciles,
		})
	// START owns OMIT

	if r.WatchRules {
		rule := &unstructured.Unstructured{}
		rule.SetGroupVersionKind(alerting.PrometheusRuleGVK)
		b = b.Owns(rule) // edits or deletes of our rules trigger a repair
	}
	// END owns OMIT
	return b.Complete(r)
}

// END setup OMIT

// START mapfunc OMIT

// checksForService maps a Service event to the HealthChecks that target it.
func (r *HealthCheckReconciler) checksForService(
	ctx context.Context, svc client.Object,
) []reconcile.Request {
	var list v1alpha1.HealthCheckList
	if err := r.List(ctx, &list, client.InNamespace(svc.GetNamespace()),
		client.MatchingFields{serviceNameField: svc.GetName()}); err != nil {
		logf.FromContext(ctx).Error(err, "listing HealthChecks for Service")
		return nil
	}
	reqs := make([]reconcile.Request, 0, len(list.Items))
	for i := range list.Items {
		key := client.ObjectKeyFromObject(&list.Items[i])
		reqs = append(reqs, reconcile.Request{NamespacedName: key})
	}
	return reqs
}

// servicePortsChanged passes creates, deletes, and port changes.
var servicePortsChanged = predicate.Funcs{
	UpdateFunc: func(e event.UpdateEvent) bool {
		o, ok1 := e.ObjectOld.(*corev1.Service)
		n, ok2 := e.ObjectNew.(*corev1.Service)
		if !ok1 || !ok2 {
			return true
		}
		return !equality.Semantic.DeepEqual(o.Spec.Ports, n.Spec.Ports)
	},
}

// END mapfunc OMIT

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
