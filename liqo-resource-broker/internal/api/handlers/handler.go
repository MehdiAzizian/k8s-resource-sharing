package handlers

import (
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Handler contains dependencies for HTTP handlers
type Handler struct {
	k8sClient client.Client
	namespace string // Default namespace for resources
}

// NewHandler creates a new handler with k8s client
func NewHandler(k8sClient client.Client, namespace string) *Handler {
	return &Handler{
		k8sClient: k8sClient,
		namespace: namespace,
	}
}
