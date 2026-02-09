#!/usr/bin/env bash
# Test 5: Reservation time vs simultaneous requests
# Creates N reservations in parallel, measures how long each takes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/5_concurrent_reservations.csv"
CONCURRENCY_LEVELS=(1 2 4 6 8 10)
SETTLE_SECS=60
AGENT_COUNT=10  # Need enough provider clusters

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

echo "concurrent_requests,avg_resolve_ms,min_resolve_ms,max_resolve_ms" > "$OUTPUT"

for level in "${CONCURRENCY_LEVELS[@]}"; do
    log_info "--- Testing with $level concurrent request(s) ---"

    # Delete any previous reservations
    delete_all_reservations
    sleep 5

    # Create temp dir for per-request timing
    timing_dir=$(mktemp -d)

    # Launch N reservations in parallel
    t_start=$(now_ms)
    for r in $(seq 1 "$level"); do
        (
            res_name="concurrent-${level}-r${r}"
            requester="agent-$r"

            create_reservation "$res_name" "$requester" "200m" "128Mi" >/dev/null 2>&1
            ts_create=$(now_ms)

            if wait_for_reservation_phase "$res_name" "Reserved" 120; then
                ts_reserved=$(now_ms)
                duration=$((ts_reserved - ts_create))
                echo "$duration" > "$timing_dir/r${r}.ms"
            else
                echo "TIMEOUT" > "$timing_dir/r${r}.ms"
            fi
        ) &
    done
    wait

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
    echo "$level,$avg_ms,$min_ms,$max_ms" >> "$OUTPUT"

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
