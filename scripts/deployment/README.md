# deployment

Scripts in this folder support the milestone-specific workflows described by the root Makefile.

## `bootstrap-cluster.sh` (Milestone 3)

End-to-end Kubernetes platform bootstrap once the Milestone 2 nodes are
provisioned and reachable:

1. Runs `ansible/playbooks/site.yml` to apply the node baseline (containerd,
   kubeadm prerequisites, admin tools).
2. Runs `ansible/playbooks/cluster.yml` to `kubeadm init` the control plane,
   join the workers, install the Cilium CNI, and install the platform add-ons
   (MetalLB, cert-manager, ingress-nginx, local-path storage).
3. Reconciles the declarative manifests under `kubernetes/platform` and
   `kubernetes/security` with `kubectl apply`.
4. Applies the Terraform tenant module (`terraform/environments/lab`) to
   provision the `trading` and `market-data` tenants.

```bash
export KUBECONFIG="$HOME/.kube/config"   # kubeconfig for the lab cluster
# Optional: override the inventory used for both playbooks.
# export INVENTORY_PATH="$PWD/ansible/inventories/lab/hosts.yml"
./scripts/deployment/bootstrap-cluster.sh
```

Every step is idempotent (baseline tasks, init, join, and Helm installs are
guarded), so the script can be re-run safely to converge the cluster.

> Tip: from the Hyper-V host, `scripts/bootstrap/Start-LabProvisioning.ps1`
> provisions the VMs and then invokes this script for a single-command lab
> bring-up.

