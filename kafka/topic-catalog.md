# Kafka topic catalog

| Topic | Implemented | Purpose | Key | Partitioning | Retention | Producer guarantees | Consumer group | Replay behavior | Schema | Classification | Expected volume |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `platform.telemetry-events` | Yes | Normalized operational events for semantic indexing | `eventId` | 3 partitions for event fan-in | Delete, 7 days | At-least-once | `semantic-indexer` | Replay allowed; idempotent document IDs tolerate redelivery | JSON Schema `operational-event.schema.json` | Internal operational metadata | Low in dev, bursty in incidents |
| `semantic.dead-letter` | Yes | Invalid or poison events for inspection | `tenantId` or `eventId` | 3 partitions | Delete, 14 days | At-least-once | Manual triage | Replay only after fix | Dead-letter envelope JSON | Internal operational metadata | Very low |
| `platform.alerts.raw` | Planned | Raw alert ingress | `alert fingerprint` | By alert source | TBD | At-least-once | Alert normalizer | Replay supported | TBD | Internal operational metadata | Medium |
| `platform.alerts.normalized` | Planned | Normalized alerts | `alert fingerprint` | By alert source | TBD | At-least-once | Semantic indexer | Replay supported | JSON Schema | Internal operational metadata | Medium |
| `platform.deployments` | Planned | Deployment and change events | `changeId` | By service/change | TBD | At-least-once | Correlation services | Replay supported | JSON Schema | Internal operational metadata | Low |
| `platform.changes` | Planned | Change management events | `changeId` | By change | TBD | At-least-once | Correlation services | Replay supported | JSON Schema | Internal operational metadata | Low |
| `platform.incidents` | Planned | Incident lifecycle | `incidentId` | By incident | TBD | At-least-once | Search and workflow consumers | Replay supported | JSON Schema | Internal operational metadata | Low |
| `platform.problems` | Planned | Problem records | `problemId` | By problem | TBD | At-least-once | Workflow consumers | Replay supported | JSON Schema | Internal operational metadata | Low |
| `semantic.documents` | Planned | Document fan-out after indexing | `documentId` | By tenant/document | Compact | At-least-once | Secondary processors | Replay supported | Semantic document schema | Internal operational metadata | Medium |
