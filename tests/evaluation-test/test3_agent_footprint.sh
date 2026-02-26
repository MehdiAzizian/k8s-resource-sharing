#!/usr/bin/env bash
# Test 3: CPU and RAM used by 1 agent
#
# What we measure:
#   - Agent process CPU usage (%) via /proc/PID/stat
#   - Agent process RSS memory (MB) via /proc/PID/status VmRSS
#   - Extended to 5 minutes to observe whether CPU spikes are caused by
#     Go garbage collection (GC) or other periodic behavior
#
# Optional: Set ENABLE_GC_TRACE=1 to start the agent with GODEBUG=gctrace=1
#   This writes GC timing info to the agent log, allowing you to correlate
#   CPU spikes with garbage collection pauses.
#
# Findings (expected):
#   - Average CPU: ~0.2-0.5% (mostly idle, wakes every 30s for advertisement)
#   - Memory: ~40-50 MB RSS (Go runtime + controller-runtime + k8s client cache)
#   - CPU spikes every ~30s correspond to advertisement publish cycle
#   - Smaller spikes between cycles are likely Go GC (verify with gctrace)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/3_agent_footprint.csv"
STABILIZE_SECS=60
MEASURE_SECS=300   # 5 minutes (extended from 2 min to investigate spikes)
SAMPLE_INTERVAL=5
ENABLE_GC_TRACE=${ENABLE_GC_TRACE:-0}

log_info "========================================="
log_info "  Test 3: Agent Resource Footprint"
log_info "  Duration: ${MEASURE_SECS}s (${SAMPLE_INTERVAL}s samples)"
log_info "  GC trace: $([ "$ENABLE_GC_TRACE" = "1" ] && echo "ENABLED" || echo "disabled (set ENABLE_GC_TRACE=1 to enable)")"
log_info "========================================="

# Create 1 agent cluster
create_cluster "agent-1"
install_agent_crds "agent-1"

# Start broker
start_broker
clean_broker_crds

# Start agent (optionally with GC tracing)
if [[ "$ENABLE_GC_TRACE" == "1" ]]; then
    log_info "Starting agent with GODEBUG=gctrace=1 (GC events logged to agent log)"
    GODEBUG=gctrace=1 KUBECONFIG="$KUBECONFIGS_DIR/agent-1.kubeconfig" \
        "$AGENT_DIR/bin/agent" \
        --broker-transport=http \
        --broker-url="https://localhost:$BROKER_PORT" \
        --broker-cert-path="$CERTS_DIR/agent-1" \
        --cluster-id="agent-1" \
        --health-probe-bind-address=":9001" \
        --metrics-bind-address=0 \
        --metrics-secure=false \
        --advertisement-requeue-interval=30s \
        > "$LOGS_DIR/agent-1.log" 2>&1 &
    echo "$!" > "$PIDS_DIR/agent-1.pid"
    log_info "Agent 'agent-1' started with GC trace (PID: $!)"
else
    start_agent "agent-1" "agent-1" 1
fi

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
min_cpu=$(awk -F, 'NR>1 {if(NR==2 || $3<m) m=$3} END {printf "%.2f", m}' "$OUTPUT")

log_info "Summary: avg_cpu=${avg_cpu}% max_cpu=${max_cpu}% min_cpu=${min_cpu}% avg_mem=${avg_mem}MB max_mem=${max_mem}MB"

if [[ "$ENABLE_GC_TRACE" == "1" ]]; then
    gc_count=$(grep -c "^gc " "$LOGS_DIR/agent-1.log" 2>/dev/null || echo 0)
    log_info "GC events during measurement: $gc_count (check $LOGS_DIR/agent-1.log for details)"
fi

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 3 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
