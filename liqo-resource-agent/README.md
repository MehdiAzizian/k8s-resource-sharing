# Liqo Resource Agent

Cluster-side agent that monitors resources and communicates with the central broker.

## What It Does

The agent runs in each Kubernetes cluster to:
- Monitor local resources (nodes, pods)
- Publish advertisements to the broker
- Receive reservation instructions
- Track reserved resources

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Agent Cluster                       │
│                                                  │
│  Nodes + Pods ──> MetricsCollector              │
│                        │                         │
│                        v                         │
│                  Advertisement                   │
│                        │                         │
│                        v                         │
│              BrokerCommunicator ────────> Broker │
│                        │                         │
│                        v                         │
│  ReservationInstruction / ProviderInstruction   │
└─────────────────────────────────────────────────┘
```

## Key Features

| Feature | Description |
|---------|-------------|
| **Resource Monitoring** | Collects CPU, Memory, GPU from nodes and pods |
| **HTTP Transport** | mTLS authenticated communication with broker |
| **BrokerCommunicator Interface** | Protocol-agnostic design |
| **Reserved Field Preservation** | Prevents double-booking race conditions |

## Quick Start

```bash
# 1. Install CRDs
make install

# 2. Setup certificates
kubectl apply -k config/certmanager/

# 3. Run agent
./bin/agent \
  --broker-transport=http \
  --broker-url=https://broker:8443 \
  --broker-cert-path=/path/to/certs \
  --cluster-id=my-cluster
```

## Resource Calculation

```
Available = Allocatable - Allocated - Reserved

Where:
- Allocatable = Node capacity minus system reserved
- Allocated   = Sum of pod resource requests
- Reserved    = Resources locked by broker reservations
```

## CRDs

- **Advertisement** - Local cluster state published to broker
- **ReservationInstruction** - Tells cluster to use remote resources
- **ProviderInstruction** - Tells cluster to reserve resources for others

## Project Structure

```
├── api/v1alpha1/           # CRD type definitions
├── cmd/main.go             # Entry point
├── internal/
│   ├── controller/         # Kubernetes controllers
│   ├── metrics/            # Resource collector
│   ├── publisher/          # Legacy K8s transport
│   └── transport/          # Protocol abstraction
│       ├── interface.go    # BrokerCommunicator interface
│       └── http/           # HTTP implementation
└── config/
    ├── crd/                # CRD manifests
    └── certmanager/        # Certificate configuration
```

## BrokerCommunicator Interface

```go
type BrokerCommunicator interface {
    PublishAdvertisement(ctx, adv) error
    FetchReservations(ctx, clusterID, role) ([]*Reservation, error)
    Ping(ctx) error
    Close() error
}
```

This interface allows adding new transport protocols (MQTT, gRPC, etc.) without changing business logic.

## Authentication

Certificate CN = Cluster ID

```
Certificate: CN=my-cluster
Agent uses this certificate → Broker identifies as "my-cluster"
```
