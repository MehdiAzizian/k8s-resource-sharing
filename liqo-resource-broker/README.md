# Liqo Resource Broker

Central resource brokerage system for multi-cluster Kubernetes environments.

## What It Does

The broker is the central coordination point that:
- Receives resource advertisements from agent clusters
- Runs a decision engine to select the best provider
- Manages reservation lifecycle and resource locking

## Architecture

```
Agent Cluster 1                    Broker                    Agent Cluster 2
─────────────────                 ────────                   ─────────────────

Publish resources ─────────────>  Stores advertisement

                                  Receives reservation request
                                  Runs DecisionEngine
                                  Selects best provider
                                  Locks resources (Reserved field)

Poll reservations <─────────────  Returns instructions  ─────────────> Poll reservations

ReservationInstruction            Phase: Reserved           ProviderInstruction
(use Cluster 2)                                             (reserve for Cluster 1)
```

## Key Features

| Feature | Description |
|---------|-------------|
| **HTTP REST API** | mTLS authenticated endpoints for agents |
| **Decision Engine** | Selects cluster based on CPU/memory availability |
| **Resource Locking** | Reserved field prevents double-booking |
| **cert-manager** | Automatic certificate management |

## Quick Start

```bash
# 1. Install CRDs
make install

# 2. Setup certificates
kubectl apply -k config/certmanager/

# 3. Run broker
./bin/broker \
  --broker-interface=http \
  --http-port=8443 \
  --http-cert-path=/path/to/certs
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/advertisements` | Receive cluster advertisement |
| GET | `/api/v1/advertisements/{id}` | Get advertisement (with Reserved field) |
| GET | `/api/v1/reservations` | Poll reservations for a cluster |
| GET | `/healthz` | Health check |

## CRDs

- **ClusterAdvertisement** - Cluster resources (Allocatable, Allocated, Reserved, Available)
- **Reservation** - Resource request with lifecycle (Pending → Reserved → Active → Released)

## Project Structure

```
├── api/v1alpha1/           # CRD type definitions
├── cmd/main.go             # Entry point
├── internal/
│   ├── api/                # HTTP server, handlers, middleware
│   ├── broker/decision.go  # Decision engine
│   ├── controller/         # Kubernetes controllers
│   └── resource/           # Availability calculations
└── config/
    ├── crd/                # CRD manifests
    └── certmanager/        # Certificate configuration
```

## Authentication

All API requests require mTLS. The cluster ID is extracted from certificate CN (Common Name).

```
Agent certificate: CN=cluster-1
Broker reads CN → identifies as "cluster-1"
```
