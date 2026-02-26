# Liqo Resource Agent

Per-cluster agent for multi-cluster Kubernetes resource sharing. The agent monitors local resources, publishes advertisements to the central broker, handles reservation requests from users, and automatically establishes Liqo peering with provider clusters.

## How It Works

The agent performs four main functions:

1. **Resource monitoring** -- Collects CPU, memory, and GPU metrics from local nodes and pods, computing `Available = Allocatable - Allocated - Reserved`
2. **Advertisement publishing** -- Sends resource metrics to the broker every 30 s via `POST /api/v1/advertisements`, preserving the broker's `Reserved` field
3. **Synchronous reservations** -- When a user creates a `ResourceRequest` CRD, the agent sends `POST /api/v1/reservations` and receives the decision instantly in the HTTP response
4. **Instruction polling** -- Polls `GET /api/v1/instructions` every 5 s to discover `ProviderInstruction` objects when this cluster is selected as a provider

## Reservation Flow

```
 User                 Agent                          Broker
  │                     │                               │
  │  kubectl apply      │                               │
  │  ResourceRequest    │                               │
  │ ──────────────────► │                               │
  │                     │  POST /api/v1/reservations    │
  │                     │ ────────────────────────────► │
  │                     │                               │── decide, lock
  │                     │  HTTP 200 + instruction       │
  │                     │ ◄──────────────────────────── │
  │                     │                               │
  │                     │── Create ReservationInstr.    │
  │                     │── Update ResourceRequest      │
  │                     │   status → "Reserved"         │
  │                     │                               │
  │                     │── liqoctl peer (automatic)    │
  │                     │── Virtual Node created        │
```

## CRDs

| CRD | Purpose |
|-----|---------|
| `Advertisement` | Local representation of cluster resources, published to broker |
| `ResourceRequest` | **User-facing.** Created by users to trigger a reservation (specifies CPU, memory, priority) |
| `ReservationInstruction` | Created by agent after successful reservation. Contains target provider info. Triggers Liqo peering |
| `ProviderInstruction` | Created by agent when this cluster is selected as provider. Tracks reserved resources for others |

### ResourceRequest (user creates this)

```yaml
apiVersion: liqo.io/v1alpha1
kind: ResourceRequest
metadata:
  name: my-request
spec:
  cpu: "500m"
  memory: "256Mi"
  priority: 10
# Status is updated by the agent:
#   status.phase: Reserved
#   status.targetClusterID: agent-cluster-2
#   status.reservationName: res-abc123
```

## BrokerCommunicator Interface

The agent communicates with the broker through a protocol-agnostic interface:

```go
type BrokerCommunicator interface {
    PublishAdvertisement(ctx context.Context,
        adv *dto.AdvertisementDTO) error
    RequestReservation(ctx context.Context,
        req *dto.ReservationRequestDTO) (*dto.ReservationDTO, error)
    FetchInstructions(ctx context.Context) (
        []*dto.ReservationDTO, error)
    Ping(ctx context.Context) error
    Close() error
}
```

- `PublishAdvertisement` -- `POST /api/v1/advertisements` (preserves `Reserved` field)
- `RequestReservation` -- `POST /api/v1/reservations` (synchronous, returns decision inline)
- `FetchInstructions` -- `GET /api/v1/instructions` (provider polling, every 5 s)

This interface allows adding new transport protocols (MQTT, gRPC) without changing the controllers.

## Controllers

| Controller | Watches | Action |
|-----------|---------|--------|
| `AdvertisementReconciler` | `Advertisement` | Collects local metrics, publishes to broker every 30 s |
| `ResourceRequestReconciler` | `ResourceRequest` | Sends synchronous `POST /reservations`, creates `ReservationInstruction` |
| `ReservationInstructionReconciler` | `ReservationInstruction` | Triggers `liqoctl peer` to establish Liqo peering with provider |
| `ProviderInstructionReconciler` | `ProviderInstruction` | Marks instruction as enforced, included in resource calculation |
| `InstructionPoller` | (background) | Polls `GET /instructions` every 5 s for provider instructions |

## Resource Calculation

```
Available = Allocatable - Allocated - Reserved

Where:
  Allocatable = Sum of ready nodes' allocatable resources
  Allocated   = Sum of all pod resource requests (max of init containers, not sum)
  Reserved    = Sum of enforced, non-expired ProviderInstruction resources
```

## Authentication

The agent uses mTLS with the broker. The cluster identity equals the certificate Common Name:

```
Certificate CN: "agent-cluster-1"
  → Broker identifies this agent as "agent-cluster-1"
  → Advertisements are validated against this identity
```

## Quick Start

```bash
# Install CRDs
make install

# Run agent
./bin/agent \
  --broker-transport=http \
  --broker-url=https://broker:8443 \
  --broker-cert-path=/path/to/certs \
  --cluster-id=my-cluster \
  --kubeconfigs-dir=/path/to/kubeconfigs    # enables Liqo peering
  --advertisement-requeue-interval=30s      # publish frequency
  --instruction-poll-interval=5s            # provider poll frequency
```

The `--kubeconfigs-dir` flag enables automatic Liqo peering. The directory should contain files named `<cluster-id>.kubeconfig`. If omitted, Liqo peering is skipped and instructions are marked as delivered immediately.

## Project Structure

```
liqo-resource-agent/
├── api/v1alpha1/                  # CRD type definitions
│   ├── advertisement_types.go
│   ├── resourcerequest_types.go        # User-facing reservation trigger
│   ├── reservationinstruction_types.go
│   └── providerinstruction_types.go
├── cmd/main.go                    # Entry point, flag parsing, controller setup
├── internal/
│   ├── controller/
│   │   ├── advertisement_controller.go       # Publishes advertisements
│   │   ├── resourcerequest_controller.go     # Synchronous reservation flow
│   │   ├── reservationinstruction_controller.go  # Liqo peering trigger
│   │   ├── providerinstruction_controller.go # Provider-side handling
│   │   └── instruction_poller.go             # Polls GET /instructions every 5s
│   ├── metrics/
│   │   └── collector.go           # Node/pod resource collection
│   ├── publisher/
│   │   └── broker_client.go       # Legacy Kubernetes CRD transport
│   └── transport/
│       ├── interface.go           # BrokerCommunicator interface
│       └── http/
│           └── client.go          # mTLS HTTP client with retry logic
└── config/
    └── crd/                       # Generated CRD YAML manifests
```
