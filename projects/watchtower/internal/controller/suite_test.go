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

// START suite OMIT
// TestMain starts a real kube-apiserver and etcd (envtest), installs our
// CRD plus a stand-in PrometheusRule CRD, and runs the controller in a
// manager, exactly as main does, but against a throwaway control plane.
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
			filepath.Join("testdata", "crds"),
		},
		ErrorIfCRDPathMissing: true,
		BinaryAssetsDirectory: envtestBinDir(),
	}
	if os.Getenv("KUBEBUILDER_ASSETS") == "" && env.BinaryAssetsDirectory == "" {
		fmt.Println("envtest binaries not found; integration tests will be skipped " +
			"(run `make test`)")
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
		_ = k8s.Create(context.Background(), &corev1.Namespace{
			Name: ns})
	}

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
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := mgr.Start(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "manager:", err)
		}
	}()

	envUp = true
	code := m.Run()
	cancel()
	<-done // stop the manager before the API server goes away
	return code
}

// END suite OMIT

// clusterDNSProber answers for in-cluster Service URLs (there is no cluster
// DNS in envtest) and delegates everything else to the real HTTP prober.
type clusterDNSProber struct{ real probe.Prober }

func (p clusterDNSProber) Probe(ctx context.Context, s probe.Spec) probe.Result {
	if strings.Contains(s.URL, ".svc.cluster.local") {
		return probe.Result{OK: true, Code: 200, Message: "HTTP 200"}
	}
	return p.real.Probe(ctx, s)
}

func requireEnv(t *testing.T) {
	t.Helper()
	if !envUp {
		t.Skip("envtest not available; run `make test`")
	}
}

// eventually polls cond until it succeeds or timeout elapses.
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
