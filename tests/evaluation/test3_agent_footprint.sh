#!/usr/bin/env bash
# Test 3: CPU and RAM used by 1 agent
# Samples agent process resource usage over time
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/3_agent_footprint.csv"
STABILIZE_SECS=60
MEASURE_SECS=120
SAMPLE_INTERVAL=5

log_info "========================================="
log_info "  Test 3: Agent Resource Footprint"
log_info "========================================="

# Create 1 agent cluster
create_cluster "agent-1"
install_agent_crds "agent-1"

# Start broker + 1 agent
start_broker
start_agent "agent-1" "agent-1" 1
wait_for_cluster_advertisement "agent-1" 120

agent_pid=$(cat "$PIDS_DIR/agent-1.pid")

log_info "Agent connected (PID: $agent_pid). Stabilizing ${STABILIZE_SECS}s..."
sleep "$STABILIZE_SECS"

echo "sample,elapsed_sec,cpu_percent,memory_mb" > "$OUTPUT"

samples=$((MEASURE_SECS / SAMPLE_INTERVAL))
log_info "Measuring agent for ${MEASURE_SECS}s..."

for s in $(seq 1 "$samples"); do
    ticks_before=$(get_cpu_ticks "$agent_pid")
    sleep "$SAMPLE_INTERVAL"
    ticks_after=$(get_cpu_ticks "$agent_pid")
    mem_kb=$(get_rss_kb "$agent_pid")

    cpu_pct=$(calc_cpu_percent "$ticks_before" "$ticks_after" "$SAMPLE_INTERVAL")
    mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_kb / 1024}")
    elapsed=$((s * SAMPLE_INTERVAL))

    echo "$s,$elapsed,$cpu_pct,$mem_mb" >> "$OUTPUT"
done

# Calculate summary
avg_cpu=$(awk -F, 'NR>1 {s+=$3; n++} END {printf "%.2f", s/n}' "$OUTPUT")
avg_mem=$(awk -F, 'NR>1 {s+=$4; n++} END {printf "%.2f", s/n}' "$OUTPUT")
max_cpu=$(awk -F, 'NR>1 {if($3>m) m=$3} END {printf "%.2f", m}' "$OUTPUT")
max_mem=$(awk -F, 'NR>1 {if($4>m) m=$4} END {printf "%.2f", m}' "$OUTPUT")

log_info "Summary: avg_cpu=${avg_cpu}% max_cpu=${max_cpu}% avg_mem=${avg_mem}MB max_mem=${max_mem}MB"

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 3 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
