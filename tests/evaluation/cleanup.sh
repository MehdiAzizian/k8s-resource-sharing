#!/usr/bin/env bash
# Cleanup all evaluation resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
init_workdir

log_info "========================================="
log_info "  Cleaning up all evaluation resources"
log_info "========================================="

# Stop all running processes
stop_all

# Delete all Kind clusters
for cluster in $(kind get clusters 2>/dev/null); do
    log_info "Deleting cluster '$cluster'..."
    kind delete cluster --name "$cluster" 2>/dev/null || true
done

# Clean up work directory
rm -rf "$WORK_DIR"

log_info "Cleanup complete!"
