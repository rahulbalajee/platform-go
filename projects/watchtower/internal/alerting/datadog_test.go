// START ddtesthead OMIT

package alerting_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting/ddfake"
)

func newBackend(t *testing.T) (*alerting.Datadog, *ddfake.Server) {
	t.Helper()
	fake := ddfake.New(t)
	dd := &alerting.Datadog{
		BaseURL: fake.URL, APIKey: "k", AppKey: "a", HTTP: fake.Client(),
	}
	return dd, fake
}

func check() *v1alpha1.HealthCheck {
	return &v1alpha1.HealthCheck{
		Name: "checkout", Namespace: "shop", UID: types.UID("uid-1"),
		Spec: v1alpha1.HealthCheckSpec{Alert: &v1alpha1.AlertSpec{
			Severity:   "critical",
			For:        metav1.Duration{Duration: 2 * time.Minute},
			RunbookURL: "https://runbooks.example.com/checkout",
		}},
	}
}

// END ddtesthead OMIT

// START ddtest OMIT
func TestDatadogEnsureIsIdempotentAcrossLostStatus(t *testing.T) {
	dd, fake := newBackend(t)
	hc := check()

	ref, err := dd.Ensure(t.Context(), hc)
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a crash before the status update: Status.Alerting is still
	// empty, so the backend has to find its monitor by the UID tag.
	ref2, err := dd.Ensure(t.Context(), hc)
	if err != nil {
		t.Fatal(err)
	}
	if ref != ref2 || fake.Creates() != 1 || len(fake.Monitors()) != 1 {
		t.Fatalf("refs %s/%s, %d creates, %d monitors; want exactly one monitor",
			ref, ref2, fake.Creates(), len(fake.Monitors()))
	}
	m := fake.Monitors()[1]
	if q := m["query"].(string); !strings.Contains(q, "max(last_5m)") ||
		!strings.Contains(q, "check_name:checkout") {
		t.Errorf("query = %q", q)
	}
	if msg := m["message"].(string); !strings.Contains(msg, "Runbook: https://") {
		t.Errorf("message lacks runbook: %q", msg)
	}
}

// END ddtest OMIT

// START ddtestmore OMIT
func TestDatadogRecreatesMonitorDeletedInUI(t *testing.T) {
	dd, fake := newBackend(t)
	hc := check()
	ref, _ := dd.Ensure(t.Context(), hc)
	hc.Status.Alerting = &v1alpha1.AlertingStatus{Backend: "datadog", Ref: ref}

	fake.DeleteAll()

	ref2, err := dd.Ensure(t.Context(), hc)
	if err != nil || ref2 == ref || len(fake.Monitors()) != 1 {
		t.Fatalf("ref %s -> %s, err %v, %d monitors; want a fresh monitor",
			ref, ref2, err, len(fake.Monitors()))
	}
}

func TestDatadogRemoveIsIdempotent(t *testing.T) {
	dd, fake := newBackend(t)
	hc := check()
	if _, err := dd.Ensure(t.Context(), hc); err != nil {
		t.Fatal(err)
	}
	for range 2 { // the second call finds nothing and succeeds
		if err := dd.Remove(t.Context(), hc); err != nil {
			t.Fatal(err)
		}
	}
	if n := len(fake.Monitors()); n != 0 {
		t.Errorf("%d monitors left", n)
	}
}

func TestDatadogWithoutCredentialsIsUnavailable(t *testing.T) {
	dd, _ := newBackend(t)
	dd.AppKey = ""
	_, err := dd.Ensure(t.Context(), check())
	if !errors.Is(err, alerting.ErrUnavailable) {
		t.Fatalf("err = %v, want ErrUnavailable", err)
	}
}

// END ddtestmore OMIT
