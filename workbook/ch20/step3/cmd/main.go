// START imports OMIT

// Command main runs the watchtower operator: a controller-runtime manager
// with the HealthCheck controller registered.
package main

import (
	"crypto/tls"
	"flag"
	"net/http"
	"os"

	// Import all Kubernetes client auth plugins (e.g. Azure, GCP, OIDC, etc.)
	// to ensure that exec-entrypoint and run can make use of them.
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/filters"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	watchtowerv1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/controller"
	"watchtower/internal/probe"
	// +kubebuilder:scaffold:imports
)

// END imports OMIT

// START scheme OMIT
var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(watchtowerv1alpha1.AddToScheme(scheme))
	// +kubebuilder:scaffold:scheme
}

// END scheme OMIT

// START flags OMIT
func main() {
	var (
		metricsAddr, probeAddr string
		certPath, certName     string
		keyName                string
		leaderElect, secure    bool
		enableHTTP2            bool
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", "0",
		"Metrics address: :8443 for HTTPS, :8080 for HTTP, 0 to disable.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081",
		"The address the health probe endpoint binds to.")
	flag.BoolVar(&leaderElect, "leader-elect", false,
		"Enable leader election, so only one replica is active.")
	flag.BoolVar(&secure, "metrics-secure", true,
		"Serve metrics over HTTPS with authentication and authorization.")
	flag.StringVar(&certPath, "metrics-cert-path", "",
		"Directory with the metrics server certificate (default: self-signed).")
	flag.StringVar(&certName, "metrics-cert-name", "tls.crt",
		"The name of the metrics server certificate file.")
	flag.StringVar(&keyName, "metrics-cert-key", "tls.key",
		"The name of the metrics server key file.")
	flag.BoolVar(&enableHTTP2, "enable-http2", false,
		"Serve metrics over HTTP/2 (off by default; see the Rapid Reset CVEs).")
	// END flags OMIT
	// START ownflags OMIT
	var (
		clusterDomain  string
		maxConcurrency int
	)
	flag.StringVar(&clusterDomain, "cluster-domain", "cluster.local",
		"Cluster DNS domain used to build URLs for Service targets.")
	flag.IntVar(&maxConcurrency, "max-concurrent-reconciles", 16,
		"HealthChecks probed in parallel. A probe holds a worker until it ends.")
	// END ownflags OMIT
	// START manager OMIT
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	// HTTP/2 stays off unless asked for: it exposed servers to the HTTP/2
	// Stream Cancellation and Rapid Reset CVEs (GHSA-qppj-fm5r-hxr3,
	// GHSA-4374-p667-p6c8).
	var tlsOpts []func(*tls.Config)
	if !enableHTTP2 {
		tlsOpts = append(tlsOpts, func(c *tls.Config) {
			setupLog.Info("Disabling HTTP/2")
			c.NextProtos = []string{"http/1.1"}
		})
	}
	metricsOpts := metricsserver.Options{
		BindAddress:   metricsAddr,
		SecureServing: secure,
		TLSOpts:       tlsOpts,
	}
	if secure {
		// Only callers allowed by RBAC (a TokenReview and a
		// SubjectAccessReview per request) may read the metrics.
		metricsOpts.FilterProvider = filters.WithAuthenticationAndAuthorization
	}
	if certPath != "" { // otherwise a self-signed certificate is generated
		metricsOpts.CertDir = certPath
		metricsOpts.CertName = certName
		metricsOpts.KeyName = keyName
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsOpts,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         leaderElect,
		LeaderElectionID:       "8bdb4b95.platformgo.dev",
		// Give up the lease as soon as the manager stops, so a rolling
		// update hands over in seconds instead of waiting for the lease to
		// expire. Safe because main exits right after mgr.Start returns.
		LeaderElectionReleaseOnCancel: true,
	})
	if err != nil {
		setupLog.Error(err, "Failed to start manager")
		os.Exit(1)
	}
	// END manager OMIT

	// START wiring OMIT
	// One signal-aware context for setup and for running the manager.
	ctx := ctrl.SetupSignalHandler()

	if err := (&controller.HealthCheckReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
		Prober: probe.HTTP{
			Client:    &http.Client{Transport: http.DefaultTransport},
			UserAgent: "watchtower/1.0",
		},
		ClusterDomain:           clusterDomain,
		MaxConcurrentReconciles: maxConcurrency,
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "Failed to create controller",
			"controller", "healthcheck")
		os.Exit(1)
	}
	// END wiring OMIT
	// START start OMIT
	// +kubebuilder:scaffold:builder

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "Failed to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "Failed to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("Starting manager")
	if err := mgr.Start(ctx); err != nil {
		setupLog.Error(err, "Failed to run manager")
		os.Exit(1)
	}
}

// END start OMIT
