package http

import (
	"context"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
	"github.com/mehdiazizian/liqo-resource-agent/internal/transport"
	"github.com/mehdiazizian/liqo-resource-agent/internal/transport/dto"
)

// ReservationPoller polls broker for reservations and creates local Instruction CRDs
type ReservationPoller struct {
	communicator         transport.BrokerCommunicator
	clusterID            string
	interval             time.Duration
	localClient          client.Client
	instructionNamespace string
}

// NewReservationPoller creates a new reservation poller
func NewReservationPoller(
	communicator transport.BrokerCommunicator,
	clusterID string,
	interval time.Duration,
	localClient client.Client,
	instructionNamespace string,
) *ReservationPoller {
	return &ReservationPoller{
		communicator:         communicator,
		clusterID:            clusterID,
		interval:             interval,
		localClient:          localClient,
		instructionNamespace: instructionNamespace,
	}
}

// Start begins polling loop for reservations
func (p *ReservationPoller) Start(ctx context.Context) error {
	logger := log.FromContext(ctx).WithName("reservation-poller")
	logger.Info("Starting reservation poller",
		"clusterID", p.clusterID,
		"interval", p.interval)

	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()

	// Initial poll
	p.poll(ctx)

	for {
		select {
		case <-ctx.Done():
			logger.Info("Stopping reservation poller")
			return nil
		case <-ticker.C:
			p.poll(ctx)
		}
	}
}

// poll fetches reservations and processes them
func (p *ReservationPoller) poll(ctx context.Context) {
	logger := log.FromContext(ctx).WithName("reservation-poller")

	// Poll as requester (this cluster is requesting resources)
	if err := p.pollAndProcess(ctx, dto.RoleRequester); err != nil {
		logger.Error(err, "Failed to poll requester reservations")
	}

	// Poll as provider (this cluster is providing resources)
	if err := p.pollAndProcess(ctx, dto.RoleProvider); err != nil {
		logger.Error(err, "Failed to poll provider reservations")
	}
}

// pollAndProcess fetches and processes reservations for a specific role
func (p *ReservationPoller) pollAndProcess(ctx context.Context, role dto.Role) error {
	logger := log.FromContext(ctx).WithName("reservation-poller")

	reservations, err := p.communicator.FetchReservations(ctx, p.clusterID, role)
	if err != nil {
		return fmt.Errorf("failed to fetch %s reservations: %w", role, err)
	}

	for _, rsv := range reservations {
		// Only process reservations in Reserved phase
		if rsv.Status.Phase != "Reserved" {
			continue
		}

		if role == dto.RoleRequester {
			if err := p.createRequesterInstruction(ctx, rsv); err != nil {
				logger.Error(err, "Failed to create requester instruction",
					"reservation", rsv.ID)
			}
		} else {
			if err := p.createProviderInstruction(ctx, rsv); err != nil {
				logger.Error(err, "Failed to create provider instruction",
					"reservation", rsv.ID)
			}
		}
	}

	return nil
}

// createRequesterInstruction creates/updates ReservationInstruction for requester role
func (p *ReservationPoller) createRequesterInstruction(ctx context.Context, rsv *dto.ReservationDTO) error {
	logger := log.FromContext(ctx).WithName("reservation-poller")

	instructionName := rsv.ID
	instruction := &rearv1alpha1.ReservationInstruction{}

	// Check if instruction already exists
	err := p.localClient.Get(ctx,
		types.NamespacedName{Name: instructionName, Namespace: p.instructionNamespace},
		instruction)

	if err == nil {
		// Instruction already exists, no need to recreate
		return nil
	}

	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("failed to check existing instruction: %w", err)
	}

	// Create new instruction
	instruction = &rearv1alpha1.ReservationInstruction{
		ObjectMeta: metav1.ObjectMeta{
			Name:      instructionName,
			Namespace: p.instructionNamespace,
		},
		Spec: rearv1alpha1.ReservationInstructionSpec{
			ReservationName: rsv.ID,
			TargetClusterID: rsv.TargetClusterID,
			RequestedCPU:    rsv.RequestedResources.CPU,
			RequestedMemory: rsv.RequestedResources.Memory,
			Message: fmt.Sprintf("Use %s for %s CPU / %s Memory",
				rsv.TargetClusterID,
				rsv.RequestedResources.CPU,
				rsv.RequestedResources.Memory),
			ExpiresAt: convertTimePtr(rsv.Status.ExpiresAt),
		},
	}

	if err := p.localClient.Create(ctx, instruction); err != nil {
		return fmt.Errorf("failed to create instruction: %w", err)
	}

	logger.Info("Created requester instruction",
		"reservation", rsv.ID,
		"targetCluster", rsv.TargetClusterID,
		"cpu", rsv.RequestedResources.CPU,
		"memory", rsv.RequestedResources.Memory)

	return nil
}

// createProviderInstruction creates/updates ProviderInstruction for provider role
func (p *ReservationPoller) createProviderInstruction(ctx context.Context, rsv *dto.ReservationDTO) error {
	logger := log.FromContext(ctx).WithName("reservation-poller")

	instructionName := fmt.Sprintf("%s-provider", rsv.ID)
	instruction := &rearv1alpha1.ProviderInstruction{}

	// Check if instruction already exists
	err := p.localClient.Get(ctx,
		types.NamespacedName{Name: instructionName, Namespace: p.instructionNamespace},
		instruction)

	if err == nil {
		// Instruction already exists, no need to recreate
		return nil
	}

	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("failed to check existing instruction: %w", err)
	}

	// Create new instruction
	instruction = &rearv1alpha1.ProviderInstruction{
		ObjectMeta: metav1.ObjectMeta{
			Name:      instructionName,
			Namespace: p.instructionNamespace,
		},
		Spec: rearv1alpha1.ProviderInstructionSpec{
			ReservationName:    rsv.ID,
			RequesterClusterID: rsv.RequesterID,
			RequestedCPU:       rsv.RequestedResources.CPU,
			RequestedMemory:    rsv.RequestedResources.Memory,
			Message: fmt.Sprintf("Hold %s CPU / %s Memory for requester %s",
				rsv.RequestedResources.CPU,
				rsv.RequestedResources.Memory,
				rsv.RequesterID),
			ExpiresAt: convertTimePtr(rsv.Status.ExpiresAt),
		},
	}

	if err := p.localClient.Create(ctx, instruction); err != nil {
		return fmt.Errorf("failed to create provider instruction: %w", err)
	}

	logger.Info("Created provider instruction",
		"reservation", rsv.ID,
		"requester", rsv.RequesterID,
		"cpu", rsv.RequestedResources.CPU,
		"memory", rsv.RequestedResources.Memory)

	return nil
}

// convertTimePtr converts *time.Time to *metav1.Time
func convertTimePtr(t *time.Time) *metav1.Time {
	if t == nil {
		return nil
	}
	return &metav1.Time{Time: *t}
}
