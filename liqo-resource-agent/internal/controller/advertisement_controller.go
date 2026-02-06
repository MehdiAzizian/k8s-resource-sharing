/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
	"github.com/mehdiazizian/liqo-resource-agent/internal/metrics"
	"github.com/mehdiazizian/liqo-resource-agent/internal/publisher" // ← Add this line
	"github.com/mehdiazizian/liqo-resource-agent/internal/transport"
	"github.com/mehdiazizian/liqo-resource-agent/internal/transport/dto"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// AdvertisementReconciler reconciles an Advertisement object
type AdvertisementReconciler struct {
	client.Client
	Scheme             *runtime.Scheme
	MetricsCollector   *metrics.Collector
	BrokerClient       *publisher.BrokerClient      // Legacy Kubernetes transport
	BrokerCommunicator transport.BrokerCommunicator // New transport abstraction
	TargetKey          types.NamespacedName
	RequeueInterval    time.Duration // Configurable requeue interval
}

// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=advertisements,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=advertisements/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=rear.fluidos.eu,resources=advertisements/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch

// Reconcile is part of the main kubernetes reconciliation loop
func (r *AdvertisementReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	logger.Info("reconciling advertisement",
		"name", req.Name,
		"namespace", req.Namespace)

	// Fetch the Advertisement instance
	advertisement := &rearv1alpha1.Advertisement{}
	err := r.Get(ctx, req.NamespacedName, advertisement)
	if err != nil {
		if client.IgnoreNotFound(err) == nil {
			logger.Info("advertisement not found, may have been deleted",
				"name", req.Name,
				"namespace", req.Namespace)
			return ctrl.Result{}, nil
		}
		logger.Error(err, "failed to get advertisement",
			"name", req.Name,
			"namespace", req.Namespace)
		return ctrl.Result{}, err
	}

	// Collect current cluster metrics
	resourceData, err := r.MetricsCollector.CollectClusterResources(ctx)
	if err != nil {
		logger.Error(err, "failed to collect cluster resources")
		return r.updateStatus(ctx, advertisement, "Error", false, fmt.Sprintf("Failed to collect metrics: %v", err))
	}

	// Get cluster ID
	clusterID, err := r.MetricsCollector.GetClusterID(ctx)
	if err != nil {
		logger.Error(err, "failed to get cluster ID")
		return r.updateStatus(ctx, advertisement, "Error", false, fmt.Sprintf("Failed to get cluster ID: %v", err))
	}

	// Update the Advertisement spec with collected data
	advertisement.Spec.ClusterID = clusterID
	advertisement.Spec.Resources = *resourceData
	advertisement.Spec.Timestamp = metav1.Now()

	// Update the Advertisement resource
	if err := r.Update(ctx, advertisement); err != nil {
		logger.Error(err, "failed to update advertisement spec",
			"name", advertisement.Name,
			"namespace", advertisement.Namespace)
		return ctrl.Result{}, err
	}

	// Log with better readability - single message with newlines
	logger.Info(fmt.Sprintf("📊 Advertisement updated\n"+
		"  └─ Cluster: %s\n"+
		"  └─ CPU: allocatable=%s, allocated=%s, available=%s\n"+
		"  └─ Memory: allocatable=%s, allocated=%s, available=%s",
		clusterID,
		resourceData.Allocatable.CPU.String(),
		resourceData.Allocated.CPU.String(),
		resourceData.Available.CPU.String(),
		resourceData.Allocatable.Memory.String(),
		resourceData.Allocated.Memory.String(),
		resourceData.Available.Memory.String()))

	// Update status to indicate successful publication
	result, err := r.updateStatus(ctx, advertisement, "Active", true, "Advertisement updated successfully")

	// Publish to broker using new transport abstraction
	if r.BrokerCommunicator != nil {
		advDTO := dto.ToAdvertisementDTO(advertisement)
		if err := r.BrokerCommunicator.PublishAdvertisement(ctx, advDTO); err != nil {
			logger.Error(err, fmt.Sprintf("❌ Failed to publish to broker (will retry)\n  └─ Cluster: %s", clusterID))
			// Don't fail the reconciliation, just log the error
		} else {
			logger.Info(fmt.Sprintf("✅ Published to broker successfully (via transport abstraction)\n  └─ Cluster: %s", clusterID))
		}
	} else if r.BrokerClient != nil && r.BrokerClient.Enabled {
		// Legacy Kubernetes transport fallback
		if err := r.BrokerClient.PublishAdvertisement(ctx, advertisement); err != nil {
			logger.Error(err, fmt.Sprintf("❌ Failed to publish to broker (will retry)\n  └─ Cluster: %s", clusterID))
			// Don't fail the reconciliation, just log the error
		} else {
			logger.Info(fmt.Sprintf("✅ Published to broker successfully (via legacy client)\n  └─ Cluster: %s", clusterID))
		}
	}

	return result, err
}

// updateStatus updates the Advertisement status
func (r *AdvertisementReconciler) updateStatus(
	ctx context.Context,
	advertisement *rearv1alpha1.Advertisement,
	phase string,
	published bool,
	message string,
) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	advertisement.Status.Phase = phase
	advertisement.Status.Published = published
	advertisement.Status.Message = message
	advertisement.Status.LastUpdateTime = metav1.Now()

	if err := r.Status().Update(ctx, advertisement); err != nil {
		logger.Error(err, "failed to update advertisement status",
			"name", advertisement.Name,
			"namespace", advertisement.Namespace,
			"phase", phase)
		return ctrl.Result{}, err
	}

	// Calculate time until next clock-synchronized update
	// This ensures all agents publish at the same clock time (e.g., 14:35:00, 14:36:00)
	requeueInterval := r.RequeueInterval
	if requeueInterval == 0 {
		requeueInterval = 1 * time.Minute // Default: 1 minute
	}

	nextUpdate := calculateNextClockSync(time.Now(), requeueInterval)
	waitDuration := time.Until(nextUpdate)

	logger.Info("scheduled next advertisement update",
		"nextUpdate", nextUpdate.Format("15:04:05"),
		"waitDuration", waitDuration.Round(time.Second))

	return ctrl.Result{RequeueAfter: waitDuration}, nil
}

// calculateNextClockSync calculates the next clock-synchronized time
// For 1-minute interval: returns next minute boundary (e.g., 14:35:00, 14:36:00)
// For other intervals: aligns to nearest interval boundary
func calculateNextClockSync(now time.Time, interval time.Duration) time.Time {
	// Round interval to nearest minute for simplicity
	intervalMinutes := int(interval.Minutes())
	if intervalMinutes < 1 {
		intervalMinutes = 1
	}

	// Calculate next aligned minute
	currentMinute := now.Minute()
	nextMinute := ((currentMinute / intervalMinutes) + 1) * intervalMinutes

	// Build next sync time
	nextSync := time.Date(
		now.Year(), now.Month(), now.Day(),
		now.Hour(), nextMinute%60, 0, 0, now.Location(),
	)

	// If we rolled over to next hour
	if nextMinute >= 60 {
		nextSync = nextSync.Add(time.Hour)
	}

	return nextSync
}

// SetupWithManager sets up the controller with the Manager
func (r *AdvertisementReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Initialize metrics collector if not set
	if r.MetricsCollector == nil {
		r.MetricsCollector = &metrics.Collector{}
	}
	r.MetricsCollector.Client = r.Client

	return ctrl.NewControllerManagedBy(mgr).
		For(&rearv1alpha1.Advertisement{}).
		Watches(
			&corev1.Node{},
			handler.EnqueueRequestsFromMapFunc(r.findAdvertisementsForNode),
		).
		Watches(
			&corev1.Pod{},
			handler.EnqueueRequestsFromMapFunc(r.findAdvertisementsForPod),
		).
		Named("advertisement").
		Complete(r)
}

// findAdvertisementsForNode triggers reconciliation when nodes change
func (r *AdvertisementReconciler) findAdvertisementsForNode(ctx context.Context, node client.Object) []reconcile.Request {
	if r.TargetKey.Name == "" {
		return nil
	}
	return []reconcile.Request{{NamespacedName: r.TargetKey}}
}

// findAdvertisementsForPod triggers reconciliation when pods change
func (r *AdvertisementReconciler) findAdvertisementsForPod(ctx context.Context, pod client.Object) []reconcile.Request {
	if r.TargetKey.Name == "" {
		return nil
	}
	return []reconcile.Request{{NamespacedName: r.TargetKey}}
}
