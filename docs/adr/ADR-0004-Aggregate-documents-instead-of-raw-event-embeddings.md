# ADR-0004 Aggregate documents instead of raw-event embeddings

- Status: Accepted
- Date: 2026-07-01

## Context

Milestones 0 and 1 need a reproducible local slice with room to evolve into the Hyper-V and Kubernetes target architecture.

## Decision

The indexer generates document-level summaries so search stays grounded, cheaper, and less noisy than embedding every raw line.

Events merge into aggregates keyed by tenant, environment, document type and source identity (masked
log template per hour, trace ID, incident ID, change ID, alert name per hour). Each aggregate keeps a
compact record per contributing event and is rebuilt from that set, which makes merging idempotent and
independent of delivery order. Details: [semantic indexing](../architecture/semantic-indexing.md).

## Consequences

- The repository keeps local development practical.
- Later milestones can replace implementations without changing the operational contracts.
- Search returns one result per log template, trace, incident, change or alert, with occurrence counts
  and all original evidence links, instead of one result per raw event.
- Each write reads the aggregate first and uses optimistic concurrency; per-event records make large
  aggregates heavier, so contributions are capped (`max_contributions_per_aggregate`, default 100)
  while duplicate detection maintains a separate, larger bounded window of seen event IDs
  (`max_tracked_event_ids_per_aggregate`, default 1000) ensuring redeliveries within the last N events
  per aggregate are absorbed.
- Changing the identity rules changes document IDs, which requires a new index version and a replay.
