# Test Setup

Scripts to test the full resource sharing flow using Kind clusters with cert-manager.

## Prerequisites

- Docker running
- `kind` installed
- `kubectl` installed
- `liqoctl` installed (for Liqo peering: `curl --fail -LS https://get.liqo.io | bash`)
- Go 1.21+

---

## Quick Start

```bash
cd test-setup/scripts

# Setup (once)
./setup-clusters.sh
./setup-certmanager.sh
./extract-certs.sh

# Run (3 terminals)
./run-broker.sh      # Terminal 1
./run-agent-1.sh     # Terminal 2
./run-agent-2.sh     # Terminal 3

# Wait 30 seconds, then test
./test-reservation.sh
```

---

## Demo Commands

### 1. Show Registered Clusters

```bash
kubectl --context kind-broker-cluster get clusteradvertisements
```

### 2. Show Resource Details

```bash
kubectl --context kind-broker-cluster get clusteradvertisements -o wide
```

### 3. Create Reservation

```bash
kubectl --context kind-broker-cluster apply -f ../test-reservation.yaml
```

### 4. Check Reservation Status

```bash
kubectl --context kind-broker-cluster get reservations
```

### 5. Check Provider Received Instruction

```bash
kubectl --context kind-agent-cluster-2 get providerinstructions
```

### 6. Check Requester Received Instruction

```bash
kubectl --context kind-agent-cluster-1 get reservationinstructions
```

---

## Security Demo

### Without Certificate (should fail)

```bash
curl -k https://localhost:8443/api/v1/advertisements
```

Expected: `Client certificate required`

### With Certificate (should work)

```bash
curl --cert certs/agent1/tls.crt \
     --key certs/agent1/tls.key \
     --cacert certs/ca.crt \
     https://localhost:8443/api/v1/advertisements
```

Expected: JSON response with cluster data

### Show Certificate Identity

```bash
openssl x509 -in certs/agent1/tls.crt -text -noout | grep "Subject:"
```

Expected: `Subject: CN = agent-cluster-1`

---

## What You Should See

### After Agents Connect (~30 seconds)

```
$ kubectl --context kind-broker-cluster get clusteradvertisements

NAME                  CLUSTERID         AVAILABLE-CPU   AVAILABLE-MEMORY   ACTIVE
agent-cluster-1-adv   agent-cluster-1   3800m           7Gi                true
agent-cluster-2-adv   agent-cluster-2   3800m           7Gi                true
```

### After Creating Reservation

```
$ kubectl --context kind-broker-cluster get reservations

NAME              TARGET-CLUSTER    CPU    MEMORY   PHASE
test-reservation  agent-cluster-2   500m   256Mi    Reserved
```

### On Provider Cluster

```
$ kubectl --context kind-agent-cluster-2 get providerinstructions

NAME                        REQUESTER         CPU    MEMORY
test-reservation-provider   agent-cluster-1   500m   256Mi
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Test Environment                              │
│                                                                      │
│   ┌──────────────────┐                                               │
│   │  broker-cluster  │                                               │
│   │  ────────────────│                                               │
│   │  - cert-manager  │                                               │
│   │  - Broker API    │◄──────── HTTPS/mTLS ────────┐                 │
│   │  - CRDs:         │                             │                 │
│   │    ClusterAdv    │                             │                 │
│   │    Reservation   │                             │                 │
│   └────────┬─────────┘                             │                 │
│            │                                       │                 │
│            │ HTTPS/mTLS                            │                 │
│            ▼                                       │                 │
│   ┌──────────────────┐    Liqo Peering    ┌──────────────────┐       │
│   │ agent-cluster-1  │◄══════════════════►│ agent-cluster-2  │       │
│   │ ─────────────────│  (auto via liqoctl)│ ─────────────────│       │
│   │ - Agent + Liqo   │                   │ - Agent + Liqo   │       │
│   │ - Requester      │                   │ - Provider       │       │
│   │ - CRDs:          │                   │ - CRDs:          │       │
│   │   ReservationInst│                   │   ProviderInst   │       │
│   │ - Virtual Node   │                   │                  │       │
│   │   (from cluster2)│                   │                  │       │
│   └──────────────────┘                   └──────────────────┘       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Certificate Management

Certificates are managed by cert-manager:

| Certificate | CN (Identity) | Purpose |
|-------------|---------------|---------|
| `broker-server-cert` | `liqo-resource-broker` | Broker server |
| `agent-1-cert` | `agent-cluster-1` | Agent 1 client |
| `agent-2-cert` | `agent-cluster-2` | Agent 2 client |

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `setup-clusters.sh` | Creates 3 Kind clusters, exports kubeconfigs, installs Liqo |
| `setup-certmanager.sh` | Installs cert-manager + certificates |
| `extract-certs.sh` | Extracts certs to local files |
| `run-broker.sh` | Runs broker |
| `run-agent-1.sh` | Runs agent 1 (requester) |
| `run-agent-2.sh` | Runs agent 2 (provider) |
| `test-reservation.sh` | Creates test reservation + verifies Liqo peering |
| `status.sh` | Shows status of all clusters + Liqo peering |
| `cleanup.sh` | Deletes everything |

---

## Liqo Peering

After a reservation is processed by the broker, the requester agent **automatically** establishes Liqo peering with the provider cluster. This creates a virtual node in the requester cluster that represents the provider's resources.

### How It Works

1. Broker decides `agent-cluster-2` should provide resources to `agent-cluster-1`
2. Agent 1 receives a `ReservationInstruction` with `targetClusterID: agent-cluster-2`
3. Agent 1 automatically runs: `liqoctl peer --kubeconfig <local> --remote-kubeconfig <remote> --gw-server-service-type NodePort`
4. Liqo creates a virtual node in agent-cluster-1 representing agent-cluster-2's resources
5. Workloads scheduled on the virtual node run on agent-cluster-2

### Verify Peering

```bash
# Check virtual nodes in requester cluster
kubectl --context kind-agent-cluster-1 get nodes

# Check Liqo peering status
liqoctl status peer --kubeconfig kubeconfigs/agent-cluster-1.kubeconfig
```

---

## Troubleshooting

**Clusters not showing:**
- Wait 30 seconds after starting agents
- Check `kubectl --context kind-broker-cluster get clusteradvertisements`

**Connection refused:**
- Make sure broker is running first
- Check broker is on port 8443

**Reservation stays Pending:**
```bash
kubectl --context kind-broker-cluster describe reservation test-reservation
```

---

## Cleanup

```bash
./cleanup.sh
```
