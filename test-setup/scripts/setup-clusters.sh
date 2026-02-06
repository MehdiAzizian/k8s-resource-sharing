#!/bin/bash
# =============================================================================
# Setup Kind Clusters for Testing
# Creates: 1 broker cluster + 2 agent clusters
# =============================================================================

set -e

echo "=============================================="
echo "  Creating Kind Clusters for Testing"
echo "=============================================="

# Cluster names
BROKER_CLUSTER="broker-cluster"
AGENT1_CLUSTER="agent-cluster-1"
AGENT2_CLUSTER="agent-cluster-2"

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "Error: kind is not installed"
    echo "Install it with: brew install kind"
    exit 1
fi

# Create broker cluster
echo ""
echo "[1/3] Creating broker cluster: $BROKER_CLUSTER"
if kind get clusters | grep -q "^${BROKER_CLUSTER}$"; then
    echo "  -> Cluster already exists, skipping..."
else
    kind create cluster --name $BROKER_CLUSTER --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30443
    hostPort: 8443
    protocol: TCP
EOF
    echo "  -> Created!"
fi

# Create agent cluster 1
echo ""
echo "[2/3] Creating agent cluster: $AGENT1_CLUSTER"
if kind get clusters | grep -q "^${AGENT1_CLUSTER}$"; then
    echo "  -> Cluster already exists, skipping..."
else
    kind create cluster --name $AGENT1_CLUSTER
    echo "  -> Created!"
fi

# Create agent cluster 2
echo ""
echo "[3/3] Creating agent cluster: $AGENT2_CLUSTER"
if kind get clusters | grep -q "^${AGENT2_CLUSTER}$"; then
    echo "  -> Cluster already exists, skipping..."
else
    kind create cluster --name $AGENT2_CLUSTER
    echo "  -> Created!"
fi

echo ""
echo "=============================================="
echo "  Clusters Created Successfully!"
echo "=============================================="
echo ""
echo "Available contexts:"
kubectl config get-contexts | grep kind
echo ""
echo "Switch context with:"
echo "  kubectl config use-context kind-broker-cluster"
echo "  kubectl config use-context kind-agent-cluster-1"
echo "  kubectl config use-context kind-agent-cluster-2"
echo ""
