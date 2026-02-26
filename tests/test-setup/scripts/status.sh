#!/bin/bash
# =============================================================================
# Check Status of All Clusters
# Shows advertisements, reservations, instructions, and Liqo peering status
# =============================================================================

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

subsection() {
    echo -e "\n${YELLOW}>> $1${NC}"
}

# =============================================================================
# BROKER CLUSTER
# =============================================================================
section "BROKER CLUSTER (kind-broker-cluster)"

kubectl config use-context kind-broker-cluster > /dev/null 2>&1

subsection "ClusterAdvertisements (resources published by agents)"
kubectl get clusteradvertisements -o wide 2>/dev/null || echo "None found"

subsection "Reservations (resource requests)"
kubectl get reservations -o wide 2>/dev/null || echo "None found"

# =============================================================================
# AGENT CLUSTER 1
# =============================================================================
section "AGENT CLUSTER 1 (kind-agent-cluster-1)"

kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1

subsection "Local Advertisement"
kubectl get advertisements -o wide 2>/dev/null || echo "None found"

subsection "ReservationInstructions (as requester)"
kubectl get reservationinstructions -o wide 2>/dev/null || echo "None found"

subsection "ProviderInstructions (as provider)"
kubectl get providerinstructions -o wide 2>/dev/null || echo "None found"

subsection "Nodes (check for Liqo virtual nodes)"
kubectl get nodes -o wide 2>/dev/null || echo "None found"

if command -v liqoctl &> /dev/null; then
    subsection "Liqo Peering Status"
    liqoctl status peer 2>/dev/null || echo "No Liqo peering info"
fi

# =============================================================================
# AGENT CLUSTER 2
# =============================================================================
section "AGENT CLUSTER 2 (kind-agent-cluster-2)"

kubectl config use-context kind-agent-cluster-2 > /dev/null 2>&1

subsection "Local Advertisement"
kubectl get advertisements -o wide 2>/dev/null || echo "None found"

subsection "ReservationInstructions (as requester)"
kubectl get reservationinstructions -o wide 2>/dev/null || echo "None found"

subsection "ProviderInstructions (as provider)"
kubectl get providerinstructions -o wide 2>/dev/null || echo "None found"

subsection "Nodes (check for Liqo virtual nodes)"
kubectl get nodes -o wide 2>/dev/null || echo "None found"

if command -v liqoctl &> /dev/null; then
    subsection "Liqo Peering Status"
    liqoctl status peer 2>/dev/null || echo "No Liqo peering info"
fi

# Switch back to broker
kubectl config use-context kind-broker-cluster > /dev/null 2>&1

echo ""
echo -e "${GREEN}Status check complete!${NC}"
echo ""
