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
	p := &alerting.PrometheusRules{Scheme: scheme, Labels: map[string]string{"release": "kps"}}
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
	refs := u.GetOwnerReferences()
	if len(refs) != 1 || refs[0].Kind != "HealthCheck" || refs[0].Controller == nil || !*refs[0].Controller {
		t.Errorf("owner refs = %+v, want one controller reference to the HealthCheck", refs)
	}
	rules, _, _ := unstructured.NestedSlice(u.Object, "spec", "groups")
	rule := rules[0].(map[string]any)["rules"].([]any)[0].(map[string]any)
	if rule["for"] != "90s" || !strings.Contains(rule["expr"].(string), `check_name="checkout"`) {
		t.Errorf("rule = %v", rule)
	}
}
