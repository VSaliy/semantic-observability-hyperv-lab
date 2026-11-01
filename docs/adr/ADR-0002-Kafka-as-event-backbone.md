# ADR-0002 Kafka as event backbone

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

Kafka provides ordered, replayable, multi-consumer transport for normalized operational events and dead-letter handling.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
