# Kubernetes platform (Milestone 3)

Declarative manifests for the kubeadm-based lab cluster. The cluster itself,
the Cilium CNI, and the platform add-ons are installed by the Ansible roles
under `ansible/` (`playbooks/cluster.yml`); the manifests here are the
GitOps-ready, CI-validated source of truth that mirrors what the automation
applies.

## Layout

| Path | Contents |
| --- | --- |
| `platform/namespaces.yaml` | Shared `platform-*` namespaces (tenant namespaces are Terraform-owned). |
| `platform/governance.yaml` | PriorityClass and the node-pinned `local-path-observability` StorageClass. |
| `platform/metallb-pool.yaml` | MetalLB `IPAddressPool` + `L2Advertisement` (10.50.0.240-250). |
| `platform/ingress-example.yaml` | Reference Ingress using `ingressClassName: nginx` and the `lab-ca` issuer. |
| `platform/pdb-example.yaml` | PodDisruptionBudget example. |
| `security/network-baseline.yaml` | Default-deny NetworkPolicy baseline. |
| `security/cluster-issuers.yaml` | cert-manager self-signed root + `lab-ca` ClusterIssuer. |
| `tenants/trading-controls.yaml` | Illustrative tenant controls (Terraform is authoritative). |

## Platform add-ons

`ansible/playbooks/cluster.yml` installs the add-ons on the control-plane node
with pinned Helm charts (versions mirror `/versions.yaml`):

- **Cilium** — cluster CNI (cluster-pool IPAM over the `10.244.0.0/16` pod CIDR).
- **MetalLB** — layer-2 load balancer serving `10.50.0.240-10.50.0.250`.
- **ingress-nginx** — default `nginx` IngressClass exposed via a MetalLB `LoadBalancer`.
- **cert-manager** — self-signed root plus a `lab-ca` ClusterIssuer for lab TLS.
- **local-path-provisioner** — default dynamic `StorageClass` for workload volumes.

## Default storage classes

- `local-path` (default) — dynamic, node-local volumes from local-path-provisioner.
- `local-path-observability` — `no-provisioner` class for statically pinned volumes.

Validate the manifests locally with `make kubernetes-validate` (CI also runs `kubeval`).
