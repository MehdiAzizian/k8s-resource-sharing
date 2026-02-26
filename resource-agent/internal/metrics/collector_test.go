package metrics

import (
	"context"
	"testing"
	"time"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// Helper to create a fake client
func createFakeClient(objects ...runtime.Object) client.Client {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	_ = rearv1alpha1.AddToScheme(scheme)
	return fake.NewClientBuilder().WithScheme(scheme).WithRuntimeObjects(objects...).Build()
}

// Helper to create a ready node with resources
func makeNode(name, cpuCapacity, memoryCapacity, cpuAllocatable, memoryAllocatable string) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{
					Type:   corev1.NodeReady,
					Status: corev1.ConditionTrue,
				},
			},
			Capacity: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(cpuCapacity),
				corev1.ResourceMemory: resource.MustParse(memoryCapacity),
			},
			Allocatable: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(cpuAllocatable),
				corev1.ResourceMemory: resource.MustParse(memoryAllocatable),
			},
		},
	}
}

// Helper to create a not-ready node
func makeNotReadyNode(name string) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
		Status: corev1.NodeStatus{
			Conditions: []corev1.NodeCondition{
				{
					Type:   corev1.NodeReady,
					Status: corev1.ConditionFalse,
				},
			},
			Capacity: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("4000m"),
				corev1.ResourceMemory: resource.MustParse("8Gi"),
			},
			Allocatable: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("4000m"),
				corev1.ResourceMemory: resource.MustParse("8Gi"),
			},
		},
	}
}

// Helper to create a running pod with resource requests
func makePod(name, namespace, cpuRequest, memoryRequest string, phase corev1.PodPhase) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{
					Name: "main",
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse(cpuRequest),
							corev1.ResourceMemory: resource.MustParse(memoryRequest),
						},
					},
				},
			},
		},
		Status: corev1.PodStatus{
			Phase: phase,
		},
	}
}

// Helper to create a provider instruction
func makeProviderInstruction(name, cpu, memory string, enforced bool, expiresAt *time.Time) *rearv1alpha1.ProviderInstruction {
	pi := &rearv1alpha1.ProviderInstruction{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: "default",
		},
		Spec: rearv1alpha1.ProviderInstructionSpec{
			ReservationName:    "test-reservation",
			RequesterClusterID: "requester-1",
			RequestedCPU:       cpu,
			RequestedMemory:    memory,
		},
		Status: rearv1alpha1.ProviderInstructionStatus{
			Enforced: enforced,
		},
	}
	if expiresAt != nil {
		pi.Spec.ExpiresAt = &metav1.Time{Time: *expiresAt}
	}
	return pi
}

// Test: Aggregate resources from two nodes correctly
func TestCollectClusterResources_TwoNodes(t *testing.T) {
	node1 := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	node2 := makeNode("node-2", "4000m", "8Gi", "3500m", "7Gi")

	fakeClient := createFakeClient(node1, node2)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Total allocatable should be sum of both nodes: 7000m CPU, 14Gi memory
	expectedCPU := resource.MustParse("7000m")
	expectedMemory := resource.MustParse("14Gi")

	if result.Allocatable.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected allocatable CPU %s, got %s",
			expectedCPU.String(), result.Allocatable.CPU.String())
	}
	if result.Allocatable.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected allocatable memory %s, got %s",
			expectedMemory.String(), result.Allocatable.Memory.String())
	}
}

// Test: Exclude not-ready nodes from resource calculation
func TestCollectClusterResources_ExcludesNotReadyNodes(t *testing.T) {
	readyNode := makeNode("node-ready", "4000m", "8Gi", "3500m", "7Gi")
	notReadyNode := makeNotReadyNode("node-not-ready")

	fakeClient := createFakeClient(readyNode, notReadyNode)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Only ready node's resources should be counted
	expectedCPU := resource.MustParse("3500m")
	expectedMemory := resource.MustParse("7Gi")

	if result.Allocatable.CPU.Cmp(expectedCPU) != 0 {
		t.Errorf("expected allocatable CPU %s (only ready node), got %s",
			expectedCPU.String(), result.Allocatable.CPU.String())
	}
	if result.Allocatable.Memory.Cmp(expectedMemory) != 0 {
		t.Errorf("expected allocatable memory %s (only ready node), got %s",
			expectedMemory.String(), result.Allocatable.Memory.String())
	}
}

// Test: Return error when no nodes found
func TestCollectClusterResources_NoNodes(t *testing.T) {
	fakeClient := createFakeClient() // no nodes
	collector := &Collector{Client: fakeClient}

	_, err := collector.CollectClusterResources(context.Background())

	if err == nil {
		t.Error("expected error when no nodes found, got nil")
	}
}

// Test: Calculate allocated resources from running pods
func TestCollectClusterResources_CalculatesAllocatedFromPods(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	pod1 := makePod("pod-1", "default", "500m", "1Gi", corev1.PodRunning)
	pod2 := makePod("pod-2", "default", "500m", "1Gi", corev1.PodRunning)

	fakeClient := createFakeClient(node, pod1, pod2)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Allocated should be sum of pod requests: 1000m CPU, 2Gi memory
	expectedAllocatedCPU := resource.MustParse("1000m")
	expectedAllocatedMemory := resource.MustParse("2Gi")

	if result.Allocated.CPU.Cmp(expectedAllocatedCPU) != 0 {
		t.Errorf("expected allocated CPU %s, got %s",
			expectedAllocatedCPU.String(), result.Allocated.CPU.String())
	}
	if result.Allocated.Memory.Cmp(expectedAllocatedMemory) != 0 {
		t.Errorf("expected allocated memory %s, got %s",
			expectedAllocatedMemory.String(), result.Allocated.Memory.String())
	}
}

// Test: Exclude completed/failed pods from allocated calculation
func TestCollectClusterResources_ExcludesCompletedPods(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	runningPod := makePod("running-pod", "default", "500m", "1Gi", corev1.PodRunning)
	completedPod := makePod("completed-pod", "default", "500m", "1Gi", corev1.PodSucceeded)
	failedPod := makePod("failed-pod", "default", "500m", "1Gi", corev1.PodFailed)

	fakeClient := createFakeClient(node, runningPod, completedPod, failedPod)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Only running pod should be counted
	expectedAllocatedCPU := resource.MustParse("500m")

	if result.Allocated.CPU.Cmp(expectedAllocatedCPU) != 0 {
		t.Errorf("expected allocated CPU %s (only running pod), got %s",
			expectedAllocatedCPU.String(), result.Allocated.CPU.String())
	}
}

// Test: Include pending pods in allocated calculation
func TestCollectClusterResources_IncludesPendingPods(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	runningPod := makePod("running-pod", "default", "500m", "1Gi", corev1.PodRunning)
	pendingPod := makePod("pending-pod", "default", "500m", "1Gi", corev1.PodPending)

	fakeClient := createFakeClient(node, runningPod, pendingPod)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Both running and pending pods should be counted
	expectedAllocatedCPU := resource.MustParse("1000m")

	if result.Allocated.CPU.Cmp(expectedAllocatedCPU) != 0 {
		t.Errorf("expected allocated CPU %s (running + pending), got %s",
			expectedAllocatedCPU.String(), result.Allocated.CPU.String())
	}
}

// Test: Include reserved resources from enforced ProviderInstructions
func TestCollectClusterResources_IncludesReservedFromProviderInstructions(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	// Enforced instruction that hasn't expired
	instruction := makeProviderInstruction("pi-1", "500m", "1Gi", true, nil)

	fakeClient := createFakeClient(node, instruction)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available should be: allocatable - allocated - reserved = 3500m - 0 - 500m = 3000m
	expectedAvailableCPU := resource.MustParse("3000m")

	if result.Available.CPU.Cmp(expectedAvailableCPU) != 0 {
		t.Errorf("expected available CPU %s, got %s",
			expectedAvailableCPU.String(), result.Available.CPU.String())
	}
}

// Test: Exclude non-enforced ProviderInstructions from reserved calculation
func TestCollectClusterResources_ExcludesNonEnforcedInstructions(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	// NOT enforced instruction
	instruction := makeProviderInstruction("pi-1", "500m", "1Gi", false, nil)

	fakeClient := createFakeClient(node, instruction)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available should be: allocatable - allocated - reserved = 3500m - 0 - 0 = 3500m
	// (non-enforced instruction should not count as reserved)
	expectedAvailableCPU := resource.MustParse("3500m")

	if result.Available.CPU.Cmp(expectedAvailableCPU) != 0 {
		t.Errorf("expected available CPU %s (non-enforced not counted), got %s",
			expectedAvailableCPU.String(), result.Available.CPU.String())
	}
}

// Test: Exclude expired ProviderInstructions from reserved calculation
func TestCollectClusterResources_ExcludesExpiredInstructions(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	// Expired instruction (expiration time in the past)
	pastTime := time.Now().Add(-1 * time.Hour)
	instruction := makeProviderInstruction("pi-1", "500m", "1Gi", true, &pastTime)

	fakeClient := createFakeClient(node, instruction)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available should be full (expired instruction not counted)
	expectedAvailableCPU := resource.MustParse("3500m")

	if result.Available.CPU.Cmp(expectedAvailableCPU) != 0 {
		t.Errorf("expected available CPU %s (expired not counted), got %s",
			expectedAvailableCPU.String(), result.Available.CPU.String())
	}
}

// Test: Available = Allocatable - Allocated - Reserved formula
func TestCollectClusterResources_AvailableFormula(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")
	pod := makePod("pod-1", "default", "500m", "1Gi", corev1.PodRunning)
	instruction := makeProviderInstruction("pi-1", "500m", "1Gi", true, nil)

	fakeClient := createFakeClient(node, pod, instruction)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Available = Allocatable - Allocated - Reserved
	// Available = 3500m - 500m - 500m = 2500m
	expectedAvailableCPU := resource.MustParse("2500m")
	expectedAvailableMemory := resource.MustParse("5Gi") // 7Gi - 1Gi - 1Gi = 5Gi

	if result.Available.CPU.Cmp(expectedAvailableCPU) != 0 {
		t.Errorf("expected available CPU %s, got %s",
			expectedAvailableCPU.String(), result.Available.CPU.String())
	}
	if result.Available.Memory.Cmp(expectedAvailableMemory) != 0 {
		t.Errorf("expected available memory %s, got %s",
			expectedAvailableMemory.String(), result.Available.Memory.String())
	}
}

// Test: isNodeReady correctly identifies ready nodes
func TestIsNodeReady(t *testing.T) {
	tests := []struct {
		name     string
		node     *corev1.Node
		expected bool
	}{
		{
			name:     "node is ready",
			node:     makeNode("ready-node", "4000m", "8Gi", "3500m", "7Gi"),
			expected: true,
		},
		{
			name:     "node is not ready",
			node:     makeNotReadyNode("not-ready-node"),
			expected: false,
		},
		{
			name: "node has no conditions",
			node: &corev1.Node{
				ObjectMeta: metav1.ObjectMeta{Name: "no-conditions"},
				Status: corev1.NodeStatus{
					Conditions: []corev1.NodeCondition{},
				},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isNodeReady(tt.node)
			if result != tt.expected {
				t.Errorf("expected %v, got %v", tt.expected, result)
			}
		})
	}
}

// Test: GetClusterID uses override when set
func TestGetClusterID_UsesOverride(t *testing.T) {
	collector := &Collector{
		Client:            createFakeClient(),
		ClusterIDOverride: "my-custom-id",
	}

	result, err := collector.GetClusterID(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "my-custom-id" {
		t.Errorf("expected 'my-custom-id', got '%s'", result)
	}
}

// Test: Pod with init containers uses max of init vs regular containers
func TestCollectClusterResources_InitContainerMax(t *testing.T) {
	node := makeNode("node-1", "4000m", "8Gi", "3500m", "7Gi")

	// Pod with regular containers using 500m and init container using 800m
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pod-with-init",
			Namespace: "default",
		},
		Spec: corev1.PodSpec{
			InitContainers: []corev1.Container{
				{
					Name: "init",
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("800m"),
							corev1.ResourceMemory: resource.MustParse("2Gi"),
						},
					},
				},
			},
			Containers: []corev1.Container{
				{
					Name: "main",
					Resources: corev1.ResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("500m"),
							corev1.ResourceMemory: resource.MustParse("1Gi"),
						},
					},
				},
			},
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
		},
	}

	fakeClient := createFakeClient(node, pod)
	collector := &Collector{Client: fakeClient}

	result, err := collector.CollectClusterResources(context.Background())

	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Allocated should be max(init, containers) = max(800m, 500m) = 800m
	expectedAllocatedCPU := resource.MustParse("800m")

	if result.Allocated.CPU.Cmp(expectedAllocatedCPU) != 0 {
		t.Errorf("expected allocated CPU %s (max of init and containers), got %s",
			expectedAllocatedCPU.String(), result.Allocated.CPU.String())
	}
}
