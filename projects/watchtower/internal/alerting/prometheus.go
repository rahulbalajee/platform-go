// START head OMIT

package alerting

import (
	"context"
	"fmt"
	"maps"
	"time"

	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
)

// PrometheusRuleGVK is the Prometheus Operator's rule CRD. We use it through
// unstructured objects so the operator doesn't depend on the Prometheus
// Operator's Go module, and still works in clusters where it isn't installed.
var PrometheusRuleGVK = schema.GroupVersionKind{
	Group: "monitoring.coreos.com", Version: "v1", Kind: "PrometheusRule",
}

// FieldOwner is the server-side apply field manager for everything
// watchtower writes.
const FieldOwner = "watchtower"

// PrometheusRules renders one PrometheusRule per HealthCheck, owned by it,
// so Kubernetes garbage-collects the rule when the check is deleted.
type PrometheusRules struct {
	Client client.Client
	Scheme *runtime.Scheme
	// Labels are added to every rule, e.g. release=kube-prometheus-stack so
	// the Prometheus ruleSelector picks the rules up.
	Labels map[string]string
}

// Name implements Backend.
func (p *PrometheusRules) Name() string { return "prometheus" }

// External implements Backend: rules live in the cluster.
func (p *PrometheusRules) External() bool { return false }

// RuleName is the PrometheusRule name for hc.
func RuleName(hc *v1alpha1.HealthCheck) string { return "watchtower-" + hc.Name }

// END head OMIT

// START render OMIT

// Render builds the desired PrometheusRule for hc.
func (p *PrometheusRules) Render(
	hc *v1alpha1.HealthCheck,
) (*unstructured.Unstructured, error) {
	a := hc.Spec.Alert
	if a == nil {
		return nil, fmt.Errorf("HealthCheck %s/%s has no alert spec",
			hc.Namespace, hc.Name)
	}
	labels := map[string]any{
		"severity":                   a.Severity,
		"watchtower_check":           hc.Name,
		"watchtower_check_namespace": hc.Namespace,
	}
	annotations := map[string]any{"summary": ruleSummary(hc)}
	if a.RunbookURL != "" {
		annotations["runbook_url"] = a.RunbookURL
	}
	// Multi-line on purpose: kubectl and Git diffs show it as a YAML block.
	expr := fmt.Sprintf("max by (check_namespace, check_name) (\n"+
		"  watchtower_healthcheck_up{check_namespace=%q, check_name=%q}\n"+
		") == 0", hc.Namespace, hc.Name)

	u := &unstructured.Unstructured{Object: map[string]any{
		"spec": map[string]any{
			"groups": []any{map[string]any{
				"name": fmt.Sprintf("watchtower.%s.%s", hc.Namespace, hc.Name),
				"rules": []any{map[string]any{
					"alert":       "HealthCheckFailing",
					"expr":        expr,
					"for":         promDuration(a.For.Duration),
					"labels":      labels,
					"annotations": annotations,
				}},
			}},
		},
	}}
	u.SetGroupVersionKind(PrometheusRuleGVK)
	u.SetNamespace(hc.Namespace)
	u.SetName(RuleName(hc))
	l := map[string]string{"app.kubernetes.io/managed-by": "watchtower"}
	maps.Copy(l, p.Labels)
	u.SetLabels(l)
	// Owner reference: deleting the HealthCheck garbage-collects the rule,
	// and changes to the rule trigger a reconcile of its owner.
	if err := controllerutil.SetControllerReference(hc, u, p.Scheme); err != nil {
		return nil, err
	}
	return u, nil
}

// promDuration formats d the way Prometheus writes durations ("2m", "90s").
func promDuration(d time.Duration) string {
	switch {
	case d%time.Hour == 0 && d >= time.Hour:
		return fmt.Sprintf("%dh", d/time.Hour)
	case d%time.Minute == 0 && d >= time.Minute:
		return fmt.Sprintf("%dm", d/time.Minute)
	default:
		return fmt.Sprintf("%ds", d/time.Second)
	}
}

// END render OMIT

// START ensure OMIT

// Ensure applies the rule only if it is missing or differs from the desired
// state. The read comes from the informer cache, so steady state costs no
// API calls. Because the controller watches the rules it owns, a rule
// deleted or edited by hand is restored on the next reconcile.
func (p *PrometheusRules) Ensure(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) (string, error) {
	desired, err := p.Render(hc)
	if err != nil {
		return "", err
	}
	current := &unstructured.Unstructured{}
	current.SetGroupVersionKind(PrometheusRuleGVK)
	err = p.Client.Get(ctx, client.ObjectKeyFromObject(desired), current)
	switch {
	case meta.IsNoMatchError(err):
		return "", fmt.Errorf("%w: PrometheusRule CRD (monitoring.coreos.com/v1) "+
			"is not installed", ErrUnavailable)
	case err == nil && upToDate(current, desired):
		return desired.GetName(), nil
	case err != nil && !apierrors.IsNotFound(err):
		return "", err
	}
	// Server-side apply: we declare the fields we own; other managers'
	// fields (labels added by a policy engine, say) are left alone.
	apply := client.ApplyConfigurationFromUnstructured(desired)
	if err := p.Client.Apply(ctx, apply, client.FieldOwner(FieldOwner),
		client.ForceOwnership); err != nil {
		return "", fmt.Errorf("applying PrometheusRule: %w", err)
	}
	return desired.GetName(), nil
}

// upToDate compares only what we manage: the spec, our labels, and the
// controller reference (a rule left behind by a deleted-and-recreated
// HealthCheck still points at the old UID and must be re-adopted).
func upToDate(current, desired *unstructured.Unstructured) bool {
	cur, want := metav1.GetControllerOf(current), metav1.GetControllerOf(desired)
	if cur == nil || cur.UID != want.UID {
		return false
	}
	for k, v := range desired.GetLabels() {
		if current.GetLabels()[k] != v {
			return false
		}
	}
	return equality.Semantic.DeepEqual(current.Object["spec"], desired.Object["spec"])
}

// END ensure OMIT

// START remove OMIT

// Remove deletes the rule. Owner references would do this on HealthCheck
// deletion; Remove covers the case where alerting is turned off in the spec.
func (p *PrometheusRules) Remove(
	ctx context.Context, hc *v1alpha1.HealthCheck,
) error {
	rule := &unstructured.Unstructured{}
	rule.SetGroupVersionKind(PrometheusRuleGVK)
	rule.SetNamespace(hc.Namespace)
	rule.SetName(RuleName(hc))
	err := p.Client.Delete(ctx, rule)
	if apierrors.IsNotFound(err) || meta.IsNoMatchError(err) {
		return nil
	}
	return err
}

// END remove OMIT
