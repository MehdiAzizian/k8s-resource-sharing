#!/usr/bin/env bash
# Test 7: Reservation under resource pressure
# Reserves resources from one cluster until full, verifies routing to another
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

# Create 3 agent clusters
create_clusters_parallel "agent" 3
for i in 1 2 3; do
    install_agent_crds "agent-$i"
done

# Start broker + agents
start_broker
for i in 1 2 3; do
    start_agent "agent-$i" "agent-$i" "$i"
done
for i in 1 2 3; do
    wait_for_cluster_advertisement "agent-$i" 120
done

log_info "All agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

# Show initial state
log_info "Initial cluster states:"
for i in 1 2 3; do
    cpu=$(get_broker_available_cpu "agent-$i")
    mem=$(get_broker_available_memory "agent-$i")
    log_info "  agent-$i: CPU=$cpu Memory=$mem"
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
for i in 1 2 3; do
    cpu=$(get_broker_available_cpu "agent-$i")
    mem=$(get_broker_available_memory "agent-$i")
    log_info "  agent-$i: CPU=$cpu Memory=$mem"
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
