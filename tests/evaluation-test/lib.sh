#!/usr/bin/env bash
# Common functions for evaluation tests
#
# Uses Kind (Kubernetes in Docker) for cluster management.
# Requires sysctl tuning for many clusters (fs.inotify.max_user_instances=8192).
# Each agent gets its own real, separate Kind cluster.
set -euo pipefail

# ============================================================
# PATHS & CONSTANTS
# ============================================================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BROKER_DIR="$REPO_ROOT/liqo-resource-broker"
AGENT_DIR="$REPO_ROOT/liqo-resource-agent"
EVAL_DIR="$REPO_ROOT/tests/evaluation"
RESULTS_DIR="$EVAL_DIR/results"

WORK_DIR="/tmp/k8s-eval"
CERTS_DIR="$WORK_DIR/certs"
KUBECONFIGS_DIR="$WORK_DIR/kubeconfigs"
LOGS_DIR="$WORK_DIR/logs"
PIDS_DIR="$WORK_DIR/pids"

BROKER_PORT=8443
BROKER_HEALTH_PORT=8081
AGENT_HEALTH_PORT_BASE=9000

BROKER_CLUSTER="broker"

# ============================================================
# INITIALIZATION
# ============================================================
init_workdir() {
    mkdir -p "$RESULTS_DIR" "$CERTS_DIR" "$KUBECONFIGS_DIR" "$LOGS_DIR" "$PIDS_DIR"
}

# ============================================================
# LOGGING
# ============================================================
log_info()  { echo "[INFO]  $(date +%H:%M:%S) $*"; }
log_warn()  { echo "[WARN]  $(date +%H:%M:%S) $*"; }
log_error() { echo "[ERROR] $(date +%H:%M:%S) $*" >&2; }

# ============================================================
# CERTIFICATES (openssl)
# ============================================================
generate_ca() {
    local ca_dir="$CERTS_DIR/ca"
    mkdir -p "$ca_dir"
    [[ -f "$ca_dir/ca.crt" ]] && return 0

    log_info "Generating CA certificate..."
    openssl genrsa -out "$ca_dir/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$ca_dir/ca.key" \
        -sha256 -days 365 -out "$ca_dir/ca.crt" \
        -subj "/CN=evaluation-ca" 2>/dev/null
}

generate_broker_cert() {
    local cert_dir="$CERTS_DIR/broker"
    mkdir -p "$cert_dir"
    [[ -f "$cert_dir/tls.crt" ]] && return 0

    log_info "Generating broker server certificate..."
    cat > "$cert_dir/openssl.cnf" <<EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
[req_dn]
CN = liqo-resource-broker
[v3_req]
subjectAltName = DNS:localhost,DNS:liqo-resource-broker,IP:127.0.0.1
extendedKeyUsage = serverAuth,clientAuth
EOF

    openssl genrsa -out "$cert_dir/tls.key" 4096 2>/dev/null
    openssl req -new -key "$cert_dir/tls.key" \
        -out "$cert_dir/tls.csr" \
        -subj "/CN=liqo-resource-broker" \
        -config "$cert_dir/openssl.cnf" 2>/dev/null
    openssl x509 -req -in "$cert_dir/tls.csr" \
        -CA "$CERTS_DIR/ca/ca.crt" -CAkey "$CERTS_DIR/ca/ca.key" \
        -CAcreateserial -out "$cert_dir/tls.crt" \
        -days 365 -sha256 \
        -extensions v3_req -extfile "$cert_dir/openssl.cnf" 2>/dev/null
    cp "$CERTS_DIR/ca/ca.crt" "$cert_dir/ca.crt"
}

generate_agent_cert() {
    local agent_id=$1
    local cert_dir="$CERTS_DIR/$agent_id"
    mkdir -p "$cert_dir"
    [[ -f "$cert_dir/tls.crt" ]] && return 0

    cat > "$cert_dir/openssl.cnf" <<EOF
[ext]
extendedKeyUsage = clientAuth
EOF

    openssl genrsa -out "$cert_dir/tls.key" 4096 2>/dev/null
    openssl req -new -key "$cert_dir/tls.key" \
        -out "$cert_dir/tls.csr" \
        -subj "/CN=$agent_id" 2>/dev/null
    openssl x509 -req -in "$cert_dir/tls.csr" \
        -CA "$CERTS_DIR/ca/ca.crt" -CAkey "$CERTS_DIR/ca/ca.key" \
        -CAcreateserial -out "$cert_dir/tls.crt" \
        -days 365 -sha256 \
        -extfile "$cert_dir/openssl.cnf" -extensions ext 2>/dev/null
    cp "$CERTS_DIR/ca/ca.crt" "$cert_dir/ca.crt"
}

# ============================================================
# KIND CLUSTER MANAGEMENT
# ============================================================
create_cluster() {
    local name=$1
    local max_retries=3
    if kind get clusters 2>/dev/null | grep -qx "$name"; then
        log_info "Cluster '$name' already exists"
    else
        local attempt
        for attempt in $(seq 1 "$max_retries"); do
            log_info "Creating Kind cluster '$name'... (attempt $attempt/$max_retries)"
            if kind create cluster --name "$name" --wait 180s 2>&1 | tail -1; then
                break
            fi
            if [[ $attempt -lt $max_retries ]]; then
                log_warn "Cluster '$name' creation failed, retrying in 5s..."
                kind delete cluster --name "$name" 2>/dev/null || true
                sleep 5
            else
                log_error "Cluster '$name' failed after $max_retries attempts"
                return 1
            fi
        done
    fi
    kind get kubeconfig --name "$name" > "$KUBECONFIGS_DIR/$name.kubeconfig"
}

# Create multiple clusters in parallel (batched)
create_clusters_parallel() {
    local prefix=$1
    local count=$2
    local batch_size=${3:-5}

    for ((start=1; start<=count; start+=batch_size)); do
        local end=$((start + batch_size - 1))
        if [[ $end -gt $count ]]; then end=$count; fi

        log_info "Creating clusters ${prefix}-${start} to ${prefix}-${end} in parallel..."
        local pids=()
        for i in $(seq "$start" "$end"); do
            create_cluster "${prefix}-${i}" &
            pids+=($!)
        done

        # Wait for all in this batch
        local failed=0
        for pid in "${pids[@]}"; do
            if ! wait "$pid" 2>/dev/null; then
                ((failed++)) || true
            fi
        done

        if [[ $failed -gt 0 ]]; then
            log_error "$failed cluster(s) failed in batch starting at ${prefix}-${start}"
            return 1
        fi
    done
}

delete_cluster() {
    local name=$1
    if kind get clusters 2>/dev/null | grep -qx "$name"; then
        log_info "Deleting Kind cluster '$name'..."
        kind delete cluster --name "$name" 2>/dev/null
    fi
    rm -f "$KUBECONFIGS_DIR/$name.kubeconfig"
}

# ============================================================
# CRD INSTALLATION
# ============================================================
install_broker_crds() {
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"
    log_info "Installing broker CRDs..."
    kubectl --kubeconfig "$kubeconfig" apply -f "$BROKER_DIR/config/crd/bases/" 2>/dev/null
}

install_agent_crds() {
    local cluster_name=$1
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"
    log_info "Installing agent CRDs on '$cluster_name'..."
    kubectl --kubeconfig "$kubeconfig" apply -f "$AGENT_DIR/config/crd/bases/" 2>/dev/null
}

# ============================================================
# PROCESS MANAGEMENT
# ============================================================
start_broker() {
    log_info "Starting broker..."
    KUBECONFIG="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
        "$BROKER_DIR/bin/broker" \
        --broker-interface=http \
        --http-port="$BROKER_PORT" \
        --http-cert-path="$CERTS_DIR/broker" \
        --http-namespace=default \
        --health-probe-bind-address=":$BROKER_HEALTH_PORT" \
        --metrics-bind-address=0 \
        > "$LOGS_DIR/broker.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDS_DIR/broker.pid"
    log_info "Broker started (PID: $pid)"
    wait_for_broker
}

wait_for_broker() {
    log_info "Waiting for broker health endpoint..."
    for _ in $(seq 1 30); do
        if curl -s http://localhost:$BROKER_HEALTH_PORT/healthz >/dev/null 2>&1; then
            log_info "Broker is ready"
            return 0
        fi
        sleep 1
    done
    log_error "Broker failed to start. Check $LOGS_DIR/broker.log"
    return 1
}

# Start an agent on its own cluster.
# Parameters:
#   agent_id     - unique agent identifier (must match cert CN)
#   cluster_name - k3d cluster to connect to
#   agent_num    - numeric index (for unique health port)
start_agent() {
    local agent_id=$1
    local cluster_name=$2
    local agent_num=$3
    local health_port=$((AGENT_HEALTH_PORT_BASE + agent_num))

    KUBECONFIG="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig" \
        "$AGENT_DIR/bin/agent" \
        --broker-transport=http \
        --broker-url="https://localhost:$BROKER_PORT" \
        --broker-cert-path="$CERTS_DIR/$agent_id" \
        --cluster-id="$agent_id" \
        --health-probe-bind-address=":$health_port" \
        --metrics-bind-address=0 \
        --metrics-secure=false \
        --advertisement-requeue-interval=30s \
        > "$LOGS_DIR/${agent_id}.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDS_DIR/${agent_id}.pid"
    log_info "Agent '$agent_id' started (PID: $pid, cluster: $cluster_name)"
}

stop_process() {
    local name=$1
    local pid_file="$PIDS_DIR/${name}.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
}

stop_all_agents() {
    for pid_file in "$PIDS_DIR"/agent-*.pid; do
        [[ -f "$pid_file" ]] || continue
        local name
        name=$(basename "$pid_file" .pid)
        stop_process "$name"
    done
}

stop_broker() {
    stop_process "broker"
}

stop_all() {
    stop_all_agents
    stop_broker
}

# ============================================================
# MEASUREMENT HELPERS
# ============================================================
get_rss_kb() {
    local pid=$1
    awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

get_cpu_ticks() {
    local pid=$1
    awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0
}

get_clk_tck() {
    getconf CLK_TCK
}

calc_cpu_percent() {
    local ticks_before=$1 ticks_after=$2 interval=$3
    local clk_tck
    clk_tck=$(get_clk_tck)
    awk "BEGIN {printf \"%.2f\", ($ticks_after - $ticks_before) / ($interval * $clk_tck) * 100}"
}

now_ms() {
    date +%s%3N
}

# ============================================================
# KUBERNETES HELPERS
# ============================================================
wait_for_cluster_advertisement() {
    local cluster_id=$1
    local timeout=${2:-120}
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"
    local adv_name="${cluster_id}-adv"

    for _ in $(seq 1 "$timeout"); do
        local cpu
        cpu=$(kubectl --kubeconfig "$kubeconfig" get clusteradvertisement "$adv_name" -n default \
            -o jsonpath='{.spec.resources.available.cpu}' 2>/dev/null || true)
        if [[ -n "$cpu" && "$cpu" != "0" ]]; then
            log_info "ClusterAdvertisement '$adv_name' ready (CPU: $cpu)"
            return 0
        fi
        sleep 1
    done
    log_error "Timeout waiting for ClusterAdvertisement '$adv_name'"
    return 1
}

create_reservation() {
    local name=$1 requester_id=$2 cpu=$3 memory=$4
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"

    kubectl --kubeconfig "$kubeconfig" --request-timeout=15s apply -f - <<EOF
apiVersion: broker.fluidos.eu/v1alpha1
kind: Reservation
metadata:
  name: $name
  namespace: default
spec:
  requesterID: "$requester_id"
  requestedResources:
    cpu: "$cpu"
    memory: "$memory"
EOF
}

wait_for_reservation_phase() {
    local name=$1 phase=$2 timeout=${3:-60}
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"

    for _ in $(seq 1 "$timeout"); do
        local current
        current=$(kubectl --kubeconfig "$kubeconfig" --request-timeout=10s \
            get reservation "$name" -n default \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$current" == "$phase" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

get_reservation_target() {
    local name=$1
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"
    kubectl --kubeconfig "$kubeconfig" --request-timeout=10s \
        get reservation "$name" -n default \
        -o jsonpath='{.spec.targetClusterID}' 2>/dev/null
}

delete_reservation() {
    local name=$1
    kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
        --request-timeout=30s --wait=false \
        delete reservation "$name" -n default --ignore-not-found 2>/dev/null
}

delete_all_reservations() {
    kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
        --request-timeout=60s --wait=false \
        delete reservations --all -n default --ignore-not-found 2>/dev/null
}

clean_broker_crds() {
    local kubeconfig="$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig"
    kubectl --kubeconfig "$kubeconfig" --wait=false delete clusteradvertisements --all -n default --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" --wait=false delete reservations --all -n default --ignore-not-found 2>/dev/null
}

get_broker_available_cpu() {
    local cluster_id=$1
    kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
        --request-timeout=10s \
        get clusteradvertisement "${cluster_id}-adv" -n default \
        -o jsonpath='{.spec.resources.available.cpu}' 2>/dev/null
}

get_broker_available_memory() {
    local cluster_id=$1
    kubectl --kubeconfig "$KUBECONFIGS_DIR/$BROKER_CLUSTER.kubeconfig" \
        --request-timeout=10s \
        get clusteradvertisement "${cluster_id}-adv" -n default \
        -o jsonpath='{.spec.resources.available.memory}' 2>/dev/null
}

deploy_dummy_pod() {
    local cluster_name=$1 pod_name=$2 cpu=$3 memory=$4
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    kubectl --kubeconfig "$kubeconfig" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  namespace: default
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: "$cpu"
        memory: "$memory"
EOF
}

delete_dummy_pod() {
    local cluster_name=$1 pod_name=$2
    kubectl --kubeconfig "$KUBECONFIGS_DIR/${cluster_name}.kubeconfig" \
        delete pod "$pod_name" -n default --ignore-not-found 2>/dev/null
}

wait_for_pod_running() {
    local cluster_name=$1 pod_name=$2 timeout=${3:-60}
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    for _ in $(seq 1 "$timeout"); do
        local phase
        phase=$(kubectl --kubeconfig "$kubeconfig" get pod "$pod_name" -n default \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$phase" == "Running" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_provider_instruction() {
    local cluster_name=$1 timeout=${2:-60}
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    for _ in $(seq 1 "$timeout"); do
        local count
        count=$(kubectl --kubeconfig "$kubeconfig" get providerinstructions -n default \
            --no-headers 2>/dev/null | wc -l || true)
        if [[ "$count" -gt 0 ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

wait_for_reservation_instruction() {
    local cluster_name=$1 timeout=${2:-60}
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    for _ in $(seq 1 "$timeout"); do
        local count
        count=$(kubectl --kubeconfig "$kubeconfig" get reservationinstructions -n default \
            --no-headers 2>/dev/null | wc -l || true)
        if [[ "$count" -gt 0 ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ============================================================
# RESOURCE REQUEST HELPERS (new synchronous flow)
# ============================================================

# Create a ResourceRequest on an agent cluster (triggers synchronous reservation)
create_resource_request() {
    local name=$1 cluster_name=$2 cpu=$3 memory=$4
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    kubectl --kubeconfig "$kubeconfig" --request-timeout=15s apply -f - <<EOF
apiVersion: rear.fluidos.eu/v1alpha1
kind: ResourceRequest
metadata:
  name: $name
  namespace: default
spec:
  requestedCPU: "$cpu"
  requestedMemory: "$memory"
EOF
}

# Wait for a ResourceRequest to reach a specific phase on the agent cluster
wait_for_resource_request_phase() {
    local name=$1 cluster_name=$2 phase=$3 timeout=${4:-60}
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"

    for _ in $(seq 1 "$timeout"); do
        local current
        current=$(kubectl --kubeconfig "$kubeconfig" --request-timeout=10s \
            get resourcerequest "$name" -n default \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$current" == "$phase" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Get the target cluster from a ResourceRequest on the agent cluster
get_resource_request_target() {
    local name=$1 cluster_name=$2
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"
    kubectl --kubeconfig "$kubeconfig" --request-timeout=10s \
        get resourcerequest "$name" -n default \
        -o jsonpath='{.status.targetClusterID}' 2>/dev/null
}

# Delete a ResourceRequest on an agent cluster
delete_resource_request() {
    local name=$1 cluster_name=$2
    kubectl --kubeconfig "$KUBECONFIGS_DIR/${cluster_name}.kubeconfig" \
        --request-timeout=30s --wait=false \
        delete resourcerequest "$name" -n default --ignore-not-found 2>/dev/null
}

# Delete all ResourceRequests on an agent cluster
delete_all_resource_requests() {
    local cluster_name=$1
    kubectl --kubeconfig "$KUBECONFIGS_DIR/${cluster_name}.kubeconfig" \
        --request-timeout=60s --wait=false \
        delete resourcerequests --all -n default --ignore-not-found 2>/dev/null
}

# Clean agent instructions (provider + reservation)
clean_agent_instructions() {
    local cluster_name=$1
    local kubeconfig="$KUBECONFIGS_DIR/${cluster_name}.kubeconfig"
    kubectl --kubeconfig "$kubeconfig" delete providerinstructions --all -n default --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" delete reservationinstructions --all -n default --ignore-not-found 2>/dev/null
    kubectl --kubeconfig "$kubeconfig" delete resourcerequests --all -n default --ignore-not-found 2>/dev/null
}

# ============================================================
# STATISTICS HELPERS
# ============================================================

# Compute median from a list of values (one per line on stdin)
compute_median() {
    sort -n | awk '{a[NR]=$1} END {if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# Compute variance from a list of values (one per line on stdin)
compute_variance() {
    awk '{sum+=$1; sumsq+=$1*$1; n++} END {if(n>1) printf "%.2f", (sumsq - sum*sum/n)/(n-1); else print 0}'
}

# Compute P95 from a list of values (one per line on stdin)
compute_p95() {
    sort -n | awk '{a[NR]=$1} END {idx=int(NR*0.95); if(idx<1) idx=1; print a[idx]}'
}
