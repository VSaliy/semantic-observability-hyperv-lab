# Ansible automation (Milestones 2 and 3)

Idempotent Linux and admin-tooling configuration for the Hyper-V lab guests
(Milestone 2), plus the kubeadm cluster bootstrap and platform add-on
installation that turns those nodes into a Kubernetes cluster (Milestone 3).

## Layout

```text
ansible/
  ansible.cfg              # inventory, roles_path, sudo defaults
  requirements.yml         # community.general, ansible.posix collections
  group_vars/
    all.yml                # timezone, swap, kernel modules, pinned versions
    kubernetes.yml         # pod/service CIDRs, control-plane endpoint, add-on versions, MetalLB pool
  inventories/lab/hosts.yml  # kubernetes -> control_plane + workers subgroups
  playbooks/
    site.yml               # baseline (all) -> containerd + k8s prereqs -> admin tools
    validate.yml           # time-sync validation
    cluster.yml            # kubeadm control plane -> worker join -> platform add-ons
  roles/
    baseline/              # timezone, base packages, chrony, /etc/hosts
    containerd/            # modules, sysctl, containerd + SystemdCgroup=true
    kubernetes-prerequisites/  # swap off, pkgs.k8s.io repo, pinned kubeadm/kubelet/kubectl
    admin-tools/           # pinned Helm + jq/git/make (admin host only)
    time-sync-validation/  # asserts NTP synchronization
    kubeadm-control-plane/ # kubeadm init, kubeconfig, Helm, Cilium CNI, join command
    kubeadm-worker/        # kubeadm join using the published join command
    platform-addons/       # MetalLB, cert-manager, ingress-nginx, local-path storage
```

## Play targeting

`site.yml` runs three plays so work lands on the right hosts:

1. `baseline` on **all** hosts.
2. `containerd` + `kubernetes-prerequisites` on the **kubernetes** group.
3. `admin-tools` on the **admin** group.

`cluster.yml` runs three ordered plays for the Milestone 3 bootstrap:

1. `kubeadm-control-plane` on **control_plane** (`kubeadm init`, Cilium, publish the join command).
2. `kubeadm-worker` on **workers** (`kubeadm join` using the control-plane fact).
3. `platform-addons` on **control_plane** (MetalLB, cert-manager, ingress-nginx, storage).

## Usage

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# Preview (see check-mode notes in tests/README.md).
ansible-playbook playbooks/site.yml --check --diff

# Apply the node baseline.
ansible-playbook playbooks/site.yml

# Validate time synchronization.
ansible-playbook playbooks/validate.yml

# Bootstrap the Kubernetes cluster and platform add-ons (Milestone 3).
ansible-playbook playbooks/cluster.yml
```

The inventory can be regenerated from the Hyper-V configuration with
`Get-LabAnsibleInventory` so host addressing stays consistent with
`hyperv/config/lab-config.yaml`.

## Versions

Pinned component versions in `group_vars/all.yml` mirror the root
`versions.yaml` catalogue (Kubernetes 1.31.1, containerd 1.7.22, Helm 3.16.2).
Milestone 3 add-on versions live in `group_vars/kubernetes.yml` (Cilium 1.16.1,
MetalLB 0.14.8, ingress-nginx controller 1.11.3 / chart 4.11.3, cert-manager
1.16.1).
