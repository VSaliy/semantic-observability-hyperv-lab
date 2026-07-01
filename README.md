# semantic-observability-hyperv-lab

Production-oriented hands-on lab for building an internal observability and event-intelligence platform on Windows 11 Pro with Hyper-V, while proving one runnable local vertical slice first.

## Purpose

The target platform helps answer: **Why are production trade requests intermittently failing after the latest change?**

Milestone 1 proves a grounded path from normalized operational events to tenant-scoped, evidence-linked search results:

```text
Synthetic operational event -> Kafka -> Semantic indexer -> OpenSearch -> Hybrid search API
```

The implementation does **not** use an LLM to invent causes. Search results remain grounded in indexed evidence.

## Architecture

- [System context](docs/architecture/system-context.md)
- [Container architecture](docs/architecture/container-architecture.md)
- [Telemetry flow](docs/architecture/telemetry-flow.md)
- [Semantic indexing](docs/architecture/semantic-indexing.md)
- [Search request flow](docs/architecture/search-request-flow.md)
- [Tenant onboarding](docs/architecture/tenant-onboarding.md)

## Current implementation status

| Milestone | Status | Notes |
| --- | --- | --- |
| 0 Foundation | Implemented | Repository structure, ADRs, docs, validation scripts, CI skeleton, version catalog. |
| 1 Runnable vertical slice | Implemented | Kafka, OpenSearch, deterministic embedding service, semantic indexer, query API, seed events, evaluation dataset, tenant isolation tests. |
| 2 Hyper-V and Linux automation | Foundation only | PowerShell module shape, cloud-init examples, Ansible baseline, and milestone notes. |
| 3 Kubernetes platform | Foundation only | Namespaces, quotas, policies, storage, and Terraform tenant module. |
| 4 Core observability | Planned | OTel, Prometheus, Alertmanager, Grafana, Loki, Tempo, MinIO. |

## Profiles

- `core-observability` - future Kubernetes deployment profile
- `semantic-search` - current local vertical slice
- `analytics-comparison` - planned optional backend comparison profile
- `service-mesh` - planned Istio profile
- `network-observability` - planned FRRouting and network event profile

## Host prerequisites

### Recommended host

- Windows 11 Pro
- 64 GB RAM
- 12+ logical cores
- 300 GB SSD
- Hyper-V enabled

### Reduced host

- Windows 11 Pro
- 32 GB RAM
- 8 logical cores
- 180 GB SSD

### Local Milestone 1 prerequisites

- Docker Engine with Docker Compose
- Python 3.12+
- Java 21 for local Maven builds
- GNU Make or PowerShell equivalents

## Repository structure

The repository follows the target layout described in the issue and ensures each created directory contains implementation, examples, tests, or precise milestone notes.

## Development quick start

```bash
make dev-up
make seed-events
TOKEN=$(./scripts/bootstrap/generate-dev-jwt.py)
curl -s http://localhost:8080/api/v1/search \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
        "query": "Why are production trade requests intermittently failing after the latest change?",
        "environment": "production",
        "timeRange": "PT2H",
        "topK": 5,
        "mode": "HYBRID"
      }' | jq
```

## Hyper-V bootstrap path

1. Validate Hyper-V host prerequisites with `hyperv/powershell/HyperVLab.psm1`.
2. Load VM configuration from `hyperv/config/lab-config.yaml`.
3. Use Ansible and cloud-init examples to prepare Linux guests.
4. Progressively move from Docker Compose to kubeadm-based deployment in later milestones.

## Security and tenant isolation

- Tenant identity is derived only from authenticated JWT claims.
- The search request payload never accepts `tenantId`.
- OpenSearch queries apply server-side tenant and time filters.
- Evidence URLs are validated against an allowlist.
- Sensitive fields are redacted before indexing or embedding.

## Test commands

```bash
make format
make test-unit
make test-integration
make validate
make evaluate-search
```

## Contribution guide

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Known limitations

- Java 21 is required locally for Maven builds; the default runner JDK may be older.
- The Milestone 1 embedding service is deterministic and local, not semantically rich.
- Hyper-V, kubeadm, Keycloak, and the full observability stack are documented foundations, not yet fully deployed.
- Search ranking is deliberately transparent and heuristic, not production-tuned.

## Roadmap

- Milestone 2: Hyper-V VM lifecycle automation, cloud-init, and Ansible execution path.
- Milestone 3: kubeadm cluster automation, Cilium, MetalLB, ingress, certificates, storage, and tenant Terraform application.
- Milestone 4: full core observability stack and Kafka-connected collectors.
- Later: network observability, ITSM integrations, Keycloak, Istio, ClickHouse, deployment health gates, cost controls, and capstone incident workflows.

## Portfolio outcomes

This lab demonstrates platform engineering, observability architecture, semantic search, deterministic incident analysis, Kubernetes foundations, and infrastructure automation without relying on commercial products for the core path.
