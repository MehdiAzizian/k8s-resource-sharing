package publisher

import (
	"context"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
)

// ============================================================================
// LEGACY KUBERNETES TRANSPORT
// ============================================================================
// This file implements the original Kubernetes Watch-based notification system.
// It is kept for backward compatibility and thesis comparison purposes.
//
// NEW CODE SHOULD USE: transport/http/poller.go
// - For HTTP transport: polls broker REST API every 30 seconds
// - For future transports: implement similar polling/push mechanism
//
// This legacy implementation will be maintained but is not the recommended
// approach for new deployments.
// ============================================================================

// ReservationWatcher watches for reservations on the broker (LEGACY).
type ReservationWatcher struct {
	Client               dynamic.Interface
	LocalClient          client.Client
	ClusterID            string
	Enabled              bool
	InstructionNamespace string
	BrokerNamespace      string
	RequesterNamespace   string
}

// NewReservationWatcher creates a new reservation watcher.
func NewReservationWatcher(brokerClient *BrokerClient, localClient client.Client, instructionNamespace string) *ReservationWatcher {
	if brokerClient == nil {
		return &ReservationWatcher{Enabled: false}
	}

	ns := instructionNamespace
	if ns == "" {
		ns = "default"
	}

	return &ReservationWatcher{
		Client:               brokerClient.Client,
		LocalClient:          localClient,
		ClusterID:            brokerClient.ClusterID,
		Enabled:              brokerClient.Enabled,
		InstructionNamespace: ns,
		BrokerNamespace:      brokerClient.Namespace,
		RequesterNamespace:   ns,
	}
}

// Start starts watching for reservations.
func (w *ReservationWatcher) Start(ctx context.Context) error {
	if !w.Enabled {
		return nil
	}

	logger := log.FromContext(ctx).WithName("reservation-watcher")
	logger.Info("Starting reservation watcher", "clusterID", w.ClusterID)

	gvr := schema.GroupVersionResource{
		Group:    "broker.fluidos.eu",
		Version:  "v1alpha1",
		Resource: "reservations",
	}

	remoteNamespace := w.BrokerNamespace
	if remoteNamespace == "" {
		remoteNamespace = "default"
	}

	// Exponential backoff parameters
	backoff := 1 * time.Second
	maxBackoff := 60 * time.Second
	failureCount := 0

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
			watchInterface, err := w.Client.Resource(gvr).Namespace(remoteNamespace).Watch(ctx, metav1.ListOptions{})
			if err != nil {
				failureCount++
				logger.Error(err, "failed to start watch on broker reservations",
					"namespace", remoteNamespace,
					"retryDelay", backoff,
					"failureCount", failureCount)
				time.Sleep(backoff)

				// Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s (max)
				backoff = backoff * 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
				continue
			}

			// Reset backoff on successful watch
			backoff = 1 * time.Second
			failureCount = 0

			logger.Info("watching for reservations on broker",
				"namespace", remoteNamespace,
				"clusterID", w.ClusterID)

			for event := range watchInterface.ResultChan() {
				unstructuredObj, ok := event.Object.(*unstructured.Unstructured)
				if !ok {
					continue
				}

				spec, found, _ := unstructured.NestedMap(unstructuredObj.Object, "spec")
				if !found {
					continue
				}

				requesterID, requesterFound, _ := unstructured.NestedString(spec, "requesterID")
				targetCluster, targetFound, _ := unstructured.NestedString(spec, "targetClusterID")
				if (!requesterFound && !targetFound) || (requesterID != w.ClusterID && targetCluster != w.ClusterID) {
					continue
				}

				status, found, _ := unstructured.NestedMap(unstructuredObj.Object, "status")
				if !found {
					continue
				}

				phase, found, _ := unstructured.NestedString(status, "phase")
				if !found {
					continue
				}

				if phase != "Reserved" {
					continue
				}

				resources, resFound, _ := unstructured.NestedMap(spec, "requestedResources")
				if !resFound {
					continue
				}

				cpu, _, _ := unstructured.NestedString(resources, "cpu")
				memory, _, _ := unstructured.NestedString(resources, "memory")
				expiresAt, _, _ := unstructured.NestedString(status, "expiresAt")

				if requesterID == w.ClusterID {
					logger.Info("reservation fulfilled - this cluster is the requester",
						"reservation", unstructuredObj.GetName(),
						"requester", requesterID,
						"targetCluster", targetCluster,
						"requestedCPU", cpu,
						"requestedMemory", memory,
						"expiresAt", expiresAt,
						"action", "use-target-cluster")
					if w.LocalClient != nil {
						if err := w.upsertRequesterInstruction(ctx, unstructuredObj, targetCluster, cpu, memory, expiresAt); err != nil {
							logger.Error(err, "failed to persist reservation instruction",
								"instruction", unstructuredObj.GetName(),
								"namespace", w.InstructionNamespace)
						} else {
							logger.Info("created requester instruction successfully",
								"instruction", unstructuredObj.GetName(),
								"targetCluster", targetCluster)
						}
					}
				}

				if targetCluster == w.ClusterID {
					logger.Info("provider reservation received - this cluster is the provider",
						"reservation", unstructuredObj.GetName(),
						"requester", requesterID,
						"requestedCPU", cpu,
						"requestedMemory", memory,
						"expiresAt", expiresAt,
						"action", "reserve-resources")
					if w.LocalClient != nil {
						instructionName := fmt.Sprintf("%s-provider", unstructuredObj.GetName())
						if err := w.upsertProviderInstruction(ctx, unstructuredObj, requesterID, cpu, memory, expiresAt); err != nil {
							logger.Error(err, "failed to persist provider instruction",
								"instruction", instructionName,
								"namespace", w.InstructionNamespace)
						} else {
							logger.Info("created provider instruction successfully",
								"instruction", instructionName,
								"requester", requesterID)
						}
					}
				}
			}

			logger.Info("watch channel closed, restarting with minimal delay",
				"namespace", remoteNamespace)
			// Don't increase backoff for clean watch closures
			time.Sleep(1 * time.Second)
		}
	}
}

func (w *ReservationWatcher) upsertRequesterInstruction(
	ctx context.Context,
	reservation *unstructured.Unstructured,
	targetCluster, cpu, memory, expiresAt string,
) error {
	name := reservation.GetName()
	ns := w.InstructionNamespace
	if ns == "" {
		ns = "default"
	}

	spec := rearv1alpha1.ReservationInstructionSpec{
		ReservationName: name,
		TargetClusterID: targetCluster,
		RequestedCPU:    cpu,
		RequestedMemory: memory,
		Message: fmt.Sprintf("Use %s for %s CPU / %s Memory",
			targetCluster, cpu, memory),
	}

	if expiresAt != "" {
		if parsed, err := time.Parse(time.RFC3339, expiresAt); err == nil {
			t := metav1.NewTime(parsed)
			spec.ExpiresAt = &t
		}
	}

	instruction := &rearv1alpha1.ReservationInstruction{}
	err := w.LocalClient.Get(ctx, types.NamespacedName{Name: name, Namespace: ns}, instruction)
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return err
		}
		instruction = &rearv1alpha1.ReservationInstruction{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: ns,
			},
			Spec: spec,
		}
		if err := w.LocalClient.Create(ctx, instruction); err != nil {
			return err
		}
	} else {
		instruction.Spec = spec
		if err := w.LocalClient.Update(ctx, instruction); err != nil {
			return err
		}
	}

	instruction.Status.ObservedReservationResourceVersion = reservation.GetResourceVersion()
	instruction.Status.Delivered = false
	instruction.Status.LastUpdateTime = metav1.Now()

	return w.LocalClient.Status().Update(ctx, instruction)
}

func (w *ReservationWatcher) upsertProviderInstruction(
	ctx context.Context,
	reservation *unstructured.Unstructured,
	requester, cpu, memory, expiresAt string,
) error {
	name := fmt.Sprintf("%s-provider", reservation.GetName())
	ns := w.InstructionNamespace
	if ns == "" {
		ns = "default"
	}

	spec := rearv1alpha1.ProviderInstructionSpec{
		ReservationName:    reservation.GetName(),
		RequesterClusterID: requester,
		RequestedCPU:       cpu,
		RequestedMemory:    memory,
		Message: fmt.Sprintf("Hold %s CPU / %s Memory for requester %s",
			cpu, memory, requester),
	}

	if expiresAt != "" {
		if parsed, err := time.Parse(time.RFC3339, expiresAt); err == nil {
			t := metav1.NewTime(parsed)
			spec.ExpiresAt = &t
		}
	}

	providerInstruction := &rearv1alpha1.ProviderInstruction{}
	err := w.LocalClient.Get(ctx, types.NamespacedName{Name: name, Namespace: ns}, providerInstruction)
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return err
		}
		providerInstruction = &rearv1alpha1.ProviderInstruction{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: ns,
			},
			Spec: spec,
		}
		if err := w.LocalClient.Create(ctx, providerInstruction); err != nil {
			return err
		}
	} else {
		providerInstruction.Spec = spec
		if err := w.LocalClient.Update(ctx, providerInstruction); err != nil {
			return err
		}
	}

	providerInstruction.Status.Enforced = false
	providerInstruction.Status.LastUpdateTime = metav1.Now()

	return w.LocalClient.Status().Update(ctx, providerInstruction)
}
