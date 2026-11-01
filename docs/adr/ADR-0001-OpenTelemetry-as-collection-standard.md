# ADR-0001 OpenTelemetry as collection standard

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

OpenTelemetry provides vendor-neutral collection, enrichment, and routing across metrics, logs, traces, and events while keeping the lab portable between Docker Compose, Hyper-V, and Kubernetes.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
