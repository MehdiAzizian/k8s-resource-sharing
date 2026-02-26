package resource

import (
	"testing"

	brokerv1alpha1 "github.com/mehdiazizian/liqo-resource-broker/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// Test: Basic availability calculation without reserved
func TestCalculateAvailable_BasicCalculation(t *testing.T) {
	allocatable := resource.MustParse("4000m")
	allocated := resource.MustParse("1000m")

	result := CalculateAvailable(allocatable, allocated, nil)

	expected := resource.MustParse("3000m")
	if result.Cmp(expected) != 0 {
		t.Errorf("expected %s, got %s", expected.String(), result.String())
	}
}

// Test: Availability calculation with reserved
func TestCalculateAvailable_WithReserved(t *testing.T) {
	allocatable := resource.MustParse("4000m")
	allocated := resource.MustParse("1000m")
	reserved := resource.MustParse("500m")

	result := CalculateAvailable(allocatable, allocated, &reserved)

	// Available = 4000m - 1000m - 500m = 2500m
	expected := resource.MustParse("2500m")
	if result.Cmp(expected) != 0 {
		t.Errorf("expected %s, got %s", expected.String(), result.String())
	}
}

// Test: Zero reserved is same as nil reserved
func TestCalculateAvailable_ZeroReserved(t *testing.T) {
	allocatable := resource.MustParse("4000m")
	allocated := resource.MustParse("1000m")
	reserved := resource.MustParse("0")

	resultWithZero := CalculateAvailable(allocatable, allocated, &reserved)
	resultWithNil := CalculateAvailable(allocatable, allocated, nil)

	if resultWithZero.Cmp(resultWithNil) != 0 {
		t.Errorf("zero reserved (%s) should equal nil reserved (%s)",
			resultWithZero.String(), resultWithNil.String())
	}
}

// Test: Memory calculation works correctly
func TestCalculateAvailable_MemoryCalculation(t *testing.T) {
	allocatable := resource.MustParse("16Gi")
	allocated := resource.MustParse("4Gi")
	reserved := resource.MustParse("2Gi")

	result := CalculateAvailable(allocatable, allocated, &reserved)

	// Available = 16Gi - 4Gi - 2Gi = 10Gi
	expected := resource.MustParse("10Gi")
	if result.Cmp(expected) != 0 {
		t.Errorf("expected %s, got %s", expected.String(), result.String())
	}
}

// Test: UpdateAvailableResources updates CPU correctly
func TestUpdateAvailableResources_UpdatesCPU(t *testing.T) {
	resources := &brokerv1alpha1.ResourceMetrics{
		Allocatable: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("4000m"),
			Memory: resource.MustParse("8Gi"),
		},
		Allocated: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("1000m"),
			Memory: resource.MustParse("2Gi"),
		},
		Available: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("0"), // will be recalculated
			Memory: resource.MustParse("0"),
		},
		Reserved: &brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("500m"),
			Memory: resource.MustParse("1Gi"),
		},
	}

	UpdateAvailableResources(resources)

	// Expected: 4000m - 1000m - 500m = 2500m
	expectedCPU := resource.MustParse("2500m")
	if resources.Available.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected available CPU %s, got %s",
			expectedCPU.String(), resources.Available.CPU.String())
	}
}

// Test: UpdateAvailableResources updates Memory correctly
func TestUpdateAvailableResources_UpdatesMemory(t *testing.T) {
	resources := &brokerv1alpha1.ResourceMetrics{
		Allocatable: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("4000m"),
			Memory: resource.MustParse("8Gi"),
		},
		Allocated: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("1000m"),
			Memory: resource.MustParse("2Gi"),
		},
		Available: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("0"),
			Memory: resource.MustParse("0"),
		},
		Reserved: &brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("500m"),
			Memory: resource.MustParse("1Gi"),
		},
	}

	UpdateAvailableResources(resources)

	// Expected: 8Gi - 2Gi - 1Gi = 5Gi
	expectedMemory := resource.MustParse("5Gi")
	if resources.Available.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected available memory %s, got %s",
			expectedMemory.String(), resources.Available.Memory.String())
	}
}

// Test: UpdateAvailableResources handles nil Reserved
func TestUpdateAvailableResources_NilReserved(t *testing.T) {
	resources := &brokerv1alpha1.ResourceMetrics{
		Allocatable: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("4000m"),
			Memory: resource.MustParse("8Gi"),
		},
		Allocated: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("1000m"),
			Memory: resource.MustParse("2Gi"),
		},
		Available: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("0"),
			Memory: resource.MustParse("0"),
		},
		Reserved: nil, // no reservations
	}

	UpdateAvailableResources(resources)

	// Expected: 4000m - 1000m - 0 = 3000m
	expectedCPU := resource.MustParse("3000m")
	if resources.Available.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected available CPU %s, got %s",
			expectedCPU.String(), resources.Available.CPU.String())
	}

	// Expected: 8Gi - 2Gi - 0 = 6Gi
	expectedMemory := resource.MustParse("6Gi")
	if resources.Available.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected available memory %s, got %s",
			expectedMemory.String(), resources.Available.Memory.String())
	}
}

// Test: UpdateAvailableResources handles GPU when present
func TestUpdateAvailableResources_WithGPU(t *testing.T) {
	gpu2 := resource.MustParse("2")
	gpu1 := resource.MustParse("1")
	gpuReserved := resource.MustParse("0")

	resources := &brokerv1alpha1.ResourceMetrics{
		Allocatable: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("4000m"),
			Memory: resource.MustParse("8Gi"),
			GPU:    &gpu2,
		},
		Allocated: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("1000m"),
			Memory: resource.MustParse("2Gi"),
			GPU:    &gpu1,
		},
		Available: brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("0"),
			Memory: resource.MustParse("0"),
		},
		Reserved: &brokerv1alpha1.ResourceQuantities{
			CPU:    resource.MustParse("0"),
			Memory: resource.MustParse("0"),
			GPU:    &gpuReserved,
		},
	}

	UpdateAvailableResources(resources)

	// Expected GPU: 2 - 1 - 0 = 1
	expectedGPU := resource.MustParse("1")
	if resources.Available.GPU == nil {
		t.Fatal("expected GPU to be set in Available")
	}
	if resources.Available.GPU.Cmp(expectedGPU) != 0 {
		t.Errorf("expected available GPU %s, got %s",
			expectedGPU.String(), resources.Available.GPU.String())
	}
}

// Test: Formula is correct - Available = Allocatable - Allocated - Reserved
func TestUpdateAvailableResources_FormulaVerification(t *testing.T) {
	tests := []struct {
		name              string
		allocatableCPU    string
		allocatedCPU      string
		reservedCPU       string
		expectedAvailable string
	}{
		{
			name:              "basic case",
			allocatableCPU:    "4000m",
			allocatedCPU:      "1000m",
			reservedCPU:       "500m",
			expectedAvailable: "2500m",
		},
		{
			name:              "no allocation",
			allocatableCPU:    "4000m",
			allocatedCPU:      "0",
			reservedCPU:       "1000m",
			expectedAvailable: "3000m",
		},
		{
			name:              "no reservation",
			allocatableCPU:    "4000m",
			allocatedCPU:      "2000m",
			reservedCPU:       "0",
			expectedAvailable: "2000m",
		},
		{
			name:              "fully utilized",
			allocatableCPU:    "4000m",
			allocatedCPU:      "2000m",
			reservedCPU:       "2000m",
			expectedAvailable: "0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resources := &brokerv1alpha1.ResourceMetrics{
				Allocatable: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(tt.allocatableCPU),
					Memory: resource.MustParse("8Gi"),
				},
				Allocated: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(tt.allocatedCPU),
					Memory: resource.MustParse("0"),
				},
				Available: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse("0"),
					Memory: resource.MustParse("0"),
				},
				Reserved: &brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(tt.reservedCPU),
					Memory: resource.MustParse("0"),
				},
			}

			UpdateAvailableResources(resources)

			expected := resource.MustParse(tt.expectedAvailable)
			if resources.Available.CPU.Cmp(expected) != 0 {
				t.Errorf("expected %s, got %s", expected.String(), resources.Available.CPU.String())
			}
		})
	}
}
