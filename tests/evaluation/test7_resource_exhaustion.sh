#!/usr/bin/env bash
# Test 7: Reservation under resource pressure
# Reserves resources until one cluster is full, verifies routing to the other
# - agent-1 on "agents" cluster
# - agent-2 on "broker" cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/7_resource_exhaustion.csv"
SETTLE_SECS=60
MAX_RESERVATIONS=15

log_info "========================================="
log_info "  Test 7: Resource Exhaustion"
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

log_info "Both agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

# Show initial state
log_info "Initial cluster states:"
for agent in "agent-1" "agent-2"; do
    cpu=$(get_broker_available_cpu "$agent")
    mem=$(get_broker_available_memory "$agent")
    log_info "  $agent: CPU=$cpu Memory=$mem"
done

echo "reservation_num,target_cluster,status,available_cpu_after,available_mem_after" > "$OUTPUT"

prev_target=""
route_changed=false

for r in $(seq 1 "$MAX_RESERVATIONS"); do
    res_name="exhaust-$r"
    log_info "Reservation $r/$MAX_RESERVATIONS..."

    create_reservation "$res_name" "external-requester" "500m" "256Mi"

    if wait_for_reservation_phase "$res_name" "Reserved" 60; then
        target=$(get_reservation_target "$res_name")
        status="Reserved"

        # Wait for advertisement to update (polling interval)
        sleep 5

        avail_cpu=$(get_broker_available_cpu "$target")
        avail_mem=$(get_broker_available_memory "$target")

        # Check if routing changed (went to a different cluster)
        if [[ -n "$prev_target" && "$target" != "$prev_target" && "$route_changed" == "false" ]]; then
            route_changed=true
            log_info "  ROUTING CHANGED: $prev_target -> $target (previous cluster exhausted)"
        fi
        prev_target=$target

        log_info "  -> $target (CPU left: $avail_cpu, Mem left: $avail_mem)"
    elif wait_for_reservation_phase "$res_name" "Failed" 10; then
        status="Failed"
        target="NONE"
        avail_cpu="N/A"
        avail_mem="N/A"
        log_info "  -> FAILED (all clusters exhausted)"
    else
        status="Pending"
        target="NONE"
        avail_cpu="N/A"
        avail_mem="N/A"
        log_info "  -> PENDING (still waiting)"
    fi

    echo "$r,$target,$status,$avail_cpu,$avail_mem" >> "$OUTPUT"

    # If all clusters exhausted, stop
    if [[ "$status" == "Failed" ]]; then
        log_info "All clusters exhausted at reservation $r"
        break
    fi

    sleep 2
done

# Show final state
log_info "Final cluster states:"
for agent in "agent-1" "agent-2"; do
    cpu=$(get_broker_available_cpu "$agent")
    mem=$(get_broker_available_memory "$agent")
    log_info "  $agent: CPU=$cpu Memory=$mem"
done

if [[ "$route_changed" == "true" ]]; then
    log_info "SUCCESS: System correctly routed to another cluster when first was exhausted"
else
    log_warn "Routing did not change (all reservations went to same cluster or never filled)"
fi

# Cleanup
delete_all_reservations
stop_all

log_info "========================================="
log_info "  Test 7 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
