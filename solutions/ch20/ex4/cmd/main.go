// START imports OMIT

// Command main runs the watchtower operator: a controller-runtime manager
// with the HealthCheck controller registered.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	// Import all Kubernetes client auth plugins (e.g. Azure, GCP, OIDC, etc.)
	// to ensure that exec-entrypoint and run can make use of them.
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/filters"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	watchtowerv1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/alerting"
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
		alertBackend   string
		ruleLabels     string
		datadogURL     string
		alertResync    time.Duration
	)
	flag.StringVar(&clusterDomain, "cluster-domain", "cluster.local",
		"Cluster DNS domain used to build URLs for Service targets.")
	flag.IntVar(&maxConcurrency, "max-concurrent-reconciles", 16,
		"HealthChecks probed in parallel. A probe holds a worker until it ends.")
	flag.StringVar(&alertBackend, "alert-backend", "prometheus",
		"Where alert rules live: prometheus, datadog, or none.")
	flag.StringVar(&ruleLabels, "rule-labels", "",
		"Comma-separated k=v labels added to every PrometheusRule.")
	flag.StringVar(&datadogURL, "datadog-api-url", "https://api.datadoghq.com",
		"Datadog API base URL for your site, e.g. https://api.datadoghq.eu.")
	flag.DurationVar(&alertResync, "alert-resync", 0,
		"Re-push external alert rules this often to undo UI edits; 0 disables.")
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

	backend, watchRules, err := newAlertBackend(
		mgr, alertBackend, ruleLabels, datadogURL)
	if err != nil {
		setupLog.Error(err, "Invalid alerting configuration")
		os.Exit(1)
	}
	setupLog.Info("Alerting configured",
		"backend", backend.Name(), "watchRules", watchRules)

	if err := (&controller.HealthCheckReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorder("watchtower"),
		Prober: probe.HTTP{
			Client:    &http.Client{Transport: http.DefaultTransport},
			UserAgent: "watchtower/1.0",
		},
		Alerts:                  backend,
		ClusterDomain:           clusterDomain,
		MaxConcurrentReconciles: maxConcurrency,
		AlertResync:             alertResync,
		WatchRules:              watchRules,
	}).SetupWithManager(ctx, mgr); err != nil {
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

// START backend OMIT

// newAlertBackend builds the configured alerting backend. For prometheus it
// also reports whether the PrometheusRule CRD exists, because watching a
// kind the API server doesn't know would stop the manager from starting.
func newAlertBackend(
	mgr ctrl.Manager, name, labels, ddURL string,
) (alerting.Backend, bool, error) {
	switch name {
	case "none":
		return alerting.None{}, false, nil
	case "datadog":
		return &alerting.Datadog{
			BaseURL: ddURL,
			APIKey:  os.Getenv("DD_API_KEY"), // from a Secret, never a flag
			AppKey:  os.Getenv("DD_APP_KEY"),
			HTTP:    &http.Client{Timeout: 30 * time.Second},
		}, false, nil
	case "prometheus":
		l, err := parseLabels(labels)
		if err != nil {
			return nil, false, err
		}
		gvk := alerting.PrometheusRuleGVK
		_, err = mgr.GetRESTMapper().RESTMapping(gvk.GroupKind(), gvk.Version)
		switch {
		case meta.IsNoMatchError(err):
			setupLog.Info("PrometheusRule CRD not found; rules will be reported " +
				"as unavailable until it is installed and the operator restarts")
		case err != nil:
			return nil, false, err
		}
		return &alerting.PrometheusRules{
			Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Labels: l,
		}, err == nil, nil
	}
	return nil, false, fmt.Errorf(
		"unknown --alert-backend %q (want prometheus, datadog, none)", name)
}

// END backend OMIT

// START labels OMIT

// parseLabels parses "k=v,k2=v2" into a map.
func parseLabels(s string) (map[string]string, error) {
	out := map[string]string{}
	if s == "" {
		return out, nil
	}
	for kv := range strings.SplitSeq(s, ",") {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("invalid label %q in --rule-labels (want k=v)", kv)
		}
		out[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return out, nil
}

// END labels OMIT
