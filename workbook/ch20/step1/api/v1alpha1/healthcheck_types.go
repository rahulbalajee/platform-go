// START imports OMIT

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// END imports OMIT

// START spec OMIT

// HealthCheckSpec is the desired state of a HealthCheck.
type HealthCheckSpec struct {
	// Foo is an example field. Step 2 replaces it with the real spec.
	// +optional
	Foo *string `json:"foo,omitempty"`
}

// HealthCheckStatus is the observed state of a HealthCheck.
type HealthCheckStatus struct {
	// Conditions describe the current state of the HealthCheck.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// END spec OMIT

// START kind OMIT

// HealthCheck is the Schema for the healthchecks API.
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
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
