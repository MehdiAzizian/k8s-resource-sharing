#!/bin/bash
# =============================================================================
# Test Resource Reservation Flow (Synchronous Architecture)
# This script tests the full flow:
# 1. Check cluster advertisements are registered on the broker
# 2. Create a ResourceRequest on the requester agent cluster
# 3. Verify the agent sends a synchronous reservation to the broker
# 4. Check ReservationInstruction on requester (instant, from HTTP response)
# 5. Check ProviderInstruction on provider (via 5s polling)
# 6. Verify Liqo peering is established (virtual nodes)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  $1${NC}"
}

print_error() {
    echo -e "${RED}  $1${NC}"
}

# =============================================================================
# STEP 1: Check Broker State
# =============================================================================
print_step "STEP 1: Checking Broker State"

kubectl config use-context kind-broker-cluster > /dev/null 2>&1

echo ""
echo "Registered ClusterAdvertisements:"
echo ""
kubectl get clusteradvertisements -o wide 2>/dev/null || {
    print_warning "No ClusterAdvertisements found yet"
    echo "Make sure agents are running and have connected to the broker"
}

echo ""
echo "Existing Reservations:"
echo ""
kubectl get reservations -o wide 2>/dev/null || {
    echo "No reservations yet (this is expected)"
}

# =============================================================================
# STEP 2: Create ResourceRequest on Requester Agent Cluster
# =============================================================================
print_step "STEP 2: Creating ResourceRequest on agent-cluster-1"

REQUEST_NAME="test-request-$(date +%s)"
REQUESTER_CONTEXT="kind-agent-cluster-1"

kubectl config use-context "$REQUESTER_CONTEXT" > /dev/null 2>&1

echo ""
echo "Creating ResourceRequest:"
echo "  Name:     $REQUEST_NAME"
echo "  Cluster:  agent-cluster-1 (requester)"
echo "  CPU:      500m"
echo "  Memory:   256Mi"
echo "  Priority: 10"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: rear.fluidos.eu/v1alpha1
kind: ResourceRequest
metadata:
  name: $REQUEST_NAME
  namespace: default
spec:
  requestedCPU: "500m"
  requestedMemory: "256Mi"
  priority: 10
EOF

print_success "ResourceRequest created on agent-cluster-1"

# =============================================================================
# STEP 3: Wait for Synchronous Reservation Processing
# =============================================================================
print_step "STEP 3: Waiting for Agent to Process (synchronous flow)"

echo ""
echo "The agent sends POST /api/v1/reservations to the broker..."
echo "The broker decides inline and returns the instruction in the HTTP response."
echo ""

# Wait for ResourceRequest to be processed (should be fast - synchronous)
for i in $(seq 1 12); do
    PHASE=$(kubectl get resourcerequest $REQUEST_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$PHASE" == "Reserved" ] || [ "$PHASE" == "Failed" ]; then
        break
    fi
    echo "  Waiting for ResourceRequest processing... (attempt $i/12)"
    sleep 2
done

echo ""
echo "ResourceRequest status:"
kubectl get resourcerequest $REQUEST_NAME -o wide 2>/dev/null || true

TARGET=$(kubectl get resourcerequest $REQUEST_NAME -o jsonpath='{.status.targetClusterID}' 2>/dev/null || echo "unknown")

echo ""
if [ "$PHASE" == "Reserved" ]; then
    print_success "ResourceRequest phase: $PHASE"
    print_success "Target cluster: $TARGET"
else
    print_warning "ResourceRequest phase: $PHASE"
    echo ""
    echo "If phase is 'Failed', check:"
    echo "  1. Are agents running and advertising resources?"
    echo "  2. Do agents have enough available resources?"
    echo "  3. Is the broker running?"
    echo ""
    kubectl get resourcerequest $REQUEST_NAME -o jsonpath='{.status.message}' 2>/dev/null
    echo ""
fi

# =============================================================================
# STEP 4: Check Broker-Side Reservation and Resource Lock
# =============================================================================
print_step "STEP 4: Checking Broker-Side Reservation and Resource Lock"

kubectl config use-context kind-broker-cluster > /dev/null 2>&1

echo ""
echo "Reservations on broker:"
kubectl get reservations -o wide 2>/dev/null || echo "None found"

echo ""
echo "ClusterAdvertisement Reserved field for target cluster:"
if [ "$TARGET" != "unknown" ] && [ -n "$TARGET" ]; then
    kubectl get clusteradvertisement -o jsonpath='{range .items[?(@.spec.clusterID=="'$TARGET'")]}{.metadata.name}{": Reserved="}{.spec.resources.reserved}{"\n"}{end}'
else
    echo "No target cluster assigned yet"
fi

# =============================================================================
# STEP 5: Check ReservationInstruction (Requester Side - instant)
# =============================================================================
print_step "STEP 5: Checking ReservationInstruction (requester, synchronous)"

kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1

echo ""
echo "ReservationInstructions in agent-cluster-1:"
kubectl get reservationinstructions -o wide 2>/dev/null || {
    print_warning "No ReservationInstructions found"
    echo "(Should be instant - created from the synchronous HTTP response)"
}

# =============================================================================
# STEP 6: Check ProviderInstruction (Provider Side - polling)
# =============================================================================
print_step "STEP 6: Checking ProviderInstruction (provider, via 5s polling)"

if [ "$TARGET" == "agent-cluster-2" ]; then
    kubectl config use-context kind-agent-cluster-2 > /dev/null 2>&1

    # Provider discovers instructions by polling every 5s, so wait a bit
    echo ""
    echo "Waiting for provider to discover instruction (polls every 5s)..."
    sleep 6

    echo ""
    echo "ProviderInstructions in agent-cluster-2:"
    kubectl get providerinstructions -o wide 2>/dev/null || {
        print_warning "No ProviderInstructions found"
        echo "(Provider polls every 5s - may need a few more seconds)"
    }
fi

# =============================================================================
# STEP 7: Verify Liqo Peering
# =============================================================================
print_step "STEP 7: Verifying Liqo Peering"

PEERING_OK=false

# Check if liqoctl is available
if ! command -v liqoctl &> /dev/null; then
    print_warning "liqoctl not installed - skipping Liqo verification"
else
    echo ""
    echo "Waiting for Liqo peering to establish (checking every 5s, up to 60s)..."

    # Wait for peering to be established
    for i in $(seq 1 12); do
        echo "  Checking peering status... (attempt $i/12)"

        # Switch to requester cluster and check nodes
        kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1

        # Check for virtual node from the provider
        VIRTUAL_NODES=$(kubectl get nodes 2>/dev/null | grep -i "liqo" || true)
        if [ -n "$VIRTUAL_NODES" ]; then
            PEERING_OK=true
            break
        fi

        sleep 5
    done

    echo ""
    if [ "$PEERING_OK" = true ]; then
        print_success "Liqo peering established!"
        echo ""
        echo "  Nodes in requester cluster (agent-cluster-1):"
        kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1
        kubectl get nodes -o wide 2>/dev/null
        echo ""
        echo "  The virtual node represents resources from $TARGET"
    else
        print_warning "Virtual node not yet visible"
        echo ""
        echo "  This may take longer. Check manually:"
        echo "    kubectl config use-context kind-agent-cluster-1"
        echo "    kubectl get nodes"
        echo "    liqoctl status"
    fi

    # Show Liqo status on requester
    echo ""
    echo "Liqo status on requester (agent-cluster-1):"
    kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1
    liqoctl status 2>/dev/null || print_warning "Could not get Liqo status"
fi

# =============================================================================
# SUMMARY
# =============================================================================
print_step "TEST SUMMARY"

echo ""
if [ "$PHASE" == "Reserved" ]; then
    print_success "Reservation was successfully processed!"
    echo ""
    echo "What happened:"
    echo "  1. User created ResourceRequest on agent-cluster-1 (500m CPU, 256Mi)"
    echo "  2. Agent sent POST /api/v1/reservations to broker (synchronous)"
    echo "  3. Broker selected best provider: $TARGET"
    echo "  4. Resources locked in $TARGET's ClusterAdvertisement (Reserved field)"
    echo "  5. Requester got ReservationInstruction instantly (in HTTP response)"
    echo "  6. Provider discovered ProviderInstruction (via 5s polling)"
    if [ "$PEERING_OK" = true ]; then
        echo "  7. Liqo peering established: agent-cluster-1 -> $TARGET"
        echo "  8. Virtual node created in agent-cluster-1"
        echo ""
        echo "You can now schedule workloads on the virtual node!"
        echo "  kubectl config use-context kind-agent-cluster-1"
        echo "  kubectl get nodes  # Shows virtual node from $TARGET"
    else
        echo "  7. Liqo peering: check status with 'liqoctl status'"
    fi
else
    print_warning "Reservation not in expected state"
    echo ""
    echo "Debugging:"
    echo "  kubectl config use-context kind-agent-cluster-1"
    echo "  kubectl describe resourcerequest $REQUEST_NAME"
    echo "  kubectl config use-context kind-broker-cluster"
    echo "  kubectl get clusteradvertisements -o wide"
fi

# Switch back to broker context
kubectl config use-context kind-broker-cluster > /dev/null 2>&1

echo ""
echo "ResourceRequest name for cleanup: $REQUEST_NAME"
echo "Delete with:"
echo "  kubectl config use-context kind-agent-cluster-1"
echo "  kubectl delete resourcerequest $REQUEST_NAME"
echo ""
