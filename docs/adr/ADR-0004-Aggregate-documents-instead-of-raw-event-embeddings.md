# ADR-0004 Aggregate documents instead of raw-event embeddings

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

The indexer generates document-level summaries so search stays grounded, cheaper, and less noisy than embedding every raw line.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
