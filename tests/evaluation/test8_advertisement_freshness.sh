#!/usr/bin/env bash
# Test 8: Advertisement freshness
# Measures delay between deploying a pod and broker seeing the resource change
# Agent has its own real k3d cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/8_advertisement_freshness.csv"
TRIALS=5
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 8: Advertisement Freshness"
log_info "  Trials: $TRIALS"
log_info "========================================="

# Create 1 agent cluster
create_cluster "agent-1"
install_agent_crds "agent-1"

# Start broker + 1 agent
start_broker
start_agent "agent-1" "agent-1" 1
wait_for_cluster_advertisement "agent-1" 120

log_info "Agent connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

echo "trial,pod_deploy_ms,broker_update_ms,delay_ms,cpu_before,cpu_after" > "$OUTPUT"

for t in $(seq 1 "$TRIALS"); do
    log_info "Trial $t/$TRIALS..."

    # Get current available CPU on broker
    cpu_before=$(get_broker_available_cpu "agent-1")
    log_info "  CPU before: $cpu_before"

    # Deploy a pod that consumes 500m CPU on the agent's cluster
    pod_name="freshness-$t"
    t_deploy=$(now_ms)
    deploy_dummy_pod "agent-1" "$pod_name" "500m" "256Mi"

    # Wait for pod to be running first
    if ! wait_for_pod_running "agent-1" "$pod_name" 60; then
        log_warn "  Pod did not start, skipping trial"
        delete_dummy_pod "agent-1" "$pod_name"
        continue
    fi

    # Poll broker's advertisement until CPU decreases
    timeout=120
    detected=false
    for _ in $(seq 1 "$timeout"); do
        cpu_after=$(get_broker_available_cpu "agent-1")
        # Compare: if cpu_after is different from cpu_before, the change propagated
        if [[ "$cpu_after" != "$cpu_before" && -n "$cpu_after" ]]; then
            t_detected=$(now_ms)
            delay=$((t_detected - t_deploy))
            detected=true
            log_info "  CPU after: $cpu_after (delay: ${delay}ms)"
            echo "$t,$t_deploy,$t_detected,$delay,$cpu_before,$cpu_after" >> "$OUTPUT"
            break
        fi
        sleep 0.5
    done

    if [[ "$detected" == "false" ]]; then
        log_warn "  Change not detected within timeout"
        echo "$t,$t_deploy,TIMEOUT,TIMEOUT,$cpu_before,$cpu_before" >> "$OUTPUT"
    fi

    # Cleanup: delete pod and wait for resources to free up
    delete_dummy_pod "agent-1" "$pod_name"
    log_info "  Waiting for resources to free up..."
    sleep 45  # Wait for next advertisement cycle
done

# Summary
avg_delay=$(awk -F, 'NR>1 && $4!="TIMEOUT" {s+=$4; n++} END {printf "%.0f", n>0?s/n:0}' "$OUTPUT")
log_info "Summary: avg_delay=${avg_delay}ms"

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 8 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
