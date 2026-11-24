# Terraform

## Tenant module (Milestone 3)

`modules/tenant` provisions a tenant namespace with a resource quota, limit
range, default-deny NetworkPolicy, workload service account, and a metadata
ConfigMap. The `environments/lab` root configuration applies it authoritatively
for both lab tenants (`trading` and `market-data`) against the running cluster:

```bash
make tenant-apply
# or directly:
terraform -chdir=terraform/environments/lab init -input=false
terraform -chdir=terraform/environments/lab apply \
  -var "kubeconfig_path=$HOME/.kube/config"
```

The `kubernetes` provider reads the cluster kubeconfig via `var.kubeconfig_path`
(default `~/.kube/config`). `terraform validate` runs offline in CI without a
cluster.

The remaining modules (`observability-stack`, `semantic-index`, `dashboards`,
`alert-rules`) are documented stubs for later milestones.
