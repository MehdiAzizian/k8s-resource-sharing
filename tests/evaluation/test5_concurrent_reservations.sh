#!/usr/bin/env bash
# Test 5: Reservation time vs simultaneous requests
# Creates N reservations in parallel, measures how long each takes
# Each agent has its own real Kind cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/5_concurrent_reservations.csv"
CONCURRENCY_LEVELS=(1 2 4 6 8 10)
SETTLE_SECS=60
AGENT_COUNT=10  # Need enough provider clusters
RESERVATION_TIMEOUT=60  # seconds to wait for each reservation

log_info "========================================="
log_info "  Test 5: Concurrent Reservations"
log_info "  Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
log_info "========================================="

# Create agent clusters
create_clusters_parallel "agent" "$AGENT_COUNT"
for i in $(seq 1 "$AGENT_COUNT"); do
    install_agent_crds "agent-$i"
done

# Start broker + all agents
start_broker
for i in $(seq 1 "$AGENT_COUNT"); do
    start_agent "agent-$i" "agent-$i" "$i"
done
for i in $(seq 1 "$AGENT_COUNT"); do
    wait_for_cluster_advertisement "agent-$i" 120
done

log_info "All agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

# Verify broker state before starting tests
log_info "Verifying broker state..."
broker_kc="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"
kubectl --kubeconfig "$broker_kc" --request-timeout=10s \
    get clusteradvertisements -n default \
    -o custom-columns='CLUSTER:.spec.clusterID,ACTIVE:.status.active,CPU:.spec.resources.available.cpu' 2>/dev/null || true

# Quick sanity check: create and verify a single reservation
log_info "Sanity check: creating a test reservation..."
create_reservation "sanity-check" "agent-1" "100m" "64Mi"
if wait_for_reservation_phase "sanity-check" "Reserved" 30; then
    log_info "Sanity check PASSED: reservation reached Reserved phase"
elif wait_for_reservation_phase "sanity-check" "Failed" 10; then
    phase=$(kubectl --kubeconfig "$broker_kc" --request-timeout=10s \
        get reservation "sanity-check" -n default \
        -o jsonpath='{.status.message}' 2>/dev/null || true)
    log_error "Sanity check FAILED: reservation went to Failed phase: $phase"
    log_error "Check broker logs: $LOGS_DIR/broker.log"
    stop_all
    exit 1
else
    phase=$(kubectl --kubeconfig "$broker_kc" --request-timeout=10s \
        get reservation "sanity-check" -n default \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
    log_error "Sanity check FAILED: reservation stuck in phase '$phase'"
    log_error "Check broker logs: $LOGS_DIR/broker.log"
    stop_all
    exit 1
fi
delete_reservation "sanity-check"
sleep 5

echo "concurrent_requests,avg_resolve_ms,min_resolve_ms,max_resolve_ms,timeouts" > "$OUTPUT"

for level in "${CONCURRENCY_LEVELS[@]}"; do
    log_info "--- Testing with $level concurrent request(s) ---"

    # Delete any previous reservations
    delete_all_reservations
    sleep 5

    # Create temp dir for per-request timing
    timing_dir=$(mktemp -d)

    # Launch N reservations in parallel
    reservation_pids=()
    for r in $(seq 1 "$level"); do
        (
            res_name="concurrent-${level}-r${r}"
            requester="agent-$r"

            if ! create_reservation "$res_name" "$requester" "200m" "128Mi"; then
                log_warn "  [r$r] Failed to create reservation $res_name"
                echo "TIMEOUT" > "$timing_dir/r${r}.ms"
                exit 0
            fi
            ts_create=$(now_ms)

            if wait_for_reservation_phase "$res_name" "Reserved" "$RESERVATION_TIMEOUT"; then
                ts_reserved=$(now_ms)
                duration=$((ts_reserved - ts_create))
                log_info "  [r$r] Reserved in ${duration}ms"
                echo "$duration" > "$timing_dir/r${r}.ms"
            else
                log_warn "  [r$r] Timeout waiting for Reserved phase"
                echo "TIMEOUT" > "$timing_dir/r${r}.ms"
            fi
        ) &
        reservation_pids+=($!)
    done
    # Wait ONLY for reservation subshells (not broker/agent background processes)
    for pid in "${reservation_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    durations=()
    timeouts=0
    for r in $(seq 1 "$level"); do
        val=$(cat "$timing_dir/r${r}.ms" 2>/dev/null || echo "TIMEOUT")
        if [[ "$val" == "TIMEOUT" ]]; then
            ((timeouts++)) || true
        else
            durations+=("$val")
        fi
    done
    rm -rf "$timing_dir"

    if [[ ${#durations[@]} -gt 0 ]]; then
        avg_ms=$(printf '%s\n' "${durations[@]}" | awk '{s+=$1} END {printf "%.0f", s/NR}')
        min_ms=$(printf '%s\n' "${durations[@]}" | sort -n | head -1)
        max_ms=$(printf '%s\n' "${durations[@]}" | sort -n | tail -1)
    else
        avg_ms="N/A"
        min_ms="N/A"
        max_ms="N/A"
    fi

    log_info "Results: level=$level avg=${avg_ms}ms min=${min_ms}ms max=${max_ms}ms timeouts=$timeouts"
    echo "$level,$avg_ms,$min_ms,$max_ms,$timeouts" >> "$OUTPUT"

    # Cleanup reservations
    delete_all_reservations
    sleep 10
done

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 5 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
