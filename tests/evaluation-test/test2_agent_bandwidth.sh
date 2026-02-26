#!/usr/bin/env bash
# Test 2: Agent send bandwidth toward the broker
#
# What we measure:
#   - Bytes SENT by one agent to the broker per advertisement cycle
#   - Uses iptables byte counters on loopback traffic to broker port
#
# Why only send rate:
#   - The agent sends POST /api/v1/advertisements every 30s (configurable)
#   - The response from broker is small (ACK + optional piggybacked instructions)
#   - The interesting metric is the advertisement payload size per cycle
#
# The advertisement interval (--advertisement-requeue-interval) is configurable.
# Default is 30s. Bandwidth scales linearly: at 10s interval, expect ~3x bandwidth.
#
# Findings (expected):
#   - Each advertisement cycle sends ~2-5 KB (resource metrics + mTLS overhead)
#   - At 30s interval: ~70-170 B/s average send rate
#   - The send data size is constant regardless of cluster size
#     (it only contains this cluster's resource snapshot)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/2_agent_bandwidth.csv"
MEASURE_SECS=300  # 5 minutes
SAMPLE_INTERVAL=30  # Matches default agent publish interval

log_info "========================================="
log_info "  Test 2: Agent Send Bandwidth"
log_info "  Duration: ${MEASURE_SECS}s"
log_info "  Advertisement interval: 30s (configurable via --advertisement-requeue-interval)"
log_info "========================================="

# Check sudo access for iptables
if ! sudo -n true 2>/dev/null; then
    log_error "This test requires passwordless sudo for iptables"
    log_error "Run: sudo visudo and add: $USER ALL=(ALL) NOPASSWD: ALL"
    exit 1
fi

# Create 1 agent cluster
create_cluster "agent-1"
install_agent_crds "agent-1"

# Start broker + 1 agent
start_broker
start_agent "agent-1" "agent-1" 1
wait_for_cluster_advertisement "agent-1" 120

log_info "Agent connected. Setting up bandwidth measurement..."

# Set up iptables counter for SENT traffic only
sudo iptables -I OUTPUT -o lo -p tcp --dport "$BROKER_PORT" -m comment --comment "eval-agent-sent" -j ACCEPT

# Zero the counter
sudo iptables -Z OUTPUT 1

echo "sample,elapsed_sec,bytes_sent_interval,bytes_sent_cumulative,bytes_per_cycle" > "$OUTPUT"

samples=$((MEASURE_SECS / SAMPLE_INTERVAL))
log_info "Measuring send bandwidth for ${MEASURE_SECS}s ($samples samples)..."
prev_sent=0

for s in $(seq 1 "$samples"); do
    sleep "$SAMPLE_INTERVAL"
    elapsed=$((s * SAMPLE_INTERVAL))

    # Read cumulative byte counter
    sent=$(sudo iptables -L OUTPUT -v -n -x 2>/dev/null | grep "eval-agent-sent" | awk '{print $2}')
    sent=${sent:-0}

    # Calculate interval bytes
    interval_sent=$((sent - prev_sent))
    prev_sent=$sent

    # bytes_per_cycle = interval_sent (since interval = advertisement cycle = 30s)
    log_info "Sample $s: sent=${interval_sent}B (cumulative: ${sent}B, per cycle: ${interval_sent}B)"
    echo "$s,$elapsed,$interval_sent,$sent,$interval_sent" >> "$OUTPUT"
done

# Remove iptables rule
sudo iptables -D OUTPUT -o lo -p tcp --dport "$BROKER_PORT" -m comment --comment "eval-agent-sent" -j ACCEPT 2>/dev/null || true

# Summary
total_sent=$prev_sent
bw_per_sec=$((total_sent / MEASURE_SECS))

log_info "Summary: total_sent=${total_sent}B avg=${bw_per_sec}B/s"
log_info "Note: Advertisement interval is 30s. At 10s interval, expect ~3x bandwidth."

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 2 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
