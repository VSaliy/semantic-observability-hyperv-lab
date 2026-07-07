#!/usr/bin/env bash
# Bootstrap the Milestone 3 Kubernetes platform end to end:
#   1. Node baseline: containerd + kubeadm prerequisites + admin tools (Ansible site.yml).
#   2. kubeadm control plane + workers, Cilium CNI, and platform add-ons (Ansible cluster.yml).
#   3. Declarative platform and security manifests (kubectl).
#   4. Tenant provisioning (Terraform tenant module).
#
# Prerequisites: the Milestone 2 nodes are provisioned and reachable, and the
# ansible-playbook, kubectl, and terraform binaries are on PATH. Run from the
# repository root or anywhere; paths are resolved relative to this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_PATH="${INVENTORY_PATH:-${ANSIBLE_DIR}/inventories/lab/hosts.yml}"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
TENANT_ENV="${REPO_ROOT}/terraform/environments/lab"

echo "==> Applying node baseline (containerd, kubeadm prerequisites, admin tools)"
ansible-playbook -i "${INVENTORY_PATH}" \
  "${ANSIBLE_DIR}/playbooks/site.yml"

echo "==> Bootstrapping kubeadm cluster, Cilium, and platform add-ons"
ansible-playbook -i "${INVENTORY_PATH}" \
  "${ANSIBLE_DIR}/playbooks/cluster.yml"

echo "==> Reconciling declarative platform and security manifests"
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${REPO_ROOT}/kubernetes/platform"
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${REPO_ROOT}/kubernetes/security"

echo "==> Provisioning tenants with Terraform (authoritative tenant path)"
terraform -chdir="${TENANT_ENV}" init -input=false
terraform -chdir="${TENANT_ENV}" apply -auto-approve \
  -var "kubeconfig_path=${KUBECONFIG_PATH}"

echo "==> Milestone 3 platform bootstrap complete"
