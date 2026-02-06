package controller

import (
	"context"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
)

// ReservationInstructionReconciler processes reservation instructions from the broker.
type ReservationInstructionReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=reservationinstructions,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=reservationinstructions/status,verbs=get;update;patch

func (r *ReservationInstructionReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	instruction := &rearv1alpha1.ReservationInstruction{}
	if err := r.Get(ctx, req.NamespacedName, instruction); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("reservation instruction deleted", "name", req.Name)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Check if expired
	if instruction.Spec.ExpiresAt != nil && instruction.Spec.ExpiresAt.Time.Before(time.Now()) {
		logger.Info("reservation instruction expired",
			"instruction", instruction.Name,
			"reservation", instruction.Spec.ReservationName,
			"targetCluster", instruction.Spec.TargetClusterID,
			"expiresAt", instruction.Spec.ExpiresAt.Time)

		// Mark as not delivered since it's expired
		if instruction.Status.Delivered {
			instruction.Status.Delivered = false
			instruction.Status.LastUpdateTime = metav1.Now()

			if err := r.Status().Update(ctx, instruction); err != nil {
				logger.Error(err, "failed to mark expired instruction")
				return ctrl.Result{}, err
			}
		}

		// No need to requeue - it's expired
		return ctrl.Result{}, nil
	}

	// If already delivered, just requeue to check expiration later
	if instruction.Status.Delivered {
		// Requeue before expiration to mark it as expired promptly
		if instruction.Spec.ExpiresAt != nil {
			timeUntilExpiry := time.Until(instruction.Spec.ExpiresAt.Time)
			if timeUntilExpiry > 0 {
				return ctrl.Result{RequeueAfter: timeUntilExpiry}, nil
			}
		}
		return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
	}

	// Process the instruction - this is where Liqo peering would be triggered in production
	logger.Info(fmt.Sprintf("🎯 Reservation Instruction Received\n"+
		"  └─ Reservation: %s\n"+
		"  └─ Target Cluster: %s\n"+
		"  └─ Resources: cpu=%s, memory=%s\n"+
		"  └─ Message: %s\n"+
		"  └─ Action: ready-to-offload-workload",
		instruction.Spec.ReservationName,
		instruction.Spec.TargetClusterID,
		instruction.Spec.RequestedCPU,
		instruction.Spec.RequestedMemory,
		instruction.Spec.Message))

	// In a production system with Liqo integration, here you would:
	// 1. Trigger Liqo peering with the target cluster
	// 2. Configure virtual nodes for the requested resources
	// 3. Set up namespace offloading policies
	// 4. Create resource quotas for the borrowed resources
	//
	// For thesis demonstration, we log the instruction clearly to show
	// the requester cluster is aware of where to send workloads.

	// Mark as delivered
	instruction.Status.Delivered = true
	instruction.Status.LastUpdateTime = metav1.Now()

	if err := r.Status().Update(ctx, instruction); err != nil {
		logger.Error(err, "failed to mark reservation instruction as delivered")
		return ctrl.Result{}, err
	}

	// Requeue to check for expiration
	if instruction.Spec.ExpiresAt != nil {
		timeUntilExpiry := time.Until(instruction.Spec.ExpiresAt.Time)
		if timeUntilExpiry > 0 {
			logger.Info("reservation instruction delivered, will requeue to check expiration",
				"timeUntilExpiry", timeUntilExpiry)
			return ctrl.Result{RequeueAfter: timeUntilExpiry}, nil
		}
	}

	return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

func (r *ReservationInstructionReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&rearv1alpha1.ReservationInstruction{}).
		Named("reservationinstruction").
		Complete(r)
}
