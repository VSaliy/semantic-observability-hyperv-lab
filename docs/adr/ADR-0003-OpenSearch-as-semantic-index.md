# ADR-0003 OpenSearch as semantic index

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

OpenSearch offers vector, keyword, and filtered search in a single local-first stack without a commercial dependency.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
