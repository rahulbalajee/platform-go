// START imports OMIT

package controller

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	v1alpha1 "github.com/rahulbalajee/platform-go/projects/watchtower/api/v1alpha1"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/alerting"
	"github.com/rahulbalajee/platform-go/projects/watchtower/internal/probe"
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
			// START testcrds OMIT
			filepath.Join("testdata", "crds"), // a stand-in PrometheusRule CRD
			// END testcrds OMIT
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
	// START manager OMIT

	// The controller runs in a manager, exactly as in main. Its cache only
	// sees managedNS.
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:  scheme,
		Metrics: metricsserver.Options{BindAddress: "0"},
		Cache: cache.Options{DefaultNamespaces: map[string]cache.Config{
			managedNS: {},
		}},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	// START reconciler OMIT
	r := &HealthCheckReconciler{
		Client:   mgr.GetClient(),
		Scheme:   scheme,
		Recorder: mgr.GetEventRecorder("watchtower"),
		Prober:   clusterDNSProber{probe.HTTP{Client: http.DefaultClient}},
		Alerts: &alerting.PrometheusRules{
			Client: mgr.GetClient(), Scheme: scheme,
		},

		ClusterDomain:           "cluster.local",
		MaxConcurrentReconciles: 4,
		WatchRules:              true,
	}
	if err := r.SetupWithManager(ctx, mgr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		cancel()
		return 1
	}
	// END reconciler OMIT
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := mgr.Start(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "manager:", err)
		}
	}()
	defer func() {
		cancel()
		<-done // stop the manager before the API server goes away
	}()
	// END manager OMIT

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

// START eventually OMIT

// eventually polls cond until it succeeds or timeout elapses. The API
// server and the controller run on their own goroutines, so tests wait for
// an outcome instead of sleeping for a guessed duration.
func eventually(t *testing.T, timeout time.Duration, cond func() (bool, string)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	last := ""
	for time.Now().Before(deadline) {
		ok, msg := cond()
		if ok {
			return
		}
		last = msg
		time.Sleep(150 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s: %s", timeout, last)
}

// END eventually OMIT

// START dnsprober OMIT

// clusterDNSProber answers for in-cluster Service URLs (there is no cluster
// DNS in envtest) and delegates everything else to the real HTTP prober.
type clusterDNSProber struct{ real probe.Prober }

func (p clusterDNSProber) Probe(ctx context.Context, s probe.Spec) probe.Result {
	if strings.Contains(s.URL, ".svc.cluster.local") {
		return probe.Result{OK: true, Code: 200, Message: "HTTP 200"}
	}
	return p.real.Probe(ctx, s)
}

// END dnsprober OMIT
