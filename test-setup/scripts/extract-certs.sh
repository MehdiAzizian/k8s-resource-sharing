#!/bin/bash
# =============================================================================
# Extract Certificates from Kubernetes Secrets
# Copies cert-manager generated certs to local files for local testing
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../certs"

echo "=============================================="
echo "  Extracting Certificates from Secrets"
echo "=============================================="

# Make sure we're on broker cluster
kubectl config use-context kind-broker-cluster > /dev/null 2>&1

# Create directories
mkdir -p "$CERT_DIR"/{broker,agent1,agent2}

# -----------------------------------------------------------------------------
# Extract CA certificate (from the CA secret)
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Extracting CA certificate..."
kubectl get secret liqo-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CERT_DIR/ca.crt"

# Copy CA to all directories
cp "$CERT_DIR/ca.crt" "$CERT_DIR/broker/"
cp "$CERT_DIR/ca.crt" "$CERT_DIR/agent1/"
cp "$CERT_DIR/ca.crt" "$CERT_DIR/agent2/"
echo "  -> CA extracted"

# -----------------------------------------------------------------------------
# Extract Broker certificate
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] Extracting Broker certificate..."
kubectl get secret broker-server-tls -n default -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT_DIR/broker/tls.crt"
kubectl get secret broker-server-tls -n default -o jsonpath='{.data.tls\.key}' | base64 -d > "$CERT_DIR/broker/tls.key"
echo "  -> Broker cert extracted"

# -----------------------------------------------------------------------------
# Extract Agent 1 certificate
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Extracting Agent-1 certificate..."
kubectl get secret agent-1-tls -n default -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT_DIR/agent1/tls.crt"
kubectl get secret agent-1-tls -n default -o jsonpath='{.data.tls\.key}' | base64 -d > "$CERT_DIR/agent1/tls.key"
echo "  -> Agent-1 cert extracted (CN=agent-cluster-1)"

# -----------------------------------------------------------------------------
# Extract Agent 2 certificate
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] Extracting Agent-2 certificate..."
kubectl get secret agent-2-tls -n default -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERT_DIR/agent2/tls.crt"
kubectl get secret agent-2-tls -n default -o jsonpath='{.data.tls\.key}' | base64 -d > "$CERT_DIR/agent2/tls.key"
echo "  -> Agent-2 cert extracted (CN=agent-cluster-2)"

echo ""
echo "=============================================="
echo "  Certificates Extracted Successfully!"
echo "=============================================="
echo ""
echo "Locations:"
echo "  CA:      $CERT_DIR/ca.crt"
echo "  Broker:  $CERT_DIR/broker/"
echo "  Agent-1: $CERT_DIR/agent1/"
echo "  Agent-2: $CERT_DIR/agent2/"
echo ""
echo "Verify with:"
echo "  openssl x509 -in $CERT_DIR/broker/tls.crt -text -noout | grep -A1 Subject:"
echo ""
