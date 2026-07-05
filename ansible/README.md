# Ansible automation (Milestone 2)

Idempotent Linux and admin-tooling configuration for the Hyper-V lab guests.
These roles prepare the nodes that the Milestone 3 kubeadm bootstrap will turn
into a Kubernetes cluster.

## Layout

```text
ansible/
  ansible.cfg              # inventory, roles_path, sudo defaults
  requirements.yml         # community.general, ansible.posix collections
  group_vars/
    all.yml                # timezone, swap, kernel modules, pinned versions
    kubernetes.yml         # pod CIDR and control-plane host (reserved for M3)
  inventories/lab/hosts.yml
  playbooks/
    site.yml               # baseline (all) -> containerd + k8s prereqs -> admin tools
    validate.yml           # time-sync validation
  roles/
    baseline/              # timezone, base packages, chrony, /etc/hosts
    containerd/            # modules, sysctl, containerd + SystemdCgroup=true
    kubernetes-prerequisites/  # swap off, pkgs.k8s.io repo, pinned kubeadm/kubelet/kubectl
    admin-tools/           # pinned Helm + jq/git/make (admin host only)
    time-sync-validation/  # asserts NTP synchronization
```

## Play targeting

`site.yml` runs three plays so work lands on the right hosts:

1. `baseline` on **all** hosts.
2. `containerd` + `kubernetes-prerequisites` on the **kubernetes** group.
3. `admin-tools` on the **admin** group.

## Usage

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# Preview (see check-mode notes in tests/README.md).
ansible-playbook playbooks/site.yml --check --diff

# Apply.
ansible-playbook playbooks/site.yml

# Validate time synchronization.
ansible-playbook playbooks/validate.yml
```

The inventory can be regenerated from the Hyper-V configuration with
`Get-LabAnsibleInventory` so host addressing stays consistent with
`hyperv/config/lab-config.yaml`.

## Versions

Pinned component versions in `group_vars/all.yml` mirror the root
`versions.yaml` catalogue (Kubernetes 1.31.1, containerd 1.7.22, Helm 3.16.2).
