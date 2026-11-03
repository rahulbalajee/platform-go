package alerting_test

import (
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting"
)

func TestPrometheusRuleRender(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	p := &alerting.PrometheusRules{
		Scheme: scheme, Labels: map[string]string{"release": "kps"},
	}
	hc := &v1alpha1.HealthCheck{
		Name: "checkout", Namespace: "shop", UID: types.UID("u1"),
		Spec: v1alpha1.HealthCheckSpec{Alert: &v1alpha1.AlertSpec{
			Severity: "critical", For: metav1.Duration{Duration: 90 * time.Second},
		}},
	}
	u, err := p.Render(hc)
	if err != nil {
		t.Fatal(err)
	}
	if u.GetName() != "watchtower-checkout" || u.GetLabels()["release"] != "kps" {
		t.Errorf("name/labels = %s %v", u.GetName(), u.GetLabels())
	}
	owner := metav1.GetControllerOf(u)
	if owner == nil || owner.Kind != "HealthCheck" || owner.UID != "u1" {
		t.Errorf("controller = %+v, want the HealthCheck", owner)
	}
	groups, _, _ := unstructured.NestedSlice(u.Object, "spec", "groups")
	rules, _, _ := unstructured.NestedSlice(groups[0].(map[string]any), "rules")
	rule := rules[0].(map[string]any)
	expr, _ := rule["expr"].(string)
	if rule["for"] != "90s" || !strings.Contains(expr, `check_name="checkout"`) {
		t.Errorf("rule = %v", rule)
	}
}
