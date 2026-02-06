package dto

import "time"

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
