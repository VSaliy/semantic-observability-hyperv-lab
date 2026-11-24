# ADR-0007 Embedding-provider abstraction

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

Embedding calls are hidden behind a provider interface so the lab can swap deterministic local embeddings for pinned models later without changing business logic.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
