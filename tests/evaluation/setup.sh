#!/usr/bin/env bash
# One-time setup: build binaries, generate certs, install k3d, create broker cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

log_info "========================================="
log_info "  Evaluation Test Suite - Setup"
log_info "========================================="

# Check prerequisites
log_info "Checking prerequisites..."
for cmd in docker kubectl go openssl curl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "'$cmd' is not installed"
        exit 1
    fi
done

# Install k3d if not present
if ! command -v k3d &>/dev/null; then
    log_info "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
log_info "k3d version: $(k3d version | head -1)"
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

# Create broker cluster (agent clusters are created per-test)
create_cluster "$BROKER_CLUSTER"
install_broker_crds

log_info "========================================="
log_info "  Setup complete!"
log_info "  Broker cluster ready: $BROKER_CLUSTER"
log_info "  Agent clusters will be created per-test"
log_info "  Run tests:  ./test1_broker_scalability.sh"
log_info "  Results in: $RESULTS_DIR/"
log_info "========================================="
