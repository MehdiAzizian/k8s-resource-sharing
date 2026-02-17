#!/usr/bin/env bash
# Test 4: End-to-end reservation latency (synchronous flow)
#
# What we measure:
#   The full cycle from user creating a ResourceRequest to both agents
#   receiving their instructions. Shows a timeline of each phase:
#
#   t0: ResourceRequest created on requester cluster
#   t1: ResourceRequest reaches "Reserved" phase (broker decided + responded)
#   t2: ReservationInstruction appears on requester cluster (immediate, inline response)
#   t3: ProviderInstruction appears on provider cluster (via instruction polling, ~5s)
#
# Setup:
#   - 2 agents (agent-1 = requester, agent-2 = provider), each on own Kind cluster
#   - Agent instruction polling enabled (default 5s interval)
#   - ResourceRequest created on agent-1 cluster (NOT Reservation on broker)
#
# Outputs:
#   - 4_reservation_latency.csv: per-trial timestamps and durations
#   - Shows absolute timestamps for timeline/sequence diagram plotting
#
# Findings (expected):
#   - resolve_ms: <500ms (synchronous HTTP POST to broker + decision engine)
#   - requester_instruction_ms: <1s (created from inline HTTP response)
#   - provider_instruction_ms: <10s (instruction polling at 5s interval)
#   - Total E2E: <10s (vs ~53s with old polling architecture)
#
# The improvement: old polling waited up to 30s for each agent to poll.
# Now: requester is instant (inline response), provider polls every 5s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/4_reservation_latency.csv"
TRIALS=10
SETTLE_SECS=60

log_info "========================================="
log_info "  Test 4: Reservation Latency (Synchronous)"
log_info "  Trials: $TRIALS"
log_info "  Flow: ResourceRequest -> broker decision -> instructions"
log_info "========================================="

# Create 2 agent clusters: requester + provider
create_clusters_parallel "agent" 2
install_agent_crds "agent-1"
install_agent_crds "agent-2"

# Start broker + 2 agents
start_broker
clean_broker_crds
start_agent "agent-1" "agent-1" 1
start_agent "agent-2" "agent-2" 2
wait_for_cluster_advertisement "agent-1" 120
wait_for_cluster_advertisement "agent-2" 120

log_info "Both agents connected. Settling ${SETTLE_SECS}s..."
sleep "$SETTLE_SECS"

echo "trial,t0_create_ms,resolve_ms,requester_instruction_ms,provider_instruction_ms,total_e2e_ms" > "$OUTPUT"

for t in $(seq 1 "$TRIALS"); do
    log_info "Trial $t/$TRIALS..."
    res_name="latency-test-$t"

    # Clean previous instructions on both agent clusters
    clean_agent_instructions "agent-1"
    clean_agent_instructions "agent-2"
    sleep 2

    # t0: Create ResourceRequest on agent-1 (requester)
    t0=$(now_ms)
    create_resource_request "$res_name" "agent-1" "500m" "256Mi"

    # Wait for ResourceRequest to reach Reserved phase on agent-1
    resolve_ms="N/A"
    if wait_for_resource_request_phase "$res_name" "agent-1" "Reserved" 60; then
        t_reserved=$(now_ms)
        resolve_ms=$((t_reserved - t0))
    else
        log_warn "Trial $t: ResourceRequest did not reach Reserved phase"
        delete_resource_request "$res_name" "agent-1"
        echo "$t,$t0,N/A,N/A,N/A,N/A" >> "$OUTPUT"
        continue
    fi

    # Wait for requester instruction (ReservationInstruction on agent-1)
    requester_ms="N/A"
    if wait_for_reservation_instruction "agent-1" 30; then
        t_requester=$(now_ms)
        requester_ms=$((t_requester - t0))
    fi

    # Wait for provider instruction (ProviderInstruction on agent-2, via polling)
    provider_ms="N/A"
    if wait_for_provider_instruction "agent-2" 30; then
        t_provider=$(now_ms)
        provider_ms=$((t_provider - t0))
    fi

    # Total E2E = max of requester and provider delivery
    total_e2e="N/A"
    if [[ "$requester_ms" != "N/A" && "$provider_ms" != "N/A" ]]; then
        if [[ "$provider_ms" -gt "$requester_ms" ]]; then
            total_e2e=$provider_ms
        else
            total_e2e=$requester_ms
        fi
    elif [[ "$provider_ms" != "N/A" ]]; then
        total_e2e=$provider_ms
    elif [[ "$requester_ms" != "N/A" ]]; then
        total_e2e=$requester_ms
    fi

    log_info "Trial $t: resolve=${resolve_ms}ms requester=${requester_ms}ms provider=${provider_ms}ms e2e=${total_e2e}ms"
    echo "$t,$t0,$resolve_ms,$requester_ms,$provider_ms,$total_e2e" >> "$OUTPUT"

    # Cleanup
    delete_resource_request "$res_name" "agent-1"
    sleep 5
done

# Summary
avg_resolve=$(awk -F, 'NR>1 && $3!="N/A" {s+=$3; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")
avg_requester=$(awk -F, 'NR>1 && $4!="N/A" {s+=$4; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")
avg_provider=$(awk -F, 'NR>1 && $5!="N/A" {s+=$5; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")
avg_e2e=$(awk -F, 'NR>1 && $6!="N/A" {s+=$6; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")

log_info "Summary:"
log_info "  avg_resolve=${avg_resolve}ms (broker decision time)"
log_info "  avg_requester_instruction=${avg_requester}ms (inline response)"
log_info "  avg_provider_instruction=${avg_provider}ms (via 5s polling)"
log_info "  avg_e2e=${avg_e2e}ms (full cycle)"

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 4 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
