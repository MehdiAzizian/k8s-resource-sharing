package resource

import (
	"testing"

	brokerv1alpha1 "github.com/mehdiazizian/liqo-resource-broker/api/v1alpha1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Helper to create a ClusterAdvertisement for testing
func makeClusterAdvertisement(allocatableCPU, allocatableMemory, allocatedCPU, allocatedMemory, availableCPU, availableMemory string) *brokerv1alpha1.ClusterAdvertisement {
	return &brokerv1alpha1.ClusterAdvertisement{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-cluster-adv",
			Namespace: "default",
		},
		Spec: brokerv1alpha1.ClusterAdvertisementSpec{
			ClusterID: "test-cluster",
			Resources: brokerv1alpha1.ResourceMetrics{
				Allocatable: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(allocatableCPU),
					Memory: resource.MustParse(allocatableMemory),
				},
				Allocated: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(allocatedCPU),
					Memory: resource.MustParse(allocatedMemory),
				},
				Available: brokerv1alpha1.ResourceQuantities{
					CPU:    resource.MustParse(availableCPU),
					Memory: resource.MustParse(availableMemory),
				},
				// Reserved starts as nil
			},
		},
	}
}

// Test: CanReserve returns true when enough resources available
func TestCanReserve_EnoughResources(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	result := CanReserve(cluster, resource.MustParse("1000m"), resource.MustParse("2Gi"))

	if !result {
		t.Error("expected CanReserve to return true when enough resources available")
	}
}

// Test: CanReserve returns false when CPU is insufficient
func TestCanReserve_InsufficientCPU(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "1000m", "6Gi")

	// Request more CPU than available
	result := CanReserve(cluster, resource.MustParse("2000m"), resource.MustParse("1Gi"))

	if result {
		t.Error("expected CanReserve to return false when CPU is insufficient")
	}
}

// Test: CanReserve returns false when memory is insufficient
func TestCanReserve_InsufficientMemory(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "1Gi")

	// Request more memory than available
	result := CanReserve(cluster, resource.MustParse("1000m"), resource.MustParse("2Gi"))

	if result {
		t.Error("expected CanReserve to return false when memory is insufficient")
	}
}

// Test: CanReserve returns true when request exactly matches available
func TestCanReserve_ExactMatch(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	// Request exactly what's available
	result := CanReserve(cluster, resource.MustParse("3000m"), resource.MustParse("6Gi"))

	if !result {
		t.Error("expected CanReserve to return true when request exactly matches available")
	}
}

// Test: AddReservation increases Reserved field
func TestAddReservation_IncreasesReserved(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	// Add a reservation
	err := AddReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify Reserved field was created and set
	if cluster.Spec.Resources.Reserved == nil {
		t.Fatal("expected Reserved to be initialized")
	}

	expectedCPU := resource.MustParse("500m")
	expectedMemory := resource.MustParse("1Gi")

	if cluster.Spec.Resources.Reserved.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected reserved CPU %s, got %s", expectedCPU.String(), cluster.Spec.Resources.Reserved.CPU.String())
	}
	if cluster.Spec.Resources.Reserved.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected reserved memory %s, got %s", expectedMemory.String(), cluster.Spec.Resources.Reserved.Memory.String())
	}
}

// Test: AddReservation decreases Available field
func TestAddReservation_DecreasesAvailable(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	originalAvailableCPU := cluster.Spec.Resources.Available.CPU.DeepCopy()

	// Add a reservation of 500m CPU
	err := AddReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available should decrease by reserved amount
	// New available = allocatable - allocated - reserved = 4000m - 1000m - 500m = 2500m
	expectedAvailable := resource.MustParse("2500m")

	if cluster.Spec.Resources.Available.CPU.Cmp(expectedAvailable) != 0 {
		t.Errorf("expected available CPU %s (was %s), got %s",
			expectedAvailable.String(),
			originalAvailableCPU.String(),
			cluster.Spec.Resources.Available.CPU.String())
	}
}

// Test: Multiple AddReservation calls accumulate
func TestAddReservation_MultipleReservationsAccumulate(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	// Add first reservation
	_ = AddReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	// Add second reservation
	_ = AddReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	// Total reserved should be 1000m CPU, 2Gi memory
	expectedCPU := resource.MustParse("1000m")
	expectedMemory := resource.MustParse("2Gi")

	if cluster.Spec.Resources.Reserved.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected reserved CPU %s, got %s", expectedCPU.String(), cluster.Spec.Resources.Reserved.CPU.String())
	}
	if cluster.Spec.Resources.Reserved.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected reserved memory %s, got %s", expectedMemory.String(), cluster.Spec.Resources.Reserved.Memory.String())
	}

	// Available should be: 4000m - 1000m - 1000m = 2000m
	expectedAvailable := resource.MustParse("2000m")
	if cluster.Spec.Resources.Available.CPU.Cmp(expectedAvailable) != 0 {
		t.Errorf("expected available CPU %s, got %s", expectedAvailable.String(), cluster.Spec.Resources.Available.CPU.String())
	}
}

// Test: RemoveReservation decreases Reserved field
func TestRemoveReservation_DecreasesReserved(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	// First add a reservation
	_ = AddReservation(cluster, resource.MustParse("1000m"), resource.MustParse("2Gi"))

	// Then remove part of it
	err := RemoveReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Reserved should now be 500m, 1Gi
	expectedCPU := resource.MustParse("500m")
	expectedMemory := resource.MustParse("1Gi")

	if cluster.Spec.Resources.Reserved.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected reserved CPU %s, got %s", expectedCPU.String(), cluster.Spec.Resources.Reserved.CPU.String())
	}
	if cluster.Spec.Resources.Reserved.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected reserved memory %s, got %s", expectedMemory.String(), cluster.Spec.Resources.Reserved.Memory.String())
	}
}

// Test: RemoveReservation increases Available field
func TestRemoveReservation_IncreasesAvailable(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")

	// Add then remove reservation
	_ = AddReservation(cluster, resource.MustParse("1000m"), resource.MustParse("2Gi"))
	// Available is now 2000m

	err := RemoveReservation(cluster, resource.MustParse("1000m"), resource.MustParse("2Gi"))

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available should be back to original: 4000m - 1000m - 0 = 3000m
	expectedAvailable := resource.MustParse("3000m")

	if cluster.Spec.Resources.Available.CPU.Cmp(expectedAvailable) != 0 {
		t.Errorf("expected available CPU %s, got %s", expectedAvailable.String(), cluster.Spec.Resources.Available.CPU.String())
	}
}

// Test: RemoveReservation returns error when Reserved is nil
func TestRemoveReservation_ErrorWhenNoReserved(t *testing.T) {
	cluster := makeClusterAdvertisement("4000m", "8Gi", "1000m", "2Gi", "3000m", "6Gi")
	// Reserved is nil by default

	err := RemoveReservation(cluster, resource.MustParse("500m"), resource.MustParse("1Gi"))

	if err == nil {
		t.Error("expected error when removing reservation from nil Reserved, got nil")
	}
}
