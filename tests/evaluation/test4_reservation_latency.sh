#!/usr/bin/env bash
# Test 4: End-to-end reservation time
# Measures: creation -> Reserved phase -> instruction delivery to agents
# Both agents run on the shared "agents" cluster in separate namespaces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/4_reservation_latency.csv"
TRIALS=10
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 4: Reservation Latency"
log_info "  Trials: $TRIALS"
log_info "========================================="

# Create namespaces for 2 agents on the shared cluster
create_agent_namespace "$SHARED_CLUSTER" "ns-agent-1"
create_agent_namespace "$SHARED_CLUSTER" "ns-agent-2"

# Start broker + 2 agents on shared cluster
start_broker
start_agent "agent-1" "$SHARED_CLUSTER" 1 "ns-agent-1"
start_agent "agent-2" "$SHARED_CLUSTER" 2 "ns-agent-2"
wait_for_cluster_advertisement "agent-1" 120
wait_for_cluster_advertisement "agent-2" 120

log_info "Both agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

echo "trial,resolve_ms,provider_instruction_ms,requester_instruction_ms,total_e2e_ms" > "$OUTPUT"

for t in $(seq 1 "$TRIALS"); do
    log_info "Trial $t/$TRIALS..."
    res_name="latency-test-$t"

    # Clean previous instructions on agent namespaces
    kubeconfig="$KUBECONFIGS_DIR/${SHARED_CLUSTER}.kubeconfig"
    kubectl --kubeconfig "$kubeconfig" \
        delete providerinstructions --all -n ns-agent-1 --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" \
        delete reservationinstructions --all -n ns-agent-1 --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" \
        delete providerinstructions --all -n ns-agent-2 --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" \
        delete reservationinstructions --all -n ns-agent-2 --ignore-not-found 2>/dev/null

    # Timestamp: create reservation
    t_start=$(now_ms)
    create_reservation "$res_name" "agent-1" "500m" "256Mi"

    # Wait for Reserved phase
    if wait_for_reservation_phase "$res_name" "Reserved" 60; then
        t_reserved=$(now_ms)
    else
        log_warn "Trial $t: reservation did not reach Reserved phase"
        delete_reservation "$res_name"
        continue
    fi

    resolve_ms=$((t_reserved - t_start))

    # Wait for provider instruction (check both agent namespaces)
    provider_ms="N/A"
    requester_ms="N/A"

    for ns in "ns-agent-1" "ns-agent-2"; do
        if wait_for_provider_instruction "$SHARED_CLUSTER" "$ns" 90; then
            t_provider=$(now_ms)
            provider_ms=$((t_provider - t_start))
        fi
        if wait_for_reservation_instruction "$SHARED_CLUSTER" "$ns" 90; then
            t_requester=$(now_ms)
            requester_ms=$((t_requester - t_start))
        fi
    done

    # Total E2E = max of provider and requester delivery
    if [[ "$provider_ms" != "N/A" && "$requester_ms" != "N/A" ]]; then
        if [[ "$provider_ms" -gt "$requester_ms" ]]; then
            total_e2e=$provider_ms
        else
            total_e2e=$requester_ms
        fi
    elif [[ "$provider_ms" != "N/A" ]]; then
        total_e2e=$provider_ms
    elif [[ "$requester_ms" != "N/A" ]]; then
        total_e2e=$requester_ms
    else
        total_e2e="N/A"
    fi

    log_info "Trial $t: resolve=${resolve_ms}ms provider=${provider_ms}ms requester=${requester_ms}ms e2e=${total_e2e}ms"
    echo "$t,$resolve_ms,$provider_ms,$requester_ms,$total_e2e" >> "$OUTPUT"

    # Cleanup reservation
    delete_reservation "$res_name"
    sleep 5
done

# Summary
avg_resolve=$(awk -F, 'NR>1 && $2!="N/A" {s+=$2; n++} END {printf "%.0f", n>0?s/n:0}' "$OUTPUT")
avg_e2e=$(awk -F, 'NR>1 && $5!="N/A" {s+=$5; n++} END {printf "%.0f", n>0?s/n:0}' "$OUTPUT")
log_info "Summary: avg_resolve=${avg_resolve}ms avg_e2e=${avg_e2e}ms"

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 4 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
