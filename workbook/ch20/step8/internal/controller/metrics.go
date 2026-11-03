// START head OMIT

package controller

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	v1alpha1 "watchtower/api/v1alpha1"
	"watchtower/internal/probe"
)

// END head OMIT

// START metrics OMIT

// Label names are check_namespace/check_name, not namespace/name: when
// Prometheus scrapes the operator, it attaches the *operator's* namespace
// as `namespace`, and a clashing metric label would be renamed to
// exported_namespace unless every scrape config sets honorLabels.
const (
	labelNamespace = "check_namespace"
	labelName      = "check_name"
)

var (
	checkUp = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "watchtower_healthcheck_up",
		Help: "1 if the most recent probe of a HealthCheck succeeded, 0 otherwise.",
	}, []string{labelNamespace, labelName})

	probeDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "watchtower_healthcheck_probe_duration_seconds",
		Help:    "Latency of HealthCheck probes.",
		Buckets: prometheus.ExponentialBuckets(0.005, 2, 12), // 5ms to ~10s
	}, []string{labelNamespace, labelName})

	probesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "watchtower_healthcheck_probes_total",
		Help: "HealthCheck probes by result (success or failure).",
	}, []string{labelNamespace, labelName, "result"})
)

func init() {
	// controller-runtime's registry is served on the manager's metrics
	// endpoint next to the built-in controller and workqueue metrics.
	metrics.Registry.MustRegister(checkUp, probeDuration, probesTotal)
}

// END metrics OMIT

// START observe OMIT

// observe records one probe result.
func observe(hc *v1alpha1.HealthCheck, res probe.Result) {
	up, result := 0.0, "failure"
	if res.OK {
		up, result = 1, "success"
	}
	checkUp.WithLabelValues(hc.Namespace, hc.Name).Set(up)
	probeDuration.WithLabelValues(hc.Namespace, hc.Name).
		Observe(res.Latency.Seconds())
	probesTotal.WithLabelValues(hc.Namespace, hc.Name, result).Inc()
}

// forget drops every series for a deleted check. Without it, a deleted
// check's last value is exported forever and its alert can never resolve.
func forget(namespace, name string) {
	l := prometheus.Labels{labelNamespace: namespace, labelName: name}
	checkUp.DeletePartialMatch(l)
	probeDuration.DeletePartialMatch(l)
	probesTotal.DeletePartialMatch(l)
}

// END observe OMIT
