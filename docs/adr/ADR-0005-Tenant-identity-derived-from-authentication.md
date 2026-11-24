# ADR-0005 Tenant identity derived from authentication

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

The query API ignores client-supplied tenant data and derives tenant scope only from authenticated claims to prevent cross-tenant leakage.

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
