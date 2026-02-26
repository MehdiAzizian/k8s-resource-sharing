#!/usr/bin/env bash
# Test 6: Decision accuracy
#
# What we measure:
#   - Whether the broker's decision engine correctly selects the cluster
#     with the most available resources
#   - Uses 3 provider agents with different load profiles + 1 requester
#
# Setup:
#   - agent-1: HEAVY load (6 dummy pods consuming CPU/memory)
#   - agent-2: MEDIUM load (3 dummy pods)
#   - agent-3: LIGHT load (no extra pods, most available resources)
#   - requester: sends ResourceRequests to test decision accuracy
#
# Findings (expected):
#   - Small/medium requests should route to agent-3 (lightest load)
#   - Large requests should avoid agent-1 (heaviest load)
#   - Consecutive requests may route to different clusters due to resource locking
#   - Impossible requests should be rejected (Failed phase)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/6_decision_accuracy.csv"
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 6: Decision Accuracy"
log_info "========================================="

# Create 3 provider clusters + 1 requester cluster
create_clusters_parallel "agent" 3
install_agent_crds "agent-1"
install_agent_crds "agent-2"
install_agent_crds "agent-3"
create_cluster "requester"
install_agent_crds "requester"

# Start broker + 3 providers + requester
start_broker
clean_broker_crds
start_agent "agent-1" "agent-1" 1
start_agent "agent-2" "agent-2" 2
start_agent "agent-3" "agent-3" 3
start_agent "requester" "requester" 999
wait_for_cluster_advertisement "agent-1" 120
wait_for_cluster_advertisement "agent-2" 120
wait_for_cluster_advertisement "agent-3" 120

log_info "All agents connected. Creating different load profiles..."

# Deploy heavy load on agent-1 (least available resources)
for p in $(seq 1 6); do
    deploy_dummy_pod "agent-1" "load-heavy-$p" "500m" "256Mi"
done

# Deploy medium load on agent-2
for p in $(seq 1 3); do
    deploy_dummy_pod "agent-2" "load-medium-$p" "500m" "256Mi"
done

# agent-3 has no extra load -> most available resources

log_info "Load deployed. Settling ${SETTLE_SECS}s for advertisements to update..."
sleep "$SETTLE_SECS"

# Show current state
log_info "Current cluster states on broker:"
kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
    get clusteradvertisements -n default \
    -o custom-columns='CLUSTER:.spec.clusterID,AVAIL-CPU:.spec.resources.available.cpu,AVAIL-MEM:.spec.resources.available.memory' 2>/dev/null || true

echo "scenario,requested_cpu,requested_mem,chosen_cluster,expected_cluster,pass_rate" > "$OUTPUT"

pass_count=0
total_count=0

# Scenario 1: Small request -> should go to agent-3 (most available)
log_info "Scenario 1: Small request (200m CPU, 128Mi)"
create_resource_request "accuracy-1" "requester" "200m" "128Mi"
if wait_for_resource_request_phase "accuracy-1" "requester" "Reserved" 60; then
    target=$(get_resource_request_target "accuracy-1" "requester")
    expected="agent-3"
    if [[ "$target" == "$expected" ]]; then ((pass_count++)) || true; fi
    ((total_count++)) || true
    log_info "  Chosen: $target, Expected: $expected"
    echo "small_request,200m,128Mi,$target,$expected," >> "$OUTPUT"
else
    ((total_count++)) || true
    echo "small_request,200m,128Mi,TIMEOUT,agent-3," >> "$OUTPUT"
fi
delete_resource_request "accuracy-1" "requester"
clean_agent_instructions "requester"
sleep 5

# Scenario 2: Medium request -> should still prefer lighter cluster
log_info "Scenario 2: Medium request (1 CPU, 512Mi)"
create_resource_request "accuracy-2" "requester" "1" "512Mi"
if wait_for_resource_request_phase "accuracy-2" "requester" "Reserved" 60; then
    target=$(get_resource_request_target "accuracy-2" "requester")
    expected="agent-3"
    if [[ "$target" == "$expected" ]]; then ((pass_count++)) || true; fi
    ((total_count++)) || true
    log_info "  Chosen: $target, Expected: $expected"
    echo "medium_request,1,512Mi,$target,$expected," >> "$OUTPUT"
else
    ((total_count++)) || true
    echo "medium_request,1,512Mi,TIMEOUT,agent-3," >> "$OUTPUT"
fi
delete_resource_request "accuracy-2" "requester"
clean_agent_instructions "requester"
sleep 5

# Scenario 3: Large request -> should not go to agent-1 (too loaded)
log_info "Scenario 3: Large request (2 CPU, 1Gi)"
create_resource_request "accuracy-3" "requester" "2" "1Gi"
if wait_for_resource_request_phase "accuracy-3" "requester" "Reserved" 60; then
    target=$(get_resource_request_target "accuracy-3" "requester")
    if [[ "$target" != "agent-1" ]]; then ((pass_count++)) || true; fi
    ((total_count++)) || true
    log_info "  Chosen: $target, Expected: not agent-1"
    echo "large_request,2,1Gi,$target,not-agent-1," >> "$OUTPUT"
else
    ((total_count++)) || true
    echo "large_request,2,1Gi,TIMEOUT,not-agent-1," >> "$OUTPUT"
fi
delete_resource_request "accuracy-3" "requester"
clean_agent_instructions "requester"
sleep 5

# Scenario 4: Consecutive requests -> second may go to different cluster
log_info "Scenario 4: Two consecutive requests (resource locking)"
create_resource_request "accuracy-4a" "requester" "1" "512Mi"
wait_for_resource_request_phase "accuracy-4a" "requester" "Reserved" 60
target_a=$(get_resource_request_target "accuracy-4a" "requester")
sleep 2

create_resource_request "accuracy-4b" "requester" "1" "512Mi"
if wait_for_resource_request_phase "accuracy-4b" "requester" "Reserved" 60; then
    target_b=$(get_resource_request_target "accuracy-4b" "requester")
    log_info "  First: $target_a, Second: $target_b"
    # Both should succeed - that's the test
    ((pass_count++)) || true
    ((total_count++)) || true
    echo "consecutive,1,512Mi,$target_a then $target_b,both succeed," >> "$OUTPUT"
else
    ((total_count++)) || true
    echo "consecutive,1,512Mi,$target_a then TIMEOUT,both succeed," >> "$OUTPUT"
fi
delete_resource_request "accuracy-4a" "requester"
delete_resource_request "accuracy-4b" "requester"
clean_agent_instructions "requester"
sleep 5

# Scenario 5: Request too large for any cluster -> should fail
log_info "Scenario 5: Impossibly large request (100 CPU, 500Gi)"
create_resource_request "accuracy-5" "requester" "100" "500Gi"
if wait_for_resource_request_phase "accuracy-5" "requester" "Failed" 30; then
    log_info "  Correctly rejected: too large for any cluster"
    ((pass_count++)) || true
    ((total_count++)) || true
    echo "impossible_request,100,500Gi,REJECTED,REJECTED," >> "$OUTPUT"
else
    ((total_count++)) || true
    echo "impossible_request,100,500Gi,UNEXPECTED,REJECTED," >> "$OUTPUT"
fi
delete_resource_request "accuracy-5" "requester"

# Write pass rate
log_info "Decision accuracy: $pass_count/$total_count scenarios passed"
# Update pass_rate column in CSV
sed -i "s/,$/,$pass_count\/$total_count/" "$OUTPUT"

# Cleanup dummy pods
for p in $(seq 1 6); do delete_dummy_pod "agent-1" "load-heavy-$p"; done
for p in $(seq 1 3); do delete_dummy_pod "agent-2" "load-medium-$p"; done

clean_agent_instructions "requester"
stop_all

log_info "========================================="
log_info "  Test 6 complete! Results: $OUTPUT"
log_info "  Pass rate: $pass_count/$total_count"
log_info "========================================="
cat "$OUTPUT"
