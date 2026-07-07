# deployment

Scripts in this folder support the milestone-specific workflows described by the root Makefile.

## `bootstrap-cluster.sh` (Milestone 3)

End-to-end Kubernetes platform bootstrap once the Milestone 2 nodes are
provisioned and reachable:

1. Runs `ansible/playbooks/cluster.yml` to `kubeadm init` the control plane,
   join the workers, install the Cilium CNI, and install the platform add-ons
   (MetalLB, cert-manager, ingress-nginx, local-path storage).
2. Reconciles the declarative manifests under `kubernetes/platform` and
   `kubernetes/security` with `kubectl apply`.
3. Applies the Terraform tenant module (`terraform/environments/lab`) to
   provision the `trading` and `market-data` tenants.

```bash
export KUBECONFIG="$HOME/.kube/config"   # kubeconfig for the lab cluster
./scripts/deployment/bootstrap-cluster.sh
```

The Ansible step is idempotent (init, join, and Helm installs are guarded), so
the script can be re-run safely to converge the cluster.

