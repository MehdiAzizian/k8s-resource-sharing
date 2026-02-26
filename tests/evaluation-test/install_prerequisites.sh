#!/usr/bin/env bash
# Install all prerequisites for the evaluation test suite on a fresh Ubuntu server
set -euo pipefail

echo "=== Installing prerequisites for evaluation tests ==="

# 1. System packages
echo "[1/6] Installing system packages (curl, openssl, git)..."
sudo apt-get update -qq
sudo apt-get install -y -qq curl openssl git ca-certificates gnupg

# 2. Docker
echo "[2/6] Installing Docker..."
if ! command -v docker &>/dev/null; then
    sudo apt-get install -y -qq docker.io
    sudo usermod -aG docker "$USER"
    echo "  -> Docker installed. Group 'docker' added to user '$USER'."
else
    echo "  -> Docker already installed."
fi

# 3. Go 1.24
echo "[3/6] Installing Go 1.24..."
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null)" != *"go1.24"* ]]; then
    GO_VERSION="1.24.0"
    curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    # Add to PATH for current session
    export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
    # Add to bashrc for future sessions
    if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    echo "  -> Go $(go version) installed."
else
    echo "  -> Go already installed: $(go version)"
fi

# Make sure Go is in PATH for the rest of this script
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# 4. Kind
echo "[4/6] Installing Kind..."
if ! command -v kind &>/dev/null; then
    KIND_VERSION=$(curl -sL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -sL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -o /tmp/kind
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
    echo "  -> Kind installed: $(kind version)"
else
    echo "  -> Kind already installed: $(kind version)"
fi

# 5. kubectl
echo "[5/6] Installing kubectl..."
if ! command -v kubectl &>/dev/null; then
    KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    echo "  -> kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    echo "  -> kubectl already installed."
fi

# 6. Increase inotify limits (needed for many Kind clusters)
echo "[6/6] Setting inotify limits..."
CURRENT_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
CURRENT_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
if [[ "$CURRENT_INSTANCES" -lt 8192 ]]; then
    sudo sysctl -w fs.inotify.max_user_instances=8192 >/dev/null
    sudo sysctl -w fs.inotify.max_user_watches=655360 >/dev/null
    # Make persistent across reboots
    echo "fs.inotify.max_user_instances=8192" | sudo tee -a /etc/sysctl.conf >/dev/null
    echo "fs.inotify.max_user_watches=655360" | sudo tee -a /etc/sysctl.conf >/dev/null
    echo "  -> inotify limits increased (instances=8192, watches=655360)"
else
    echo "  -> inotify limits already sufficient (instances=$CURRENT_INSTANCES, watches=$CURRENT_WATCHES)"
fi

echo ""
echo "=== All prerequisites installed ==="
echo ""
echo "IMPORTANT: You need to apply the docker group change. Do ONE of:"
echo "  Option A: Log out and log back in"
echo "  Option B: Run 'newgrp docker' (for current terminal only)"
echo ""
echo "Then run: ./setup.sh"
