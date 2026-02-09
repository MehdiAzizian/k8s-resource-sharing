#!/usr/bin/env bash
# Test 1: Broker CPU/RAM vs number of connected agents
# Creates agent clusters, starts agents, measures broker resource usage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/1_broker_scalability.csv"
AGENT_COUNTS=(1 2 5 10 15 20)
STABILIZE_SECS=90
MEASURE_SECS=120
SAMPLE_INTERVAL=5

log_info "========================================="
log_info "  Test 1: Broker Scalability"
log_info "  Agent counts: ${AGENT_COUNTS[*]}"
log_info "========================================="

echo "agents,avg_cpu_percent,max_cpu_percent,avg_memory_mb,max_memory_mb" > "$OUTPUT"

# Pre-create all clusters needed (max count)
max_count=${AGENT_COUNTS[-1]}
create_clusters_parallel "agent" "$max_count"
for i in $(seq 1 "$max_count"); do
    install_agent_crds "agent-$i"
done

for count in "${AGENT_COUNTS[@]}"; do
    log_info "--- Testing with $count agent(s) ---"

    # Start broker
    start_broker
    broker_pid=$(cat "$PIDS_DIR/broker.pid")

    # Start N agents
    for i in $(seq 1 "$count"); do
        start_agent "agent-$i" "agent-$i" "$i"
    done

    # Wait for all advertisements
    for i in $(seq 1 "$count"); do
        wait_for_cluster_advertisement "agent-$i" 120
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

    # Calculate averages and maximums
    avg_cpu=$(printf '%s\n' "${cpu_values[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    max_cpu=$(printf '%s\n' "${cpu_values[@]}" | sort -n | tail -1)
    avg_mem=$(printf '%s\n' "${mem_values[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    max_mem=$(printf '%s\n' "${mem_values[@]}" | sort -n | tail -1)

    log_info "Results: agents=$count avg_cpu=${avg_cpu}% max_cpu=${max_cpu}% avg_mem=${avg_mem}MB max_mem=${max_mem}MB"
    echo "$count,$avg_cpu,$max_cpu,$avg_mem,$max_mem" >> "$OUTPUT"

    # Cleanup for this iteration
    stop_all
    clean_broker_crds
    sleep 5

    log_info "--- Done with $count agent(s) ---"
done

log_info "========================================="
log_info "  Test 1 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
