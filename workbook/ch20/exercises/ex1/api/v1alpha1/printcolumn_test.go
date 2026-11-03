package v1alpha1_test

import (
	"os"
	"path/filepath"
	"testing"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"sigs.k8s.io/yaml"
)

// TestLastFailureColumn: `kubectl get hc -o wide` shows why a check fails.
// It reads the CRD that `make manifests` generates from the markers.
func TestLastFailureColumn(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "crd", "bases",
		"watchtower.platformgo.dev_healthchecks.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var crd apiextensionsv1.CustomResourceDefinition
	if err := yaml.Unmarshal(raw, &crd); err != nil {
		t.Fatal(err)
	}
	cols := crd.Spec.Versions[0].AdditionalPrinterColumns
	for i, c := range cols {
		if c.Name != "Last Failure" {
			continue
		}
		if c.Type != "string" || c.JSONPath != ".status.lastFailure" || c.Priority != 1 {
			t.Errorf("column = %+v; want type string, JSONPath .status.lastFailure, "+
				"priority 1", c)
		}
		if i != len(cols)-1 {
			t.Errorf("Last Failure is column %d of %d; want it last", i+1, len(cols))
		}
		return
	}
	t.Fatalf("no Last Failure column among %d printer columns "+
		"(did you run `make manifests`?)", len(cols))
}
