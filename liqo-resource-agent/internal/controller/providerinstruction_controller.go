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

// ProviderInstructionReconciler acknowledges provider instructions.
type ProviderInstructionReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=providerinstructions,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=providerinstructions/status,verbs=get;update;patch

func (r *ProviderInstructionReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	instruction := &rearv1alpha1.ProviderInstruction{}
	if err := r.Get(ctx, req.NamespacedName, instruction); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("provider instruction deleted", "name", req.Name)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Check if expired - if so, we can potentially delete it or just mark as not enforced
	if instruction.Spec.ExpiresAt != nil && instruction.Spec.ExpiresAt.Time.Before(time.Now()) {
		logger.Info("provider instruction expired",
			"instruction", instruction.Name,
			"reservation", instruction.Spec.ReservationName,
			"expiresAt", instruction.Spec.ExpiresAt.Time)

		// Mark as not enforced so it won't be counted in reserved resources
		instruction.Status.Enforced = false
		instruction.Status.LastUpdateTime = metav1.Now()

		if err := r.Status().Update(ctx, instruction); err != nil {
			logger.Error(err, "failed to mark expired instruction")
			return ctrl.Result{}, err
		}

		// No need to requeue - it's expired
		return ctrl.Result{}, nil
	}

	// If already enforced, just requeue to check expiration later
	if instruction.Status.Enforced {
		// Requeue before expiration to mark it as expired promptly
		if instruction.Spec.ExpiresAt != nil {
			timeUntilExpiry := time.Until(instruction.Spec.ExpiresAt.Time)
			if timeUntilExpiry > 0 {
				return ctrl.Result{RequeueAfter: timeUntilExpiry}, nil
			}
		}
		return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
	}

	// Mark as enforced
	expiryInfo := ""
	if instruction.Spec.ExpiresAt != nil {
		expiryInfo = fmt.Sprintf("\n  └─ Expiration: %s", instruction.Spec.ExpiresAt.Format("15:04:05"))
	}
	logger.Info(fmt.Sprintf("🔒 Provider Instruction Received\n"+
		"  └─ Reservation: %s\n"+
		"  └─ Requester Cluster: %s\n"+
		"  └─ Resources: cpu=%s, memory=%s%s",
		instruction.Spec.ReservationName,
		instruction.Spec.RequesterClusterID,
		instruction.Spec.RequestedCPU,
		instruction.Spec.RequestedMemory,
		expiryInfo))

	instruction.Status.Enforced = true
	instruction.Status.LastUpdateTime = metav1.Now()

	if err := r.Status().Update(ctx, instruction); err != nil {
		logger.Error(err, "failed to enforce provider instruction")
		return ctrl.Result{}, err
	}

	// Requeue to check for expiration
	if instruction.Spec.ExpiresAt != nil {
		timeUntilExpiry := time.Until(instruction.Spec.ExpiresAt.Time)
		if timeUntilExpiry > 0 {
			logger.Info("will requeue to check expiration",
				"timeUntilExpiry", timeUntilExpiry)
			return ctrl.Result{RequeueAfter: timeUntilExpiry}, nil
		}
	}

	return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

func (r *ProviderInstructionReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&rearv1alpha1.ProviderInstruction{}).
		Named("providerinstruction").
		Complete(r)
}
