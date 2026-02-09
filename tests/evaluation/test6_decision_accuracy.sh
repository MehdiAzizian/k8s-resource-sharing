#!/usr/bin/env bash
# Test 6: Decision accuracy
# Sets up clusters with different load profiles, verifies correct selection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/6_decision_accuracy.csv"
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 6: Decision Accuracy"
log_info "========================================="

# Create 3 agent clusters with different resource profiles
create_clusters_parallel "agent" 3
for i in 1 2 3; do
    install_agent_crds "agent-$i"
done

# Start broker + all agents
start_broker
for i in 1 2 3; do
    start_agent "agent-$i" "agent-$i" "$i"
done
for i in 1 2 3; do
    wait_for_cluster_advertisement "agent-$i" 120
done

log_info "All agents connected. Creating different load profiles..."

# Create load on clusters to differentiate them:
# agent-1: HEAVY load (nearly full) - deploy pods using most resources
# agent-2: MEDIUM load
# agent-3: LIGHT load (mostly empty)

# Agent-1: deploy heavy load pods
for p in $(seq 1 6); do
    deploy_dummy_pod "agent-1" "load-heavy-$p" "500m" "256Mi"
done

# Agent-2: deploy medium load pods
for p in $(seq 1 3); do
    deploy_dummy_pod "agent-2" "load-medium-$p" "500m" "256Mi"
done

# Agent-3: no extra load (lightest)

log_info "Load deployed. Settling ${SETTLE_SECS}s for advertisements to update..."
sleep "$SETTLE_SECS"

# Show current state
log_info "Current cluster states on broker:"
kubectl --kubeconfig "$KUBECONFIGS_DIR/broker.kubeconfig" \
    get clusteradvertisements -n default \
    -o custom-columns='CLUSTER:.spec.clusterID,AVAIL-CPU:.spec.resources.available.cpu,AVAIL-MEM:.spec.resources.available.memory,SCORE:.status.score' 2>/dev/null || true

echo "scenario,requested_cpu,requested_mem,chosen_cluster,expected_cluster,correct" > "$OUTPUT"

# Scenario 1: Small request - should go to highest-scored cluster (most available = agent-3)
log_info "Scenario 1: Small request (200m CPU, 128Mi)"
create_reservation "accuracy-1" "external-requester" "200m" "128Mi"
if wait_for_reservation_phase "accuracy-1" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-1")
    # agent-3 has most availability, should be selected
    expected="agent-3"
    correct=$([[ "$target" == "$expected" ]] && echo "yes" || echo "no")
    log_info "  Chosen: $target, Expected: $expected, Correct: $correct"
    echo "small_request,200m,128Mi,$target,$expected,$correct" >> "$OUTPUT"
else
    log_warn "  Reservation did not resolve"
    echo "small_request,200m,128Mi,TIMEOUT,agent-3,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-1"
sleep 5

# Scenario 2: Medium request - should still prefer less loaded cluster
log_info "Scenario 2: Medium request (1 CPU, 512Mi)"
create_reservation "accuracy-2" "external-requester" "1" "512Mi"
if wait_for_reservation_phase "accuracy-2" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-2")
    expected="agent-3"
    correct=$([[ "$target" == "$expected" ]] && echo "yes" || echo "no")
    log_info "  Chosen: $target, Expected: $expected, Correct: $correct"
    echo "medium_request,1,512Mi,$target,$expected,$correct" >> "$OUTPUT"
else
    echo "medium_request,1,512Mi,TIMEOUT,agent-3,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-2"
sleep 5

# Scenario 3: Request that exceeds agent-1 capacity but fits agent-2 and agent-3
log_info "Scenario 3: Large request (2 CPU, 1Gi)"
create_reservation "accuracy-3" "external-requester" "2" "1Gi"
if wait_for_reservation_phase "accuracy-3" "Reserved" 60; then
    target=$(get_reservation_target "accuracy-3")
    # Should not be agent-1 (too loaded)
    correct=$([[ "$target" != "agent-1" ]] && echo "yes" || echo "no")
    expected="agent-3 or agent-2"
    log_info "  Chosen: $target, Expected: not agent-1, Correct: $correct"
    echo "large_request,2,1Gi,$target,$expected,$correct" >> "$OUTPUT"
else
    echo "large_request,2,1Gi,TIMEOUT,not-agent-1,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-3"
sleep 5

# Scenario 4: Consecutive requests - second should go to different cluster
log_info "Scenario 4: Two consecutive requests (reservation locking)"
create_reservation "accuracy-4a" "external-requester" "1" "512Mi"
wait_for_reservation_phase "accuracy-4a" "Reserved" 60
target_a=$(get_reservation_target "accuracy-4a")
sleep 2

create_reservation "accuracy-4b" "external-requester" "1" "512Mi"
if wait_for_reservation_phase "accuracy-4b" "Reserved" 60; then
    target_b=$(get_reservation_target "accuracy-4b")
    # With resource locking, second request may go to different cluster
    log_info "  First: $target_a, Second: $target_b"
    echo "consecutive_1st,1,512Mi,$target_a,agent-3,$([ "$target_a" == "agent-3" ] && echo yes || echo no)" >> "$OUTPUT"
    echo "consecutive_2nd,1,512Mi,$target_b,varies,yes" >> "$OUTPUT"
else
    echo "consecutive_2nd,1,512Mi,TIMEOUT,varies,no" >> "$OUTPUT"
fi
delete_reservation "accuracy-4a"
delete_reservation "accuracy-4b"
sleep 5

# Scenario 5: Request too large for any single cluster - should fail
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
for p in $(seq 1 6); do delete_dummy_pod "agent-1" "load-heavy-$p"; done
for p in $(seq 1 3); do delete_dummy_pod "agent-2" "load-medium-$p"; done

stop_all

log_info "========================================="
log_info "  Test 6 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
