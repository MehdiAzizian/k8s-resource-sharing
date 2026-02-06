#!/bin/bash
# =============================================================================
# Cleanup Test Environment
# Deletes kind clusters and certificates
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../certs"

echo "=============================================="
echo "  Cleanup Test Environment"
echo "=============================================="
echo ""
echo "This will delete:"
echo "  - Kind clusters: broker-cluster, agent-cluster-1, agent-cluster-2"
echo "  - Test certificates"
echo ""
read -p "Are you sure? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "[1/4] Deleting broker-cluster..."
kind delete cluster --name broker-cluster 2>/dev/null || echo "  -> Not found"

echo ""
echo "[2/4] Deleting agent-cluster-1..."
kind delete cluster --name agent-cluster-1 2>/dev/null || echo "  -> Not found"

echo ""
echo "[3/4] Deleting agent-cluster-2..."
kind delete cluster --name agent-cluster-2 2>/dev/null || echo "  -> Not found"

echo ""
echo "[4/4] Deleting certificates..."
rm -rf "$CERT_DIR"
echo "  -> Done"

echo ""
echo "=============================================="
echo "  Cleanup Complete!"
echo "=============================================="
echo ""
