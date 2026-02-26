package publisher

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	rearv1alpha1 "github.com/mehdiazizian/liqo-resource-agent/api/v1alpha1"
)

// ============================================================================
// LEGACY KUBERNETES TRANSPORT
// ============================================================================
// This file implements the original Kubernetes CRD-based communication.
// It is kept for backward compatibility and thesis comparison purposes.
//
// NEW CODE SHOULD USE: internal/transport/BrokerCommunicator interface
// - For HTTP transport: transport/http/client.go
// - For future transports: implement BrokerCommunicator interface
//
// This legacy implementation will be maintained but is not the recommended
// approach for new deployments.
// ============================================================================

// BrokerClient publishes advertisements to the broker cluster (LEGACY)
type BrokerClient struct {
	Client    dynamic.Interface
	ClusterID string
	Enabled   bool
	Namespace string
}

// NewBrokerClient creates a new broker client using dynamic client
func NewBrokerClient(brokerKubeconfig, clusterID, namespace string) (*BrokerClient, error) {
	// Check if broker publishing is enabled
	if brokerKubeconfig == "" {
		return &BrokerClient{
			Enabled: false,
		}, nil
	}

	// Load kubeconfig for broker cluster
	config, err := loadBrokerConfig(brokerKubeconfig)
	if err != nil {
		return nil, fmt.Errorf("failed to load broker kubeconfig: %w", err)
	}

	// Create dynamic client
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	return &BrokerClient{
		Client:    dynamicClient,
		ClusterID: clusterID,
		Enabled:   true,
		Namespace: namespace,
	}, nil
}

// loadBrokerConfig loads kubeconfig from file
func loadBrokerConfig(kubeconfigPath string) (*rest.Config, error) {
	// Expand ~ to home directory
	if len(kubeconfigPath) >= 2 && kubeconfigPath[:2] == "~/" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		kubeconfigPath = filepath.Join(home, kubeconfigPath[2:])
	}

	config, err := clientcmd.BuildConfigFromFlags("", kubeconfigPath)
	if err != nil {
		return nil, err
	}
	return config, nil
}

// PublishAdvertisement publishes or updates an advertisement in the broker
func (b *BrokerClient) PublishAdvertisement(ctx context.Context, adv *rearv1alpha1.Advertisement) error {
	if !b.Enabled {
		// Publishing disabled, skip
		return nil
	}

	// Define the GVR for ClusterAdvertisement
	gvr := schema.GroupVersionResource{
		Group:    "broker.fluidos.eu",
		Version:  "v1alpha1",
		Resource: "clusteradvertisements",
	}

	namespace := b.Namespace
	if namespace == "" {
		namespace = "default"
	}
	resourceClient := b.Client.Resource(gvr).Namespace(namespace)

	// Try to get existing advertisement to preserve resourceVersion for optimistic concurrency
	existing, err := resourceClient.Get(ctx, fmt.Sprintf("%s-adv", b.ClusterID), metav1.GetOptions{})

	// Build resources spec
	// Note: We publish Capacity, Allocatable, Allocated, and Available.
	// The Available value already accounts for locally reserved resources (via ProviderInstructions).
	// The broker manages its own Reserved field independently for immediate resource locking.
	// The broker's ClusterAdvertisementReconciler will recalculate Available using the fresh
	// Allocatable/Allocated we provide here, combined with its own Reserved tracking.
	resourcesSpec := map[string]interface{}{
		"capacity": map[string]interface{}{
			"cpu":    adv.Spec.Resources.Capacity.CPU.String(),
			"memory": adv.Spec.Resources.Capacity.Memory.String(),
		},
		"allocatable": map[string]interface{}{
			"cpu":    adv.Spec.Resources.Allocatable.CPU.String(),
			"memory": adv.Spec.Resources.Allocatable.Memory.String(),
		},
		"allocated": map[string]interface{}{
			"cpu":    adv.Spec.Resources.Allocated.CPU.String(),
			"memory": adv.Spec.Resources.Allocated.Memory.String(),
		},
		"available": map[string]interface{}{
			"cpu":    adv.Spec.Resources.Available.CPU.String(),
			"memory": adv.Spec.Resources.Available.Memory.String(),
		},
	}

	// Preserve the broker's Reserved field if it exists
	// The broker manages reservations independently, so we must not overwrite its Reserved tracking
	if err == nil && existing != nil {
		if existingSpec, ok := existing.Object["spec"].(map[string]interface{}); ok {
			if existingResources, ok := existingSpec["resources"].(map[string]interface{}); ok {
				if reserved, hasReserved := existingResources["reserved"]; hasReserved {
					resourcesSpec["reserved"] = reserved
				}
			}
		}
	}

	// Convert to unstructured
	clusterAdv := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "broker.fluidos.eu/v1alpha1",
			"kind":       "ClusterAdvertisement",
			"metadata": map[string]interface{}{
				"name":      fmt.Sprintf("%s-adv", b.ClusterID),
				"namespace": namespace,
			},
			"spec": map[string]interface{}{
				"clusterID":   adv.Spec.ClusterID,
				"clusterName": b.ClusterID,
				"resources":   resourcesSpec,
				"timestamp":   adv.Spec.Timestamp.Format("2006-01-02T15:04:05Z"),
			},
		},
	}

	if err != nil {
		// Doesn't exist, create
		_, err = resourceClient.Create(ctx, clusterAdv, metav1.CreateOptions{})
		if err != nil {
			return fmt.Errorf("failed to create advertisement in broker: %w", err)
		}
		return nil
	}

	// Exists, update with preserved resourceVersion
	existingMeta := existing.Object["metadata"].(map[string]interface{})
	clusterAdvMeta := clusterAdv.Object["metadata"].(map[string]interface{})
	clusterAdvMeta["resourceVersion"] = existingMeta["resourceVersion"]

	_, err = resourceClient.Update(ctx, clusterAdv, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("failed to update advertisement in broker: %w", err)
	}

	return nil
}
