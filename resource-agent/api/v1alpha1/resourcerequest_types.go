package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ResourceRequestSpec defines the desired state of ResourceRequest.
// A user creates this CRD to request resources from remote clusters.
// The agent sends a synchronous reservation request to the broker.
type ResourceRequestSpec struct {
	// RequestedCPU is the CPU quantity to request (e.g., "500m", "2").
	RequestedCPU string `json:"requestedCPU"`

	// RequestedMemory is the memory quantity to request (e.g., "256Mi", "1Gi").
	RequestedMemory string `json:"requestedMemory"`

	// Priority of this request (higher number = higher priority).
	// +optional
	Priority int32 `json:"priority,omitempty"`

	// Duration is how long the reservation should last (e.g., "1h", "30m").
	// +optional
	Duration string `json:"duration,omitempty"`
}

// ResourceRequestStatus defines the observed state of ResourceRequest.
type ResourceRequestStatus struct {
	// Phase represents the current state: Pending, Reserved, Failed.
	// +optional
	Phase string `json:"phase,omitempty"`

	// TargetClusterID is the cluster selected by the broker.
	// +optional
	TargetClusterID string `json:"targetClusterID,omitempty"`

	// ReservationName is the broker-side reservation ID.
	// +optional
	ReservationName string `json:"reservationName,omitempty"`

	// Message provides additional information about the status.
	// +optional
	Message string `json:"message,omitempty"`

	// LastUpdateTime records the last status update.
	// +optional
	LastUpdateTime metav1.Time `json:"lastUpdateTime,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced
// +kubebuilder:printcolumn:name="CPU",type=string,JSONPath=`.spec.requestedCPU`
// +kubebuilder:printcolumn:name="Memory",type=string,JSONPath=`.spec.requestedMemory`
// +kubebuilder:printcolumn:name="Target",type=string,JSONPath=`.status.targetClusterID`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// ResourceRequest is created by a user to request resources from remote clusters.
// The agent processes it by sending a synchronous reservation request to the broker.
type ResourceRequest struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ResourceRequestSpec   `json:"spec,omitempty"`
	Status ResourceRequestStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// ResourceRequestList contains a list of ResourceRequest.
type ResourceRequestList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ResourceRequest `json:"items"`
}

func init() {
	SchemeBuilder.Register(&ResourceRequest{}, &ResourceRequestList{})
}
