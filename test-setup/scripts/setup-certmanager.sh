#!/bin/bash
# =============================================================================
# Setup cert-manager and Generate Certificates
# Installs cert-manager in broker cluster and creates all certificates
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../.."

echo "=============================================="
echo "  Setting up cert-manager"
echo "=============================================="

# -----------------------------------------------------------------------------
# Step 1: Install cert-manager in broker cluster
# -----------------------------------------------------------------------------
echo ""
echo "[1/5] Switching to broker-cluster..."
kubectl config use-context kind-broker-cluster

echo ""
echo "[2/5] Installing cert-manager..."
if kubectl get namespace cert-manager &> /dev/null; then
    echo "  -> cert-manager already installed, skipping..."
else
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

    echo "  -> Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=120s
    kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
    kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=120s
    echo "  -> cert-manager is ready!"
fi

# -----------------------------------------------------------------------------
# Step 2: Create CA Issuer
# -----------------------------------------------------------------------------
echo ""
echo "[3/5] Creating CA Issuer..."

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: liqo-selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: liqo-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: liqo-resource-broker-ca
  secretName: liqo-ca-secret
  duration: 87600h  # 10 years
  issuerRef:
    name: liqo-selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: liqo-ca-issuer
spec:
  ca:
    secretName: liqo-ca-secret
EOF

echo "  -> Waiting for CA to be ready..."
sleep 5
kubectl wait --for=condition=Ready certificate/liqo-ca -n cert-manager --timeout=60s

# -----------------------------------------------------------------------------
# Step 3: Create Broker Certificate
# -----------------------------------------------------------------------------
echo ""
echo "[4/5] Creating Broker certificate..."

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: broker-server-cert
  namespace: default
spec:
  secretName: broker-server-tls
  duration: 8760h
  renewBefore: 720h
  commonName: liqo-resource-broker
  subject:
    organizations:
      - LiqoResourceBroker
  dnsNames:
    - localhost
    - liqo-resource-broker
    - broker
  ipAddresses:
    - 127.0.0.1
  usages:
    - server auth
    - client auth
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: liqo-ca-issuer
    kind: ClusterIssuer
EOF

echo "  -> Waiting for broker cert..."
kubectl wait --for=condition=Ready certificate/broker-server-cert -n default --timeout=60s

# -----------------------------------------------------------------------------
# Step 4: Create Agent Certificates
# -----------------------------------------------------------------------------
echo ""
echo "[5/5] Creating Agent certificates..."

# Agent 1 certificate
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agent-1-cert
  namespace: default
spec:
  secretName: agent-1-tls
  duration: 8760h
  renewBefore: 720h
  commonName: agent-cluster-1
  subject:
    organizations:
      - LiqoResourceAgent
  usages:
    - client auth
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: liqo-ca-issuer
    kind: ClusterIssuer
EOF

# Agent 2 certificate
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agent-2-cert
  namespace: default
spec:
  secretName: agent-2-tls
  duration: 8760h
  renewBefore: 720h
  commonName: agent-cluster-2
  subject:
    organizations:
      - LiqoResourceAgent
  usages:
    - client auth
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: liqo-ca-issuer
    kind: ClusterIssuer
EOF

echo "  -> Waiting for agent certs..."
kubectl wait --for=condition=Ready certificate/agent-1-cert -n default --timeout=60s
kubectl wait --for=condition=Ready certificate/agent-2-cert -n default --timeout=60s

echo ""
echo "=============================================="
echo "  cert-manager Setup Complete!"
echo "=============================================="
echo ""
echo "Certificates created:"
kubectl get certificates -n default
echo ""
echo "Secrets created:"
kubectl get secrets -n default | grep tls
echo ""
