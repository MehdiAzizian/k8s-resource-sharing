#!/bin/bash
# =============================================================================
# Test Resource Reservation Flow
# This script tests the full flow:
# 1. Check cluster advertisements are registered
# 2. Create a reservation request
# 3. Verify reservation is processed
# 4. Check instructions are created on both sides
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
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
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
# STEP 2: Create Test Reservation
# =============================================================================
print_step "STEP 2: Creating Test Reservation"

RESERVATION_NAME="test-reservation-$(date +%s)"
REQUESTER_ID="agent-cluster-1"

echo ""
echo "Creating reservation:"
echo "  Name: $RESERVATION_NAME"
echo "  Requester: $REQUESTER_ID"
echo "  CPU: 500m"
echo "  Memory: 256Mi"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: broker.fluidos.eu/v1alpha1
kind: Reservation
metadata:
  name: $RESERVATION_NAME
  namespace: default
spec:
  requesterID: "$REQUESTER_ID"
  requestedResources:
    cpu: "500m"
    memory: "256Mi"
  priority: 10
EOF

print_success "Reservation created"

# =============================================================================
# STEP 3: Wait for Reservation Processing
# =============================================================================
print_step "STEP 3: Waiting for Reservation Processing"

echo ""
echo "Waiting for broker to process reservation..."
sleep 5

echo ""
echo "Reservation status:"
kubectl get reservation $RESERVATION_NAME -o yaml | grep -A 20 "status:" || true

# Get the phase
PHASE=$(kubectl get reservation $RESERVATION_NAME -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
TARGET=$(kubectl get reservation $RESERVATION_NAME -o jsonpath='{.spec.targetClusterID}' 2>/dev/null || echo "unknown")

echo ""
if [ "$PHASE" == "Reserved" ] || [ "$PHASE" == "Active" ]; then
    print_success "Reservation phase: $PHASE"
    print_success "Target cluster: $TARGET"
else
    print_warning "Reservation phase: $PHASE"
    echo ""
    echo "If phase is 'Failed', check:"
    echo "  1. Are agents running and advertising resources?"
    echo "  2. Do agents have enough available resources?"
    echo ""
    kubectl get reservation $RESERVATION_NAME -o jsonpath='{.status.message}'
    echo ""
fi

# =============================================================================
# STEP 4: Check ClusterAdvertisement Reserved Field
# =============================================================================
print_step "STEP 4: Checking Resource Lock (Reserved Field)"

echo ""
echo "ClusterAdvertisement for target cluster:"
if [ "$TARGET" != "unknown" ] && [ -n "$TARGET" ]; then
    kubectl get clusteradvertisement -o jsonpath='{range .items[?(@.spec.clusterID=="'$TARGET'")]}{.metadata.name}{": Reserved="}{.spec.resources.reserved}{"\n"}{end}'
else
    echo "No target cluster assigned yet"
fi

# =============================================================================
# STEP 5: Check Agent Instructions (Requester Side)
# =============================================================================
print_step "STEP 5: Checking Requester Agent Instructions"

kubectl config use-context kind-agent-cluster-1 > /dev/null 2>&1

echo ""
echo "ReservationInstructions in agent-cluster-1:"
kubectl get reservationinstructions -o wide 2>/dev/null || {
    print_warning "No ReservationInstructions found"
    echo "(Agent may not have polled yet - wait 30 seconds)"
}

# =============================================================================
# STEP 6: Check Agent Instructions (Provider Side)
# =============================================================================
print_step "STEP 6: Checking Provider Agent Instructions"

if [ "$TARGET" == "agent-cluster-2" ]; then
    kubectl config use-context kind-agent-cluster-2 > /dev/null 2>&1

    echo ""
    echo "ProviderInstructions in agent-cluster-2:"
    kubectl get providerinstructions -o wide 2>/dev/null || {
        print_warning "No ProviderInstructions found"
        echo "(Agent may not have polled yet - wait 30 seconds)"
    }
fi

# =============================================================================
# SUMMARY
# =============================================================================
print_step "TEST SUMMARY"

echo ""
if [ "$PHASE" == "Reserved" ] || [ "$PHASE" == "Active" ]; then
    print_success "Reservation was successfully processed!"
    echo ""
    echo "What happened:"
    echo "  1. Agent-1 requested 500m CPU + 256Mi Memory"
    echo "  2. Broker selected best cluster: $TARGET"
    echo "  3. Resources were locked in $TARGET's advertisement"
    echo "  4. Instructions will be created in both clusters"
    echo ""
    echo "Next steps:"
    echo "  - Wait 30s for agents to poll and create instructions"
    echo "  - Run this script again to see updated instruction status"
else
    print_warning "Reservation not in expected state"
    echo ""
    echo "Debugging:"
    echo "  kubectl config use-context kind-broker-cluster"
    echo "  kubectl describe reservation $RESERVATION_NAME"
    echo "  kubectl get clusteradvertisements -o wide"
fi

# Switch back to broker context
kubectl config use-context kind-broker-cluster > /dev/null 2>&1

echo ""
echo "Reservation name for cleanup: $RESERVATION_NAME"
echo "Delete with: kubectl delete reservation $RESERVATION_NAME"
echo ""
