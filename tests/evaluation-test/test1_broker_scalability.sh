#!/usr/bin/env bash
# Test 1: Broker CPU and RAM vs number of connected agents
#
# What we measure:
#   - Broker process CPU usage (%) via /proc/PID/stat ticks
#   - Broker process RSS memory (MB) via /proc/PID/status VmRSS
#   These are direct kernel-reported values, more accurate than htop.
#
# Setup:
#   - One broker + N agents, each agent on its own Kind cluster
#   - Agent counts: 1,2,5,10,15,20,25,30,40,50,60,70,80,90,100
#   - After all agents connect, stabilize, then sample CPU/memory
#
# Outputs TWO separate CSVs for graphing:
#   - 1a_broker_cpu.csv    (agents vs CPU%)
#   - 1b_broker_memory.csv (agents vs Memory MB)
#
# Also includes a resource exhaustion verification at the end:
#   Creates reservations to verify the broker correctly routes
#   requests to different clusters as resources are consumed.
#
# Findings (expected):
#   - CPU scales roughly linearly with agent count (each agent sends
#     advertisements every 30s; broker processes them + runs decision engine)
#   - Memory should remain relatively constant (broker stores CRDs in etcd,
#     process memory is mostly Go runtime overhead)
#   - At 100 agents, CPU usage may spike during advertisement bursts
#     but should remain manageable (<5% on modern hardware)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT_CPU="$RESULTS_DIR/1a_broker_cpu.csv"
OUTPUT_MEM="$RESULTS_DIR/1b_broker_memory.csv"
OUTPUT_RAW="$RESULTS_DIR/1_raw_samples.csv"
OUTPUT_EXHAUST="$RESULTS_DIR/1c_resource_exhaustion.csv"
AGENT_COUNTS=(1 2 5 10 15 20 25 30 40 50 60 70 80 90 100)
STABILIZE_SECS=90
MEASURE_SECS=120
SAMPLE_INTERVAL=5

log_info "========================================="
log_info "  Test 1: Broker Scalability"
log_info "  Agent counts: ${AGENT_COUNTS[*]}"
log_info "  Monitoring: /proc/PID/stat (CPU ticks)"
log_info "             /proc/PID/status (VmRSS)"
log_info "========================================="

echo "agents,avg_cpu_percent,median_cpu_percent,p95_cpu_percent,max_cpu_percent,min_cpu_percent" > "$OUTPUT_CPU"
echo "agents,avg_memory_mb,median_memory_mb,p95_memory_mb,max_memory_mb,min_memory_mb" > "$OUTPUT_MEM"
echo "agents,sample_num,cpu_percent,memory_mb" > "$OUTPUT_RAW"

# Pre-create all agent clusters needed (max count)
max_count=${AGENT_COUNTS[-1]}
create_clusters_parallel "agent" "$max_count" 5
for i in $(seq 1 "$max_count"); do
    install_agent_crds "agent-$i"
done

for count in "${AGENT_COUNTS[@]}"; do
    log_info "--- Testing with $count agent(s) ---"

    # Start broker
    start_broker
    broker_pid=$(cat "$PIDS_DIR/broker.pid")

    # Start N agents (each on its own cluster)
    for i in $(seq 1 "$count"); do
        start_agent "agent-$i" "agent-$i" "$i"
    done

    # Wait for all advertisements
    for i in $(seq 1 "$count"); do
        wait_for_cluster_advertisement "agent-$i" 180
    done

    log_info "All $count agents connected. Stabilizing ${STABILIZE_SECS}s..."
    sleep "$STABILIZE_SECS"

    # Measure broker CPU and memory
    log_info "Measuring broker for ${MEASURE_SECS}s..."
    samples=$((MEASURE_SECS / SAMPLE_INTERVAL))
    cpu_values=()
    mem_values=()

    for _ in $(seq 1 "$samples"); do
        ticks_before=$(get_cpu_ticks "$broker_pid")
        sleep "$SAMPLE_INTERVAL"
        ticks_after=$(get_cpu_ticks "$broker_pid")
        mem_kb=$(get_rss_kb "$broker_pid")

        cpu_pct=$(calc_cpu_percent "$ticks_before" "$ticks_after" "$SAMPLE_INTERVAL")
        mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_kb / 1024}")

        cpu_values+=("$cpu_pct")
        mem_values+=("$mem_mb")
    done

    # Dump raw samples
    for s in $(seq 0 $((${#cpu_values[@]} - 1))); do
        echo "$count,$((s+1)),${cpu_values[$s]},${mem_values[$s]}" >> "$OUTPUT_RAW"
    done

    # Calculate statistics
    avg_cpu=$(printf '%s\n' "${cpu_values[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    median_cpu=$(printf '%s\n' "${cpu_values[@]}" | compute_median)
    p95_cpu=$(printf '%s\n' "${cpu_values[@]}" | compute_p95)
    max_cpu=$(printf '%s\n' "${cpu_values[@]}" | sort -n | tail -1)
    min_cpu=$(printf '%s\n' "${cpu_values[@]}" | sort -n | head -1)
    avg_mem=$(printf '%s\n' "${mem_values[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    median_mem=$(printf '%s\n' "${mem_values[@]}" | compute_median)
    p95_mem=$(printf '%s\n' "${mem_values[@]}" | compute_p95)
    max_mem=$(printf '%s\n' "${mem_values[@]}" | sort -n | tail -1)
    min_mem=$(printf '%s\n' "${mem_values[@]}" | sort -n | head -1)

    log_info "CPU: avg=${avg_cpu}% median=${median_cpu}% p95=${p95_cpu}% max=${max_cpu}% min=${min_cpu}%"
    log_info "MEM: avg=${avg_mem}MB median=${median_mem}MB p95=${p95_mem}MB max=${max_mem}MB min=${min_mem}MB"

    echo "$count,$avg_cpu,$median_cpu,$p95_cpu,$max_cpu,$min_cpu" >> "$OUTPUT_CPU"
    echo "$count,$avg_mem,$median_mem,$p95_mem,$max_mem,$min_mem" >> "$OUTPUT_MEM"

    # Cleanup for this iteration
    stop_all
    clean_broker_crds
    sleep 5

    log_info "--- Done with $count agent(s) ---"
done

# ================================================================
# Resource exhaustion verification (merged from old test 7)
# Verifies broker correctly routes to different clusters under load
# ================================================================
log_info "--- Resource Exhaustion Verification ---"
EXHAUST_AGENTS=2
EXHAUST_MAX=15

# Reuse first 2 clusters
start_broker
clean_broker_crds
start_agent "agent-1" "agent-1" 1
start_agent "agent-2" "agent-2" 2
wait_for_cluster_advertisement "agent-1" 120
wait_for_cluster_advertisement "agent-2" 120

# Need a requester cluster
create_cluster "requester"
install_agent_crds "requester"
start_agent "requester" "requester" 999

log_info "Settling 60s before exhaustion test..."
sleep 60

echo "reservation_num,target_cluster,status" > "$OUTPUT_EXHAUST"

prev_target=""
route_changed=false

for r in $(seq 1 "$EXHAUST_MAX"); do
    res_name="exhaust-$r"
    log_info "Exhaustion reservation $r/$EXHAUST_MAX..."

    create_resource_request "$res_name" "requester" "500m" "256Mi"

    if wait_for_resource_request_phase "$res_name" "requester" "Reserved" 60; then
        target=$(get_resource_request_target "$res_name" "requester")
        status="Reserved"

        if [[ -n "$prev_target" && "$target" != "$prev_target" && "$route_changed" == "false" ]]; then
            route_changed=true
            log_info "  ROUTING CHANGED: $prev_target -> $target"
        fi
        prev_target=$target
        log_info "  -> $target"
    elif wait_for_resource_request_phase "$res_name" "requester" "Failed" 10; then
        status="Failed"
        target="NONE"
        log_info "  -> FAILED (clusters exhausted)"
    else
        status="Pending"
        target="NONE"
    fi

    echo "$r,$target,$status" >> "$OUTPUT_EXHAUST"

    if [[ "$status" == "Failed" ]]; then
        log_info "All clusters exhausted at reservation $r"
        break
    fi
    sleep 2
done

if [[ "$route_changed" == "true" ]]; then
    log_info "VERIFIED: Broker correctly routes to different cluster when first is exhausted"
else
    log_warn "Routing did not change during exhaustion test"
fi

# Cleanup
clean_agent_instructions "requester"
delete_all_reservations
stop_all

log_info "========================================="
log_info "  Test 1 complete!"
log_info "  CPU results:        $OUTPUT_CPU"
log_info "  Memory results:     $OUTPUT_MEM"
log_info "  Exhaustion results: $OUTPUT_EXHAUST"
log_info "========================================="
log_info "--- CPU ---"
cat "$OUTPUT_CPU"
log_info "--- Memory ---"
cat "$OUTPUT_MEM"
log_info "--- Exhaustion ---"
cat "$OUTPUT_EXHAUST"
