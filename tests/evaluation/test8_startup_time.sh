#!/usr/bin/env bash
# Test 8: Agent startup time breakdown
#
# What we measure:
#   The time from starting the agent to having its first advertisement
#   visible on the broker, broken down into phases:
#
#   Phase 1: Certificate generation (cert-manager / openssl) - NOT our component
#   Phase 2: Agent binary startup + controller initialization - our component
#   Phase 3: First metrics collection + advertisement POST - our component
#   Phase 4: Broker receives and stores advertisement - our component
#
# Purpose:
#   Show that our system (agent) starts quickly. Most of the total startup
#   time is due to external components (certificate issuance, Kubernetes API
#   server warmup). Our agent's contribution is minimal.
#
# Setup:
#   - Same Kind cluster setup as other tests
#   - Measures each phase separately using timestamps
#   - Runs multiple trials for consistency
#
# Findings (expected):
#   - Certificate generation: 1-3s (openssl in test, cert-manager in prod: 5-30s)
#   - Agent startup to ready: <2s (Go binary + controller-runtime init)
#   - First advertisement published: <3s after agent starts (first reconcile)
#   - Broker receives advertisement: <1s after publish (HTTP round-trip)
#   - Total: ~5-8s, of which agent's own contribution is ~3-5s
#   - In production with cert-manager: total may be 30-60s, but agent portion stays ~3-5s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

OUTPUT="$RESULTS_DIR/8_startup_time.csv"
TRIALS=5

log_info "========================================="
log_info "  Test 8: Agent Startup Time Breakdown"
log_info "  Trials: $TRIALS"
log_info "========================================="

# Create 1 agent cluster
create_cluster "agent-1"
install_agent_crds "agent-1"

# Start broker (stays running across trials)
start_broker

echo "trial,cert_gen_ms,agent_startup_ms,first_adv_ms,broker_receive_ms,total_ms,agent_portion_ms,external_portion_ms" > "$OUTPUT"

for t in $(seq 1 "$TRIALS"); do
    log_info "Trial $t/$TRIALS..."

    # Clean previous state
    clean_broker_crds
    stop_process "agent-1"
    # Remove old cert to re-measure generation
    rm -rf "$CERTS_DIR/agent-1"
    sleep 2

    # Phase 1: Certificate generation
    t_cert_start=$(now_ms)
    generate_agent_cert "agent-1"
    t_cert_done=$(now_ms)
    cert_gen_ms=$((t_cert_done - t_cert_start))

    # Phase 2: Agent binary startup
    t_agent_start=$(now_ms)
    health_port=$((AGENT_HEALTH_PORT_BASE + 1))
    KUBECONFIG="$KUBECONFIGS_DIR/agent-1.kubeconfig" \
        "$AGENT_DIR/bin/agent" \
        --broker-transport=http \
        --broker-url="https://localhost:$BROKER_PORT" \
        --broker-cert-path="$CERTS_DIR/agent-1" \
        --cluster-id="agent-1" \
        --health-probe-bind-address=":$health_port" \
        --metrics-bind-address=0 \
        --metrics-secure=false \
        --advertisement-requeue-interval=30s \
        > "$LOGS_DIR/agent-1.log" 2>&1 &
    echo "$!" > "$PIDS_DIR/agent-1.pid"

    # Wait for agent health endpoint (signals controller-runtime is ready)
    agent_ready=false
    for _ in $(seq 1 60); do
        if curl -s "http://localhost:$health_port/healthz" >/dev/null 2>&1; then
            agent_ready=true
            break
        fi
        sleep 0.2
    done
    t_agent_ready=$(now_ms)
    agent_startup_ms=$((t_agent_ready - t_agent_start))

    if [[ "$agent_ready" != "true" ]]; then
        log_warn "Trial $t: Agent health check timed out"
        echo "$t,$cert_gen_ms,TIMEOUT,N/A,N/A,N/A,N/A,N/A" >> "$OUTPUT"
        continue
    fi

    # Phase 3+4: Wait for first advertisement to appear on broker
    t_adv_wait_start=$(now_ms)
    adv_received=false
    for _ in $(seq 1 120); do
        cpu=$(kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
            get clusteradvertisement "agent-1-adv" -n default \
            -o jsonpath='{.spec.resources.available.cpu}' 2>/dev/null || true)
        if [[ -n "$cpu" && "$cpu" != "0" ]]; then
            adv_received=true
            break
        fi
        sleep 0.5
    done
    t_adv_received=$(now_ms)

    if [[ "$adv_received" != "true" ]]; then
        log_warn "Trial $t: Advertisement not received"
        echo "$t,$cert_gen_ms,$agent_startup_ms,N/A,N/A,N/A,N/A,N/A" >> "$OUTPUT"
        continue
    fi

    first_adv_ms=$((t_adv_received - t_agent_ready))
    broker_receive_ms=$((t_adv_received - t_adv_wait_start))
    total_ms=$((t_adv_received - t_cert_start))

    # Our component = agent startup + first advertisement delivery
    agent_portion_ms=$((agent_startup_ms + first_adv_ms))
    # External = certificate generation (in prod: cert-manager, DNS, etc.)
    external_portion_ms=$cert_gen_ms

    log_info "Trial $t:"
    log_info "  cert_gen=${cert_gen_ms}ms (external)"
    log_info "  agent_startup=${agent_startup_ms}ms (our component)"
    log_info "  first_adv=${first_adv_ms}ms (our component)"
    log_info "  broker_receive=${broker_receive_ms}ms"
    log_info "  TOTAL=${total_ms}ms (agent: ${agent_portion_ms}ms, external: ${external_portion_ms}ms)"

    echo "$t,$cert_gen_ms,$agent_startup_ms,$first_adv_ms,$broker_receive_ms,$total_ms,$agent_portion_ms,$external_portion_ms" >> "$OUTPUT"
done

# Summary
avg_total=$(awk -F, 'NR>1 && $6!="N/A" {s+=$6; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")
avg_agent=$(awk -F, 'NR>1 && $7!="N/A" {s+=$7; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")
avg_external=$(awk -F, 'NR>1 && $8!="N/A" {s+=$8; n++} END {if(n>0) printf "%.0f", s/n; else print 0}' "$OUTPUT")

log_info "Summary:"
log_info "  avg_total=${avg_total}ms"
log_info "  avg_agent_portion=${avg_agent}ms (our system)"
log_info "  avg_external_portion=${avg_external}ms (cert generation)"
if [[ "$avg_total" -gt 0 ]]; then
    pct=$(awk "BEGIN {printf \"%.0f\", ($avg_external / $avg_total) * 100}")
    log_info "  Certificate generation accounts for ~${pct}% of total startup time"
    log_info "  In production with cert-manager, this fraction would be even higher"
fi

# Cleanup
stop_all

log_info "========================================="
log_info "  Test 8 complete! Results: $OUTPUT"
log_info "========================================="
cat "$OUTPUT"
