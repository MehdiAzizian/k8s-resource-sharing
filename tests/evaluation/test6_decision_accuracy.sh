#!/usr/bin/env bash
# Test 6: Decision accuracy
# Sets up 2 agents with different load profiles, verifies correct selection
# - agent-1 on "agents" cluster (HEAVY load via dummy pods)
# - agent-2 on "broker" cluster (LIGHT / no extra load)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/6_decision_accuracy.csv"
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 6: Decision Accuracy"
log_info "========================================="

# Create namespaces for agents
create_agent_namespace "$SHARED_CLUSTER" "ns-agent-1"
create_agent_namespace "$BROKER_CLUSTER" "ns-agent-2"

# Start broker + 2 agents on different clusters
start_broker
start_agent "agent-1" "$SHARED_CLUSTER" 1 "ns-agent-1"
start_agent "agent-2" "$BROKER_CLUSTER" 2 "ns-agent-2"
wait_for_cluster_advertisement "agent-1" 120
wait_for_cluster_advertisement "agent-2" 120

log_info "Both agents connected. Creating different load profiles..."

# Deploy heavy load on the "agents" cluster (agent-1 sees less available resources)
for p in $(seq 1 6); do
    deploy_dummy_pod "$SHARED_CLUSTER" "load-heavy-$p" "500m" "256Mi"
done

# "broker" cluster (agent-2) has no extra load -> more available resources

log_info "Load deployed. Settling ${SETTLE_SECS}s for advertisements to update..."
sleep "$SETTLE_SECS"

# Show current state
log_info "Current cluster states on broker:"
kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
    get clusteradvertisements -n default \
    -o custom-columns='CLUSTER:.spec.clusterID,AVAIL-CPU:.spec.resources.available.cpu,AVAIL-MEM:.spec.resources.available.memory' 2>/dev/null || true

echo "scenario,requested_cpu,requested_mem,chosen_cluster,expected_cluster,correct" > "$OUTPUT"

# Scenario 1: Small request - should go to agent-2 (more available resources)
log_info "Scenario 1: Small request (200m CPU, 128Mi)"
create_reservation "accuracy-1" "external-requester" "200m" "128Mi"
if wait_for_reservation_phase "accuracy-1" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-1")
    expected="agent-2"
    correct=$([[ "$target" == "$expected" ]] && echo "yes" || echo "no")
    log_info "  Chosen: $target, Expected: $expected, Correct: $correct"
    echo "small_request,200m,128Mi,$target,$expected,$correct" >> "$OUTPUT"
else
    log_warn "  Reservation did not resolve"
    echo "small_request,200m,128Mi,TIMEOUT,agent-2,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-1"
sleep 5

# Scenario 2: Medium request - should still prefer lighter cluster
log_info "Scenario 2: Medium request (1 CPU, 512Mi)"
create_reservation "accuracy-2" "external-requester" "1" "512Mi"
if wait_for_reservation_phase "accuracy-2" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-2")
    expected="agent-2"
    correct=$([[ "$target" == "$expected" ]] && echo "yes" || echo "no")
    log_info "  Chosen: $target, Expected: $expected, Correct: $correct"
    echo "medium_request,1,512Mi,$target,$expected,$correct" >> "$OUTPUT"
else
    echo "medium_request,1,512Mi,TIMEOUT,agent-2,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-2"
sleep 5

# Scenario 3: Large request that may exceed heavily-loaded cluster
log_info "Scenario 3: Large request (2 CPU, 1Gi)"
create_reservation "accuracy-3" "external-requester" "2" "1Gi"
if wait_for_reservation_phase "accuracy-3" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-3")
    # Should not be agent-1 (too loaded)
    correct=$([[ "$target" == "agent-2" ]] && echo "yes" || echo "no")
    log_info "  Chosen: $target, Expected: agent-2, Correct: $correct"
    echo "large_request,2,1Gi,$target,agent-2,$correct" >> "$OUTPUT"
else
    echo "large_request,2,1Gi,TIMEOUT,agent-2,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-3"
sleep 5

# Scenario 4: Consecutive requests - second may go to different cluster due to resource locking
log_info "Scenario 4: Two consecutive requests (reservation locking)"
create_reservation "accuracy-4a" "external-requester" "1" "512Mi"
wait_for_reservation_phase "accuracy-4a" "Reserved" 60
target_a=$(get_reservation_target "accuracy-4a")
sleep 2

create_reservation "accuracy-4b" "external-requester" "1" "512Mi"
if wait_for_reservation_phase "accuracy-4b" "Reserved" 60; then
    target_b=$(get_reservation_target "accuracy-4b")
    log_info "  First: $target_a, Second: $target_b"
    echo "consecutive_1st,1,512Mi,$target_a,agent-2,$([[ "$target_a" == "agent-2" ]] && echo yes || echo no)" >> "$OUTPUT"
    echo "consecutive_2nd,1,512Mi,$target_b,varies,yes" >> "$OUTPUT"
else
    echo "consecutive_2nd,1,512Mi,TIMEOUT,varies,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-4a"
delete_reservation "accuracy-4b"
sleep 5

# Scenario 5: Request too large for any cluster - should fail
log_info "Scenario 5: Impossibly large request (100 CPU, 500Gi)"
create_reservation "accuracy-5" "external-requester" "100" "500Gi"
if wait_for_reservation_phase "accuracy-5" "Failed" 30; then
    log_info "  Correctly rejected: too large for any cluster"
    echo "impossible_request,100,500Gi,NONE,NONE,yes" >> "$OUTPUT"
elif wait_for_reservation_phase "accuracy-5" "Reserved" 10; then
    target=$(get_reservation_target "accuracy-5")
    log_warn "  Unexpectedly accepted by: $target"
    echo "impossible_request,100,500Gi,$target,NONE,no" >> "$OUTPUT"
else
    # Stayed Pending - also acceptable (no cluster could satisfy)
    log_info "  Stayed Pending (no suitable cluster)"
    echo "impossible_request,100,500Gi,PENDING,NONE,yes" >> "$OUTPUT"
fi
delete_reservation "accuracy-5"

# Cleanup dummy pods
for p in $(seq 1 6); do delete_dummy_pod "$SHARED_CLUSTER" "load-heavy-$p"; done

stop_all

log_info "========================================="
log_info "  Test 6 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
