#!/usr/bin/env bash
# Test 2: Bandwidth of 1 agent toward the broker
# Uses iptables byte counters on loopback traffic to port 8443
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/2_agent_bandwidth.csv"
MEASURE_SECS=300  # 5 minutes
SAMPLE_INTERVAL=30  # Sample every 30s (matches agent publish interval)

log_info "========================================="
log_info "  Test 2: Agent Bandwidth"
log_info "  Duration: ${MEASURE_SECS}s"
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

# Set up iptables counters (loopback traffic to/from broker port)
sudo iptables -I OUTPUT -o lo -p tcp --dport "$BROKER_PORT" -m comment --comment "eval-agent-sent" -j ACCEPT
sudo iptables -I INPUT -i lo -p tcp --sport "$BROKER_PORT" -m comment --comment "eval-agent-recv" -j ACCEPT

# Zero the counters
sudo iptables -Z OUTPUT 1
sudo iptables -Z INPUT 1

echo "sample,elapsed_sec,bytes_sent,bytes_received,cumulative_sent,cumulative_recv" > "$OUTPUT"

samples=$((MEASURE_SECS / SAMPLE_INTERVAL))
log_info "Measuring bandwidth for ${MEASURE_SECS}s ($samples samples)..."

for s in $(seq 1 "$samples"); do
    sleep "$SAMPLE_INTERVAL"
    elapsed=$((s * SAMPLE_INTERVAL))

    # Read cumulative byte counters
    sent=$(sudo iptables -L OUTPUT -v -n -x 2>/dev/null | grep "eval-agent-sent" | awk '{print $2}')
    recv=$(sudo iptables -L INPUT -v -n -x 2>/dev/null | grep "eval-agent-recv" | awk '{print $2}')
    sent=${sent:-0}
    recv=${recv:-0}

    # Calculate interval bytes (diff from previous)
    if [[ $s -eq 1 ]]; then
        interval_sent=$sent
        interval_recv=$recv
    else
        interval_sent=$((sent - prev_sent))
        interval_recv=$((recv - prev_recv))
    fi
    prev_sent=$sent
    prev_recv=$recv

    log_info "Sample $s: sent=${interval_sent}B recv=${interval_recv}B (cumulative: sent=${sent}B recv=${recv}B)"
    echo "$s,$elapsed,$interval_sent,$interval_recv,$sent,$recv" >> "$OUTPUT"
done

# Remove iptables rules
sudo iptables -D OUTPUT -o lo -p tcp --dport "$BROKER_PORT" -m comment --comment "eval-agent-sent" -j ACCEPT 2>/dev/null || true
sudo iptables -D INPUT -i lo -p tcp --sport "$BROKER_PORT" -m comment --comment "eval-agent-recv" -j ACCEPT 2>/dev/null || true

# Summary
total_sent=$prev_sent
total_recv=$prev_recv
total_bytes=$((total_sent + total_recv))
bw_per_sec=$((total_bytes / MEASURE_SECS))

log_info "Summary: total_sent=${total_sent}B total_recv=${total_recv}B total=${total_bytes}B avg=${bw_per_sec}B/s"

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 2 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
