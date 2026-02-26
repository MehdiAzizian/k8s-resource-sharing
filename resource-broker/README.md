# Liqo Resource Broker

Central coordination component for multi-cluster Kubernetes resource sharing. The broker collects resource advertisements from all connected agent clusters, processes reservation requests through a scoring-based decision engine, and manages the reservation lifecycle with atomic resource locking.

## Reservation Flow

```
 Requester Agent                     Broker                      Provider Agent
      │                                │                               │
      │   POST /api/v1/advertisements  │  POST /api/v1/advertisements  │
      │ ─────────────────────────────► │ ◄───────────────────────────── │
      │        (every 30s)             │        (every 30s)            │
      │                                │                               │
      │   POST /api/v1/reservations    │                               │
      │ ─────────────────────────────► │                               │
      │                                │── Decision Engine             │
      │                                │   ├─ Filter (sufficient?)     │
      │                                │   ├─ Score (headroom)         │
      │                                │   └─ Lock (Reserved += req)   │
      │   HTTP 200 + instruction       │                               │
      │ ◄───────────────────────────── │                               │
      │   (synchronous, sub-second)    │                               │
      │                                │   GET /api/v1/instructions    │
      │                                │ ◄───────────────────────────── │
      │                                │   ProviderInstruction         │
      │                                │ ─────────────────────────────►│
      │                                │        (polling, every 5s)    │
```

**Requester path (synchronous):** The agent sends `POST /api/v1/reservations`. The broker runs the decision engine inline, locks resources, and returns the `ReservationInstruction` in the HTTP response. The requester receives its instruction in a single round trip (sub-second).

**Provider path (polling):** The provider agent polls `GET /api/v1/instructions` every 5 seconds. When a new reservation targets this cluster, the broker returns the `ProviderInstruction`.

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/v1/advertisements` | Receive a cluster resource advertisement. Preserves the broker's `Reserved` field. |
| `GET` | `/api/v1/advertisements/{id}` | Retrieve a specific cluster's advertisement (including `Reserved` field). |
| `POST` | `/api/v1/reservations` | **Synchronous reservation.** Runs decision engine, locks resources, returns instruction in the response. |
| `GET` | `/api/v1/instructions` | Poll for provider instructions. Returns pending `ProviderInstruction` objects for the calling cluster (identified by mTLS CN). |
| `GET` | `/healthz` | Health check (no authentication required). |

## Decision Engine

The broker selects the optimal provider in three steps:

1. **Filter** -- Exclude clusters that: are the requester itself, are inactive/stale, or have insufficient available resources
2. **Score** -- Rank candidates by projected post-reservation headroom:
   ```
   Score = (1 - 0.5 * CPU_utilization) + (1 - 0.5 * Memory_utilization)
   ```
   Higher score = more remaining capacity after fulfilling the request
3. **Select** -- Choose the highest-scoring cluster and atomically lock resources via `RetryOnConflict`

## Resource Locking

When a provider is selected, the broker increments the `Reserved` field in the provider's `ClusterAdvertisement` using Kubernetes optimistic concurrency (`RetryOnConflict`). Subsequent decisions see the reduced availability, preventing double-booking. When agents publish new advertisements, the handler preserves the `Reserved` field to avoid accidentally unlocking resources.

## CRDs

| CRD | Cluster | Description |
|-----|---------|-------------|
| `ClusterAdvertisement` | Broker | Stores each agent's resources: Capacity, Allocatable, Allocated, Reserved, Available |
| `Reservation` | Broker | Reservation lifecycle: Pending -> Reserved -> Active -> Released (or Failed) |

## Authentication

All endpoints (except `/healthz`) require mTLS. The cluster identity is extracted from the client certificate's Common Name (CN):

```
Agent certificate CN: "agent-cluster-1"
  → Broker identifies caller as "agent-cluster-1"
  → POST /advertisements validates CN matches the advertised clusterID
  → GET /instructions returns only instructions for this cluster
```

## Quick Start

```bash
# Install CRDs
make install

# Run broker
./bin/broker \
  --broker-interface=http \
  --http-port=8443 \
  --http-cert-path=/path/to/certs
```

## Project Structure

```
liqo-resource-broker/
├── api/v1alpha1/              # CRD type definitions
│   ├── clusteradvertisement_types.go
│   └── reservation_types.go
├── cmd/main.go                # Entry point, flag parsing, server startup
├── internal/
│   ├── api/
│   │   ├── server.go          # TLS server setup and route registration
│   │   ├── handlers/          # POST/GET handlers for each endpoint
│   │   └── middleware/        # mTLS authentication, logging
│   ├── broker/
│   │   └── decision.go        # Decision engine (filter, score, select)
│   ├── controller/
│   │   └── reservation_controller.go  # Reconciler for Reservation lifecycle
│   └── resource/
│       └── availability.go    # Available = Allocatable - Allocated - Reserved
└── config/
    ├── crd/                   # Generated CRD YAML manifests
    └── certmanager/           # Certificate and Issuer definitions
```
