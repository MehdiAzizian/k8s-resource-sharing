#!/usr/bin/env bash
# Test 5: Reservation latency vs simultaneous requests
#
# What we measure:
#   - How reservation latency scales with concurrent requests
#   - Each concurrency level is tested 5 times for statistical significance
#   - Reports: median, variance, P95 (not average, which is misleading with outliers)
#
# Setup:
#   - 10 agents (each on own Kind cluster), 1 used as requester
#   - Concurrency levels: 1, 2, 4, 6, 8, 10
#   - Each request creates a ResourceRequest on the requester cluster
#
# Findings (expected):
#   - At low concurrency (1-2): median ~200-500ms (synchronous decision)
#   - At high concurrency (10): median may increase due to broker serialization
#   - Variance should be low at low concurrency, higher at high concurrency
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/5_concurrent_reservations.csv"
CONCURRENCY_LEVELS=(1 2 4 6 8 10)
SETTLE_SECS=60
AGENT_COUNT=10
REPETITIONS=5
RESERVATION_TIMEOUT=60

log_info "========================================="
log_info "  Test 5: Concurrent Reservations"
log_info "  Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
log_info "  Repetitions per level: $REPETITIONS"
log_info "  Statistics: median, variance, P95"
log_info "========================================="

# Create agent clusters (providers) + 1 requester cluster
create_clusters_parallel "agent" "$AGENT_COUNT"
for i in $(seq 1 "$AGENT_COUNT"); do
    install_agent_crds "agent-$i"
done
create_cluster "requester"
install_agent_crds "requester"

# Start broker + all agents + requester
start_broker
clean_broker_crds
for i in $(seq 1 "$AGENT_COUNT"); do
    start_agent "agent-$i" "agent-$i" "$i"
done
start_agent "requester" "requester" 999
for i in $(seq 1 "$AGENT_COUNT"); do
    wait_for_cluster_advertisement "agent-$i" 120
done

log_info "All agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

echo "concurrent_requests,repetition,median_resolve_ms,variance_ms,p95_resolve_ms,timeouts" > "$OUTPUT"

for level in "${CONCURRENCY_LEVELS[@]}"; do
    log_info "--- Testing with $level concurrent request(s) ---"

    for rep in $(seq 1 "$REPETITIONS"); do
        log_info "  Repetition $rep/$REPETITIONS..."

        # Clean up from previous round
        clean_agent_instructions "requester"
        delete_all_reservations
        sleep 5

        timing_dir=$(mktemp -d)

        # Launch N reservations in parallel (all from requester cluster)
        reservation_pids=()
        for r in $(seq 1 "$level"); do
            (
                res_name="concurrent-${level}-rep${rep}-r${r}"

                ts_create=$(now_ms)
                create_resource_request "$res_name" "requester" "200m" "128Mi"

                if wait_for_resource_request_phase "$res_name" "requester" "Reserved" "$RESERVATION_TIMEOUT"; then
                    ts_reserved=$(now_ms)
                    duration=$((ts_reserved - ts_create))
                    echo "$duration" > "$timing_dir/r${r}.ms"
                else
                    echo "TIMEOUT" > "$timing_dir/r${r}.ms"
                fi
            ) &
            reservation_pids+=($!)
        done

        # Wait for all reservation subshells
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
            median_ms=$(printf '%s\n' "${durations[@]}" | compute_median)
            variance_ms=$(printf '%s\n' "${durations[@]}" | compute_variance)
            p95_ms=$(printf '%s\n' "${durations[@]}" | compute_p95)
        else
            median_ms="N/A"
            variance_ms="N/A"
            p95_ms="N/A"
        fi

        log_info "  Rep $rep: median=${median_ms}ms variance=${variance_ms} p95=${p95_ms}ms timeouts=$timeouts"
        echo "$level,$rep,$median_ms,$variance_ms,$p95_ms,$timeouts" >> "$OUTPUT"

        # Cleanup
        clean_agent_instructions "requester"
        delete_all_reservations
        sleep 5
    done
done

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 5 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
