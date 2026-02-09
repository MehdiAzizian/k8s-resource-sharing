#!/usr/bin/env bash
# One-time setup: build binaries, generate certs, create 2 Kind clusters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

log_info "========================================="
log_info "  Evaluation Test Suite - Setup"
log_info "========================================="

# Check prerequisites
log_info "Checking prerequisites..."
for cmd in docker kind kubectl go openssl curl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "'$cmd' is not installed"
        exit 1
    fi
done
log_info "All prerequisites found"

# Build broker
log_info "Building broker binary..."
cd "$BROKER_DIR"
go build -o bin/broker cmd/main.go
log_info "Broker binary: $BROKER_DIR/bin/broker"

# Generate agent CRD manifests
log_info "Generating CRD manifests..."
cd "$AGENT_DIR"
GOBIN="$AGENT_DIR/bin" go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest 2>/dev/null || true
"$AGENT_DIR/bin/controller-gen" crd paths="./..." output:crd:artifacts:config=config/crd/bases 2>/dev/null || \
    make manifests 2>/dev/null || true

# Build agent
log_info "Building agent binary..."
go build -o bin/agent cmd/main.go
log_info "Agent binary: $AGENT_DIR/bin/agent"

# Generate certificates
generate_ca
generate_broker_cert
log_info "Generating agent certificates (1-20)..."
for i in $(seq 1 20); do
    generate_agent_cert "agent-$i"
done
log_info "All certificates generated"

# Create exactly 2 Kind clusters (all tests share these)
create_cluster "$BROKER_CLUSTER"
create_cluster "$SHARED_CLUSTER"

# Install CRDs on both clusters
install_broker_crds
install_agent_crds "$SHARED_CLUSTER"
install_agent_crds "$BROKER_CLUSTER"

log_info "========================================="
log_info "  Setup complete! (2 clusters: $BROKER_CLUSTER + $SHARED_CLUSTER)"
log_info "  Run tests:  ./test1_broker_scalability.sh"
log_info "  Results in: $RESULTS_DIR/"
log_info "========================================="
