# ADR-0006 Docker Compose development versus Kubernetes target

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

Milestone 1 uses Docker Compose for a fast local loop while keeping contracts and manifests aligned with the later Kubernetes target.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
