# Multi-Cluster Kubernetes Resource Sharing

A centralized resource brokerage system that enables Kubernetes clusters to share CPU, memory, and GPU resources. A central broker collects real-time resource advertisements from all clusters, processes reservation requests through a scoring-based decision engine, and automatically establishes cluster peering via Liqo.

## Architecture

```
 Requester Cluster              Broker Cluster              Provider Cluster
┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐
│  Agent            │  mTLS   │  REST API (mTLS) │  mTLS   │           Agent  │
│  ┌──────────────┐│         │  ┌──────────────┐│         │┌──────────────┐  │
│  │Metrics       ││────────►│  │ClusterAdverts ││◄────────││Metrics       │  │
│  │Collector     ││ publish │  │              ││ publish ││Collector     │  │
│  └──────────────┘│ every   │  ├──────────────┤│ every   │└──────────────┘  │
│                  │  30s    │  │Decision      ││  30s    │                  │
│  ┌──────────────┐│         │  │Engine        ││         │┌──────────────┐  │
│  │ResourceReq.  ││────────►│  └──────────────┘│         ││Provider      │  │
│  │(user creates)││  POST   │         │        │         ││Instruction   │  │
│  └──────────────┘│ /reser- │         │        │         │└──────┬───────┘  │
│         │        │ vations │         ▼        │         │       │          │
│         ▼        │         │  ┌──────────────┐│  GET    │       │(polls    │
│  ┌──────────────┐│◄────────│  │Reservations  ││◄────────│  every 5s)      │
│  │Reservation   ││ instant │  │+ Instructions││ /instr. │                  │
│  │Instruction   ││ (in HTTP│  └──────────────┘│         │                  │
│  └──────┬───────┘│ response│                  │         │                  │
│         │        │    )    │                  │         │                  │
│         ▼        │         │                  │         │                  │
│  ┌──────────────┐│         │                  │         │                  │
│  │Liqo Peering  │╞═══════════════WireGuard═══════════════╡                  │
│  │Virtual Node  ││         │                  │         │                  │
│  └──────────────┘│         │                  │         │                  │
└──────────────────┘         └──────────────────┘         └──────────────────┘
```

## Components

| Component | Description |
|-----------|-------------|
| [liqo-resource-broker](./liqo-resource-broker/) | Central broker: collects advertisements, runs decision engine, manages reservations |
| [liqo-resource-agent](./liqo-resource-agent/) | Per-cluster agent: monitors resources, publishes advertisements, handles instructions |
| [test-setup](./test-setup/) | Kind-based multi-cluster test environment with setup scripts |
| [tests/evaluation](./tests/evaluation/) | Automated evaluation suite (7 tests) with results and charts |

## Reservation Flow

1. **Agents publish advertisements** every 30 s -- each cluster reports its available CPU, memory, and GPU to the broker via `POST /api/v1/advertisements`
2. **User creates a ResourceRequest** on the requester cluster -- specifying desired CPU and memory (e.g., `500m`, `256Mi`)
3. **Agent sends synchronous reservation** -- `POST /api/v1/reservations` to the broker
4. **Broker decides inline** -- the decision engine selects the best provider, locks resources via the `Reserved` field, and returns the result in the HTTP response
5. **Requester gets instruction instantly** -- the `ReservationInstruction` is embedded in the HTTP response (sub-second)
6. **Provider discovers instruction by polling** -- `GET /api/v1/instructions` every 5 s returns the `ProviderInstruction`
7. **Liqo peering established** -- the requester agent automatically runs `liqoctl peer` to create a virtual node backed by the provider's resources

## Key Features

- **Synchronous Reservations** -- requester receives its instruction in the HTTP response (sub-second end-to-end)
- **mTLS Security** -- cluster identity derived from certificate Common Name, managed by cert-manager
- **Race Condition Prevention** -- `Reserved` field atomically locks resources before confirming reservations
- **Scoring-Based Decision Engine** -- selects provider with most remaining headroom after fulfillment
- **Automatic Liqo Peering** -- agent triggers `liqoctl peer` to create virtual nodes and WireGuard tunnels
- **Lightweight Agent** -- ~40 MB memory, ~0.3% CPU per agent
- **Protocol Extensibility** -- `BrokerCommunicator` interface supports adding MQTT, gRPC, etc.

## Resource Formula

```
Available = Allocatable - Allocated - Reserved

Where:
  Allocatable = Total node capacity minus OS/system reservations
  Allocated   = Sum of all running pod resource requests
  Reserved    = Resources locked by broker for pending reservations
```

## Quick Start

```bash
cd test-setup/scripts

# Setup Kind clusters (1 broker + 2 agents)
./setup-clusters.sh
./setup-certmanager.sh
./extract-certs.sh

# Run components (3 terminals)
./run-broker.sh      # Terminal 1
./run-agent-1.sh     # Terminal 2
./run-agent-2.sh     # Terminal 3

# Test reservation (4th terminal)
./test-reservation.sh
```

See [test-setup/README.md](./test-setup/README.md) for detailed instructions.

## Technology Stack

| Technology | Version | Purpose |
|-----------|---------|---------|
| Go | 1.24 | Primary language |
| controller-runtime | 0.22 | Kubernetes operator framework |
| Kubebuilder | 4.x | CRD scaffolding |
| cert-manager | 1.x | Certificate lifecycle management |
| Kind | 0.20+ | Local multi-cluster testing |
| Liqo | latest | Cluster peering and virtual nodes |

## Evaluation Results

Tested on a 96-core, 503 GB RAM server with Kind clusters. Key results:

| Test | Result |
|------|--------|
| Broker CPU (100 agents) | ~27% single-core, linear to 40 agents then plateau |
| Broker memory | Constant ~40 MB regardless of agent count |
| Reservation latency | ~433 ms broker decision, ~526 ms requester delivery |
| Concurrent (10 requests) | ~795 ms median, 0 timeouts, 0 double-bookings |
| Agent footprint | ~0.3% CPU, ~40 MB RAM |
| Agent startup (warm) | 1-4 s (certificate generation dominates) |

See [tests/evaluation/results/](./tests/evaluation/results/) for full results, charts, and methodology.

## Project Context

Developed as a master thesis project at Politecnico di Torino, extending Liqo multi-cluster capabilities with centralized resource brokerage. Related to the FLUIDOS EU project.

## License

Apache 2.0
