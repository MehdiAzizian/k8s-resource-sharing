# Liqo Resource Sharing

Multi-cluster Kubernetes resource sharing system with centralized brokerage.

## Overview

This project enables Kubernetes clusters to share resources through a central broker. Clusters advertise their available resources, and the broker coordinates reservations between requesters and providers.

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│   Cluster A     │         │     Broker      │         │   Cluster B     │
│   (Requester)   │         │                 │         │   (Provider)    │
│                 │         │                 │         │                 │
│  Agent ────────────────►  REST API         │         │                 │
│  - Publish adv  │  mTLS   │  - Collect ads  │  mTLS   │  ◄──────── Agent│
│  - Get instruct │         │  - Match reqs   │         │  - Publish adv  │
│                 │         │  - Lock resources         │  - Get instruct │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

## Components

| Component | Description |
|-----------|-------------|
| [liqo-resource-broker](./liqo-resource-broker/) | Central broker that collects advertisements and processes reservations |
| [liqo-resource-agent](./liqo-resource-agent/) | Agent deployed in each cluster to report resources and receive instructions |
| [test-setup](./test-setup/) | Scripts to test with Kind clusters |

## Key Features

- **Centralized Coordination** - Single broker manages all cluster advertisements
- **mTLS Security** - All communication authenticated via certificates
- **Race Condition Prevention** - Reserved field prevents double-booking
- **Scoring Algorithm** - Selects best provider based on available resources

## How It Works

1. **Agents publish advertisements** - Each cluster reports its available CPU/memory
2. **User creates reservation** - Requests resources (e.g., 500m CPU, 1Gi memory)
3. **Broker selects provider** - Decision engine picks best cluster
4. **Resources are locked** - Reserved field updated to prevent conflicts
5. **Instructions delivered** - Both requester and provider receive instructions

## Quick Start

```bash
cd test-setup/scripts

# Setup Kind clusters
./setup-clusters.sh
./setup-certmanager.sh
./extract-certs.sh

# Run components (3 terminals)
./run-broker.sh      # Terminal 1
./run-agent-1.sh     # Terminal 2
./run-agent-2.sh     # Terminal 3

# Test (4th terminal)
./test-reservation.sh
```

See [test-setup/README.md](./test-setup/README.md) for detailed instructions.

## Resource Formula

```
Available = Allocatable - Allocated - Reserved

Where:
- Allocatable = Total node resources for pods
- Allocated   = Sum of running pod requests
- Reserved    = Resources locked by broker
```

## Technology Stack

- Go 1.21
- controller-runtime / Kubebuilder
- cert-manager for mTLS
- Kind for local testing

## Project Context

Developed as part of the FLUIDOS EU project, extending Liqo multi-cluster capabilities with centralized resource brokerage.

## Note

In production, broker and agent would be separate repositories. They are combined here for easier testing and evaluation.

## License

Apache 2.0
