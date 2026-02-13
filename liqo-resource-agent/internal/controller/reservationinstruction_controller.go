package controller

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

	// KubeconfigsDir is the directory containing kubeconfig files for remote clusters.
	// If set, the controller triggers Liqo peering automatically when an instruction arrives.
	// Kubeconfig files are expected as: <KubeconfigsDir>/<clusterID>.kubeconfig
	KubeconfigsDir string

	// ClusterID is this agent's cluster identifier (needed to locate own kubeconfig).
	ClusterID string
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

	// Process the instruction
	logger.Info(fmt.Sprintf("Reservation Instruction Received\n"+
		"  Reservation: %s\n"+
		"  Target Cluster: %s\n"+
		"  Resources: cpu=%s, memory=%s\n"+
		"  Message: %s",
		instruction.Spec.ReservationName,
		instruction.Spec.TargetClusterID,
		instruction.Spec.RequestedCPU,
		instruction.Spec.RequestedMemory,
		instruction.Spec.Message))

	// Trigger Liqo peering if kubeconfigs directory is configured
	if r.KubeconfigsDir != "" {
		logger.Info("Initiating Liqo peering with target cluster",
			"targetCluster", instruction.Spec.TargetClusterID,
			"kubeconfigsDir", r.KubeconfigsDir)

		if err := r.executeLiqoPeering(ctx, instruction.Spec.TargetClusterID); err != nil {
			logger.Error(err, "Liqo peering failed, will retry",
				"targetCluster", instruction.Spec.TargetClusterID)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}

		logger.Info("Liqo peering completed successfully",
			"localCluster", r.ClusterID,
			"remoteCluster", instruction.Spec.TargetClusterID)
	} else {
		logger.Info("Liqo peering skipped (--kubeconfigs-dir not set)",
			"action", "ready-to-offload-workload")
	}

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

// executeLiqoPeering runs liqoctl peer to establish Liqo peering with the target cluster.
func (r *ReservationInstructionReconciler) executeLiqoPeering(ctx context.Context, targetClusterID string) error {
	localKubeconfig := filepath.Join(r.KubeconfigsDir, r.ClusterID+".kubeconfig")
	remoteKubeconfig := filepath.Join(r.KubeconfigsDir, targetClusterID+".kubeconfig")

	// Verify kubeconfig files exist
	if _, err := os.Stat(localKubeconfig); os.IsNotExist(err) {
		return fmt.Errorf("local kubeconfig not found: %s", localKubeconfig)
	}
	if _, err := os.Stat(remoteKubeconfig); os.IsNotExist(err) {
		return fmt.Errorf("remote kubeconfig not found for cluster %s: %s", targetClusterID, remoteKubeconfig)
	}

	// Check that liqoctl is available
	if _, err := exec.LookPath("liqoctl"); err != nil {
		return fmt.Errorf("liqoctl not found in PATH: %w", err)
	}

	// Run liqoctl peer with a 5-minute timeout
	peerCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(peerCtx, "liqoctl", "peer",
		"--kubeconfig", localKubeconfig,
		"--remote-kubeconfig", remoteKubeconfig,
		"--gw-server-service-type", "NodePort",
	)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("liqoctl peer failed: %w\nstdout: %s\nstderr: %s",
			err, stdout.String(), stderr.String())
	}

	return nil
}

func (r *ReservationInstructionReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&rearv1alpha1.ReservationInstruction{}).
		Named("reservationinstruction").
		Complete(r)
}
