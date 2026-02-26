package broker

import (
	"context"
	"fmt"
	"strconv"

	brokerv1alpha1 "github.com/mehdiazizian/liqo-resource-broker/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// DecisionEngine selects the best cluster for resource allocation
type DecisionEngine struct {
	Client client.Client
}

// SelectBestCluster finds the most suitable cluster based on requested resources
func (d *DecisionEngine) SelectBestCluster(
	ctx context.Context,
	requesterID string,
	requestedCPU, requestedMemory resource.Quantity,
	priority int32,
) (*brokerv1alpha1.ClusterAdvertisement, error) {

	// List all cluster advertisements
	advList := &brokerv1alpha1.ClusterAdvertisementList{}
	if err := d.Client.List(ctx, advList); err != nil {
		return nil, fmt.Errorf("failed to list cluster advertisements: %w", err)
	}

	if len(advList.Items) == 0 {
		return nil, fmt.Errorf("no clusters available")
	}

	var bestCluster *brokerv1alpha1.ClusterAdvertisement
	var bestScore float64 = -1

	for i := range advList.Items {
		cluster := &advList.Items[i]

		// Skip if it's the requester's own cluster
		if cluster.Spec.ClusterID == requesterID {
			continue
		}

		// Skip inactive clusters
		if !cluster.Status.Active {
			continue
		}

		// Check if cluster has enough resources
		if !d.hasEnoughResources(cluster, requestedCPU, requestedMemory) {
			continue
		}

		// Calculate score
		score := d.calculateScore(cluster, requestedCPU, requestedMemory, priority)

		if score > bestScore {
			bestScore = score
			bestCluster = cluster
		}
	}

	if bestCluster == nil {
		return nil, fmt.Errorf("no suitable cluster found for requested resources")
	}

	return bestCluster, nil
}

// hasEnoughResources checks if cluster has sufficient available resources
func (d *DecisionEngine) hasEnoughResources(
	cluster *brokerv1alpha1.ClusterAdvertisement,
	requestedCPU, requestedMemory resource.Quantity,
) bool {
	availableCPU := cluster.Spec.Resources.Available.CPU
	availableMemory := cluster.Spec.Resources.Available.Memory

	return availableCPU.Cmp(requestedCPU) >= 0 && availableMemory.Cmp(requestedMemory) >= 0
}

// calculateScore computes a score for the cluster based on availability
// Higher score = better choice
func (d *DecisionEngine) calculateScore(
	cluster *brokerv1alpha1.ClusterAdvertisement,
	requestedCPU, requestedMemory resource.Quantity,
	priority int32,
) float64 {
	// Calculate CPU utilization after reservation (0-1)
	allocatableCPU := cluster.Spec.Resources.Allocatable.CPU.AsApproximateFloat64()
	availableCPU := cluster.Spec.Resources.Available.CPU.AsApproximateFloat64()
	requestedCPUFloat := requestedCPU.AsApproximateFloat64()

	cpuUtilization := 1.0 - ((availableCPU - requestedCPUFloat) / allocatableCPU)

	// Calculate Memory utilization after reservation (0-1)
	allocatableMemory := cluster.Spec.Resources.Allocatable.Memory.AsApproximateFloat64()
	availableMemory := cluster.Spec.Resources.Available.Memory.AsApproximateFloat64()
	requestedMemoryFloat := requestedMemory.AsApproximateFloat64()

	memoryUtilization := 1.0 - ((availableMemory - requestedMemoryFloat) / allocatableMemory)

	// Balanced score: prefer clusters with lower utilization (more headroom)
	// Score is higher when utilization is lower
	score := (1.0 - cpuUtilization*0.5) + (1.0 - memoryUtilization*0.5)

	// If cost info is available, factor it in (lower cost = higher score)
	if cluster.Spec.Cost != nil {
		// For now, we just ensure cost doesn't make score negative
		// In production, you'd normalize cost and subtract it
		score = score * 0.9 // Slight penalty if cost exists but not optimized
	}

	priorityBonus := float64(priority) * 0.01

	return score + priorityBonus
}

// UpdateClusterScore updates the score field in the cluster advertisement status
func (d *DecisionEngine) UpdateClusterScore(
	ctx context.Context,
	cluster *brokerv1alpha1.ClusterAdvertisement,
) error {
	// Calculate base score (without specific reservation request)
	score := d.calculateBaseScore(cluster)

	cluster.Status.Score = strconv.FormatFloat(score, 'f', 2, 64)

	return d.Client.Status().Update(ctx, cluster)
}

// calculateBaseScore computes the base score for a cluster
func (d *DecisionEngine) calculateBaseScore(cluster *brokerv1alpha1.ClusterAdvertisement) float64 {
	allocatableCPU := cluster.Spec.Resources.Allocatable.CPU.AsApproximateFloat64()
	availableCPU := cluster.Spec.Resources.Available.CPU.AsApproximateFloat64()

	allocatableMemory := cluster.Spec.Resources.Allocatable.Memory.AsApproximateFloat64()
	availableMemory := cluster.Spec.Resources.Available.Memory.AsApproximateFloat64()

	if allocatableCPU == 0 || allocatableMemory == 0 {
		return 0
	}

	// Score based on available percentage (0-100)
	cpuAvailablePercent := (availableCPU / allocatableCPU) * 50
	memoryAvailablePercent := (availableMemory / allocatableMemory) * 50

	return cpuAvailablePercent + memoryAvailablePercent
}
