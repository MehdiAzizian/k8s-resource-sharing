package dto

import "time"

// Role represents the cluster's role in a reservation
type Role string

const (
	// RoleRequester means this cluster is requesting resources
	RoleRequester Role = "requester"

	// RoleProvider means this cluster is providing resources
	RoleProvider Role = "provider"
)

// ReservationDTO is a protocol-agnostic representation of a resource reservation
type ReservationDTO struct {
	ID                 string                `json:"id"`
	RequesterID        string                `json:"requesterID"`
	TargetClusterID    string                `json:"targetClusterID"`
	RequestedResources ResourceQuantitiesDTO `json:"requestedResources"`
	Status             ReservationStatusDTO  `json:"status"`
	CreatedAt          time.Time             `json:"createdAt"`
}

// ReservationStatusDTO represents the status of a reservation
type ReservationStatusDTO struct {
	Phase      string     `json:"phase"` // Pending, Reserved, Active, Released, Failed
	Message    string     `json:"message"`
	ReservedAt *time.Time `json:"reservedAt,omitempty"`
	ExpiresAt  *time.Time `json:"expiresAt,omitempty"`
}
