package handlers

import (
	"github.com/mehdiazizian/liqo-resource-broker/internal/broker"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Handler contains dependencies for HTTP handlers
type Handler struct {
	k8sClient      client.Client
	namespace      string // Default namespace for resources
	decisionEngine *broker.DecisionEngine
}

// NewHandler creates a new handler with k8s client and decision engine
func NewHandler(k8sClient client.Client, namespace string, decisionEngine *broker.DecisionEngine) *Handler {
	return &Handler{
		k8sClient:      k8sClient,
		namespace:      namespace,
		decisionEngine: decisionEngine,
	}
}
