// START imports OMIT

// Package controller reconciles HealthCheck objects.
package controller

import (
	"context"

	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	v1alpha1 "watchtower/api/v1alpha1"
)

// END imports OMIT

// START reconciler OMIT

// HealthCheckReconciler reconciles HealthCheck objects.
type HealthCheckReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// END reconciler OMIT

// START rbac OMIT

// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=watchtower.platformgo.dev,resources=healthchecks/finalizers,verbs=update

// END rbac OMIT

// START reconcile OMIT

// Reconcile is called with the namespace and name of a HealthCheck whenever
// it changes. For now it only logs.
func (r *HealthCheckReconciler) Reconcile(
	ctx context.Context, req ctrl.Request,
) (ctrl.Result, error) {
	logf.FromContext(ctx).Info("Reconciling", "request", req.NamespacedName)
	return ctrl.Result{}, nil
}

// END reconcile OMIT

// START setup OMIT

// SetupWithManager declares what the controller watches.
func (r *HealthCheckReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("healthcheck").
		For(&v1alpha1.HealthCheck{}).
		Complete(r)
}

// END setup OMIT
