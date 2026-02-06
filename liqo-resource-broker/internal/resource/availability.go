package resource

import (
	"k8s.io/apimachinery/pkg/api/resource"

	brokerv1alpha1 "github.com/mehdiazizian/liqo-resource-broker/api/v1alpha1"
)

// CalculateAvailable computes Available = Allocatable - Allocated - Reserved
// This is the single source of truth for availability calculation
func CalculateAvailable(
	allocatable, allocated resource.Quantity,
	reserved *resource.Quantity,
) resource.Quantity {
	available := allocatable.DeepCopy()
	available.Sub(allocated)
	if reserved != nil {
		available.Sub(*reserved)
	}
	return available
}

// UpdateAvailableResources recalculates and updates the Available field in ResourceMetrics
func UpdateAvailableResources(resources *brokerv1alpha1.ResourceMetrics) {
	// Calculate CPU
	reservedCPU := resource.NewQuantity(0, resource.DecimalSI)
	if resources.Reserved != nil {
		reservedCPU = &resources.Reserved.CPU
	}
	resources.Available.CPU = CalculateAvailable(
		resources.Allocatable.CPU,
		resources.Allocated.CPU,
		reservedCPU,
	)

	// Calculate Memory
	reservedMemory := resource.NewQuantity(0, resource.BinarySI)
	if resources.Reserved != nil {
		reservedMemory = &resources.Reserved.Memory
	}
	resources.Available.Memory = CalculateAvailable(
		resources.Allocatable.Memory,
		resources.Allocated.Memory,
		reservedMemory,
	)

	// Calculate GPU if present
	if resources.Allocatable.GPU != nil {
		reservedGPU := resource.NewQuantity(0, resource.DecimalSI)
		if resources.Reserved != nil && resources.Reserved.GPU != nil {
			reservedGPU = resources.Reserved.GPU
		}
		availableGPU := CalculateAvailable(
			*resources.Allocatable.GPU,
			*resources.Allocated.GPU,
			reservedGPU,
		)
		resources.Available.GPU = &availableGPU
	}
}
