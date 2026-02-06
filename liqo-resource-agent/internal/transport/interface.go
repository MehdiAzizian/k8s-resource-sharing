package transport

import (
	"context"

	"github.com/mehdiazizian/liqo-resource-agent/internal/transport/dto"
)

// BrokerCommunicator abstracts broker communication protocol (agent-side interface)
// Implementations: HTTP REST API, Kubernetes CRD-based, MQTT, etc.
type BrokerCommunicator interface {
	// PublishAdvertisement publishes cluster resource advertisement to broker
	PublishAdvertisement(ctx context.Context, adv *dto.AdvertisementDTO) error

	// FetchReservations retrieves reservations for this cluster by role
	FetchReservations(ctx context.Context, clusterID string, role dto.Role) ([]*dto.ReservationDTO, error)

	// Ping checks connectivity to broker
	Ping(ctx context.Context) error

	// Close cleans up resources
	Close() error
}
