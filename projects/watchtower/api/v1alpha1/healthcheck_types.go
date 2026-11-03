// START imports OMIT

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// END imports OMIT

// START spec OMIT

// HealthCheckSpec is the desired state: what to probe, how often, and what
// counts as healthy.
// +kubebuilder:validation:XValidation:rule="duration(self.timeout) < duration(self.interval)",message="timeout must be shorter than interval"
type HealthCheckSpec struct {
	// Target is the endpoint to probe.
	Target Target `json:"target"`

	// Interval between probes.
	// +kubebuilder:default="30s"
	// +kubebuilder:validation:XValidation:rule="duration(self) >= duration('5s')",message="interval must be at least 5s"
	// +optional
	Interval metav1.Duration `json:"interval,omitzero"`

	// Timeout for a single probe. Must be shorter than interval.
	// +kubebuilder:default="5s"
	// +optional
	Timeout metav1.Duration `json:"timeout,omitzero"`

	// FailureThreshold is the number of consecutive failed probes before the
	// check is reported unhealthy. Brief blips below it are absorbed.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=100
	// +kubebuilder:default=3
	// +optional
	FailureThreshold int32 `json:"failureThreshold,omitempty"`

	// Expect refines what counts as a healthy response.
	// +optional
	Expect Expectations `json:"expect,omitzero"`

	// Alert configures the alert rule generated for this check. Omit it to
	// probe without alerting.
	// +optional
	Alert *AlertSpec `json:"alert,omitempty"`

	// Suspend pauses probing without deleting the check or its alert rule.
	// +optional
	Suspend bool `json:"suspend,omitempty"`
}

// END spec OMIT

// START target OMIT

// Target identifies the endpoint to probe. Exactly one field must be set.
// +kubebuilder:validation:XValidation:rule="has(self.url) != has(self.service)",message="exactly one of url or service must be set"
type Target struct {
	// URL is an absolute http(s) URL, typically for endpoints outside the cluster.
	// +kubebuilder:validation:Pattern=`^https?://[^\s/]+`
	// +kubebuilder:validation:MaxLength=2048
	// +optional
	URL string `json:"url,omitempty"`

	// Service is a Service in the HealthCheck's namespace.
	// +optional
	Service *ServiceTarget `json:"service,omitempty"`
}

// ServiceTarget points at a port and path on an in-cluster Service.
type ServiceTarget struct {
	// Name of the Service, in the same namespace as the HealthCheck.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	Name string `json:"name"`

	// Port number on the Service.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	Port int32 `json:"port"`

	// Path to request.
	// +kubebuilder:default="/healthz"
	// +kubebuilder:validation:Pattern=`^/`
	// +optional
	Path string `json:"path,omitempty"`

	// Scheme to use.
	// +kubebuilder:validation:Enum=http;https
	// +kubebuilder:default=http
	// +optional
	Scheme string `json:"scheme,omitempty"`
}

// END target OMIT

// START expect OMIT

// Expectations define a healthy response beyond "it answered".
type Expectations struct {
	// StatusCodes that count as healthy. Empty means any 2xx or 3xx.
	// +kubebuilder:validation:MaxItems=20
	// +listType=set
	// +optional
	StatusCodes []int32 `json:"statusCodes,omitempty"`

	// MaxLatency marks a response unhealthy if it is slower than this.
	// +optional
	MaxLatency *metav1.Duration `json:"maxLatency,omitempty"`
}

// AlertSpec configures the generated alert.
type AlertSpec struct {
	// Severity label attached to the alert.
	// +kubebuilder:validation:Enum=critical;warning;info
	// +kubebuilder:default=warning
	// +optional
	Severity string `json:"severity,omitempty"`

	// For is how long the check must be failing before the alert fires.
	// +kubebuilder:default="2m"
	// +optional
	For metav1.Duration `json:"for,omitzero"`

	// RunbookURL is attached to the alert so the responder knows what to do.
	// +kubebuilder:validation:Pattern=`^https?://`
	// +optional
	RunbookURL string `json:"runbookURL,omitempty"`

	// Summary is a one-line description shown in notifications.
	// +kubebuilder:validation:MaxLength=256
	// +optional
	Summary string `json:"summary,omitempty"`
}

// END expect OMIT

// START conditions OMIT

// Condition types and reasons. Reasons are CamelCase, stable, and meant for
// machines (alerting, kubectl wait); messages are for humans.
const (
	ConditionHealthy       = "Healthy"
	ConditionAlertingReady = "AlertingReady"

	ReasonProbeSucceeded     = "ProbeSucceeded"
	ReasonProbeFailing       = "ProbeFailing"
	ReasonProbePending       = "Pending"
	ReasonSuspended          = "Suspended"
	ReasonTargetUnresolved   = "TargetUnresolved"
	ReasonRuleSynced         = "RuleSynced"
	ReasonAlertingDisabled   = "AlertingDisabled"
	ReasonBackendUnavailable = "BackendUnavailable"
	ReasonSyncFailed         = "SyncFailed"
)

// END conditions OMIT

// START status OMIT

// HealthCheckStatus is the observed state. Fields are written only when they
// change, so a steadily healthy check causes no API writes at all.
type HealthCheckStatus struct {
	// ObservedGeneration is the spec generation the status reflects.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions: Healthy and AlertingReady.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// ResolvedURL is the URL actually probed.
	// +optional
	ResolvedURL string `json:"resolvedURL,omitempty"`

	// ConsecutiveFailures counts failed probes since the last success. It
	// saturates at failureThreshold, so a long outage doesn't rewrite status
	// on every probe; the Healthy condition's lastTransitionTime says how
	// long the check has been failing.
	// +optional
	ConsecutiveFailures int32 `json:"consecutiveFailures,omitempty"`

	// LastFailure describes the most recent failed probe.
	// +optional
	LastFailure string `json:"lastFailure,omitempty"`

	// Alerting reports where the alert rule lives.
	// +optional
	Alerting *AlertingStatus `json:"alerting,omitempty"`
}

// AlertingStatus records the backend object that implements the alert.
type AlertingStatus struct {
	// Backend that owns the rule: prometheus, datadog, or none.
	Backend string `json:"backend"`
	// Ref identifies the rule in that backend, e.g. a PrometheusRule name or
	// a Datadog monitor ID.
	// +optional
	Ref string `json:"ref,omitempty"`
	// ObservedGeneration is the spec generation last synced to the backend.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// END status OMIT

// START kind OMIT

// HealthCheck continuously probes an endpoint, reports its health through
// status conditions and metrics, and keeps an alert rule in sync.
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=hc,categories=watchtower
// +kubebuilder:printcolumn:name="Healthy",type=string,JSONPath=`.status.conditions[?(@.type=="Healthy")].status`
// +kubebuilder:printcolumn:name="Reason",type=string,JSONPath=`.status.conditions[?(@.type=="Healthy")].reason`
// +kubebuilder:printcolumn:name="Failures",type=integer,JSONPath=`.status.consecutiveFailures`
// +kubebuilder:printcolumn:name="Alerting",type=string,JSONPath=`.status.alerting.backend`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// +kubebuilder:printcolumn:name="Target",type=string,JSONPath=`.status.resolvedURL`,priority=1
type HealthCheck struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// +required
	Spec HealthCheckSpec `json:"spec"`

	// +optional
	Status HealthCheckStatus `json:"status,omitzero"`
}

// END kind OMIT

// START list OMIT

// +kubebuilder:object:root=true

// HealthCheckList contains a list of HealthCheck.
type HealthCheckList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []HealthCheck `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &HealthCheck{}, &HealthCheckList{})
		return nil
	})
}

// END list OMIT
