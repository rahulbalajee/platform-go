package controller

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/yaml"

	v1alpha1 "watchtower/api/v1alpha1"
)

// TestTargetRuleIsInTheCRD needs no API server: it reads the generated CRD.
func TestTargetRuleIsInTheCRD(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "crd", "bases",
		"watchtower.platformgo.dev_healthchecks.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var crd apiextensionsv1.CustomResourceDefinition
	if err := yaml.Unmarshal(raw, &crd); err != nil {
		t.Fatal(err)
	}
	schema := crd.Spec.Versions[0].Schema.OpenAPIV3Schema
	target := schema.Properties["spec"].Properties["target"]
	for _, r := range target.XValidations {
		if r.Rule == "self == oldSelf" && strings.Contains(r.Message, "target is immutable") {
			return
		}
	}
	t.Fatalf("spec.target has no rule `self == oldSelf` with a message containing "+
		"\"target is immutable\" (did you run `make manifests`?): %+v",
		target.XValidations)
}

// TestTargetIsImmutable checks the rule against a real API server.
func TestTargetIsImmutable(t *testing.T) {
	requireEnv(t)
	name := uniq("immutable")
	hc := newCheck(manualNS, name, v1alpha1.Target{URL: "https://example.com"})
	if err := k8s.Create(t.Context(), hc); err != nil {
		t.Fatal(err)
	}

	other := get(t, manualNS, name) // other fields can still change
	other.Spec.FailureThreshold = 2
	if err := k8s.Update(t.Context(), other); err != nil {
		t.Fatalf("changing failureThreshold: %v", err)
	}

	moved := get(t, manualNS, name)
	moved.Spec.Target.URL = "https://example.org"
	err := k8s.Update(t.Context(), moved)
	if !apierrors.IsInvalid(err) || !strings.Contains(err.Error(), "target is immutable") {
		t.Fatalf("changing the target: err = %v; want Invalid, target is immutable", err)
	}
}
