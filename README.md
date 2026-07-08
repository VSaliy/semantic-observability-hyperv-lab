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
| 0 Foundation | Implemented | Repository structure, ADRs, docs, validation scripts, CI workflows, version catalog. |
| 1 Runnable vertical slice | Implemented | Kafka, OpenSearch, deterministic embedding service, semantic indexer, query API, seed events, evaluation dataset, tenant isolation tests. |
| 2 Hyper-V and Linux automation | Implemented | Hyper-V VM lifecycle module, cloud-init NoCloud seeding, and idempotent Ansible roles (baseline, containerd, kubeadm prerequisites, admin tools, time-sync validation). |
| 3 Kubernetes platform | Implemented | kubeadm control-plane and worker roles, Cilium CNI, MetalLB, ingress-nginx, cert-manager, default local-path storage, and the tenant Terraform module applied for both lab tenants. |
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

### One-touch provisioning (recommended)

From an **elevated** PowerShell session on the Hyper-V host, a single command runs
the whole flow: host readiness precheck -> provision switches/VMs + cloud-init/autoinstall
seeds -> start VMs -> wait for SSH -> regenerate the Ansible inventory -> bootstrap the
Kubernetes cluster, platform add-ons, and tenants:

```powershell
./scripts/bootstrap/Start-LabProvisioning.ps1 `
  -VhdRootPath 'C:\HyperV\VHDs' `
  -InstallIsoPath 'E:\ISO\ubuntu-24.04.3-live-server-amd64.iso' `
  -Autoinstall -BuildAutoinstallIso
```

Useful switches: `-SkipClusterBootstrap` (stop after the VMs are up and reachable),
`-Rebuild` (recreate VMs cleanly), `-DynamicMemory`, `-WhatIf`, and
`-ClusterBootstrapEngine wsl|bash`. The script is idempotent and can be re-run to converge.

Prerequisites for a hands-off run: the `powershell-yaml` module, `oscdimg.exe` (Windows ADK),
a gitignored `.env` for autoinstall credentials (see [hyperv/README.md](hyperv/README.md)), and
WSL/bash with `ansible-playbook`, `kubectl`, and `terraform` (plus a reachable kubeconfig) for
the cluster bootstrap stage.

### Manual stages

If you prefer to run each stage yourself:

1. Validate Hyper-V host prerequisites and load configuration with `hyperv/powershell/HyperVLab.psm1`.
2. Provision switches and VMs from `hyperv/config/lab-config.yaml` via `Invoke-LabProvisioning`, attaching cloud-init NoCloud seeds.
3. Apply the Linux baseline, containerd, and kubeadm prerequisites with the Ansible roles under `ansible/` (`ansible-playbook playbooks/site.yml`).
4. Bootstrap the cluster with `scripts/deployment/bootstrap-cluster.sh` (baseline -> `kubeadm init`, worker join, Cilium CNI, MetalLB, ingress-nginx, cert-manager, local-path storage, then the tenant Terraform module).

See [hyperv/README.md](hyperv/README.md) and [ansible/README.md](ansible/README.md) for the full Milestone 2 and Milestone 3 workflow.

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

Milestone 2 automation is validated separately:

```bash
# Hyper-V PowerShell module (pure functions, Hyper-V mocked)
pwsh -c "Invoke-Pester -Path ./hyperv/tests"

# Ansible roles and playbooks (Milestone 2 and Milestone 3)
cd ansible && ansible-lint playbooks/site.yml playbooks/validate.yml playbooks/cluster.yml
```

Milestone 3 cluster automation is applied against provisioned nodes with:

```bash
make cluster-up      # kubeadm init/join, Cilium, MetalLB, ingress, cert-manager, storage
make tenant-apply    # apply the tenant Terraform module to the running cluster
# or run the full end-to-end bootstrap (baseline -> cluster -> manifests -> tenants):
./scripts/deployment/bootstrap-cluster.sh
# or, from the Hyper-V host, the whole lab in one touch (elevated PowerShell):
make provision-all VHD_ROOT="C:\HyperV\VHDs" ISO="E:\ISO\ubuntu-24.04.3-live-server-amd64.iso"
```

## Contribution guide

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Known limitations

- Java 21 is required locally for Maven builds; the default runner JDK may be older.
- The Milestone 1 embedding service is deterministic and local, not semantically rich.
- Milestone 2 automation (Hyper-V module, cloud-init, Ansible roles) is implemented and unit-tested, but a running Hyper-V host is required to provision guests.
- Milestone 3 cluster automation (kubeadm roles, Cilium, MetalLB, ingress-nginx, cert-manager, storage, tenant Terraform) is implemented and statically validated (ansible-lint, kubeval, `terraform validate`), but applying it requires the provisioned Linux nodes; Keycloak and the full observability stack remain later milestones.
- Search ranking is deliberately transparent and heuristic, not production-tuned.

## Roadmap

- Milestone 4: full core observability stack (OTel, Prometheus, Alertmanager, Grafana, Loki, Tempo, MinIO) and Kafka-connected collectors.
- Later: network observability, ITSM integrations, Keycloak, Istio, ClickHouse, deployment health gates, cost controls, and capstone incident workflows.

## Portfolio outcomes

This lab demonstrates platform engineering, observability architecture, semantic search, deterministic incident analysis, Kubernetes foundations, and infrastructure automation without relying on commercial products for the core path.
