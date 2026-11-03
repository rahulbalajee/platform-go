// START imports OMIT

package controller

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	v1alpha1 "watchtower/api/v1alpha1"
)

// END imports OMIT

// START vars OMIT

// The manager under test only watches managedNS. Tests that drive
// Reconcile by hand use manualNS, where the manager can't interfere.
const (
	managedNS = "wt-managed"
	manualNS  = "wt-manual"
)

var (
	k8s    client.Client // direct (uncached) client for assertions
	scheme = runtime.NewScheme()
	envUp  bool
)

// END vars OMIT

// START suite OMIT

// TestMain starts a throwaway control plane for the package's tests:
// envtest runs a real kube-apiserver and etcd and installs the CRDs.
func TestMain(m *testing.M) {
	os.Exit(runSuite(m))
}

func runSuite(m *testing.M) int {
	logf.SetLogger(zap.New(zap.WriteTo(io.Discard)))
	_ = clientgoscheme.AddToScheme(scheme)
	_ = v1alpha1.AddToScheme(scheme)

	env := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "config", "crd", "bases"),
		},
		ErrorIfCRDPathMissing: true,
		BinaryAssetsDirectory: envtestBinDir(),
	}
	if os.Getenv("KUBEBUILDER_ASSETS") == "" && env.BinaryAssetsDirectory == "" {
		fmt.Println("envtest binaries not found (set KUBEBUILDER_ASSETS or " +
			"run `make test`); envtest tests will be skipped")
		return m.Run()
	}
	cfg, err := env.Start()
	if err != nil {
		fmt.Fprintln(os.Stderr, "starting envtest:", err)
		return 1
	}
	defer func() { _ = env.Stop() }()

	if k8s, err = client.New(cfg, client.Options{Scheme: scheme}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	for _, ns := range []string{managedNS, manualNS} {
		_ = k8s.Create(context.Background(), &corev1.Namespace{Name: ns})
	}

	envUp = true
	return m.Run()
}

// END suite OMIT

// START helpers OMIT

// requireEnv skips a test that needs the API server when envtest is off.
func requireEnv(t *testing.T) {
	t.Helper()
	if !envUp {
		t.Skip("envtest not available: set KUBEBUILDER_ASSETS or run `make test`")
	}
}

// envtestBinDir finds binaries installed by `make setup-envtest` so the
// tests also run from an IDE without KUBEBUILDER_ASSETS set.
func envtestBinDir() string {
	base := filepath.Join("..", "..", "bin", "k8s")
	entries, err := os.ReadDir(base)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if e.IsDir() {
			return filepath.Join(base, e.Name())
		}
	}
	return ""
}

// END helpers OMIT
