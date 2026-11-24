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
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/hyperv-lab.conf}"
TENANT_ENV="${REPO_ROOT}/terraform/environments/lab"
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-${ANSIBLE_DIR}/ansible.cfg}"

# Verify SSH authentication to every VM before changing any node.
ansible -i "${INVENTORY_PATH}" all -m ping

echo "==> Applying node baseline (containerd, kubeadm prerequisites, admin tools)"
ansible-playbook -i "${INVENTORY_PATH}" \
  "${ANSIBLE_DIR}/playbooks/site.yml"

echo "==> Bootstrapping kubeadm cluster, Cilium, and platform add-ons"
ansible-playbook -i "${INVENTORY_PATH}" \
  "${ANSIBLE_DIR}/playbooks/cluster.yml"

echo "==> Reconciling declarative platform and security manifests"
umask 077
private_dir=$(mktemp -d)
trap 'rm -f "$private_dir/admin.conf"; rmdir "$private_dir"' EXIT
ansible -i "${INVENTORY_PATH}" control_plane --become -m fetch \
  -a "src=/etc/kubernetes/admin.conf dest='$private_dir/admin.conf' flat=yes"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  # Refuse to apply manifests to an unrelated current context.
  trust_root() {
    kubectl --kubeconfig "$1" config view --raw --minify --flatten \
      -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
  }
  expected=$(trust_root "$private_dir/admin.conf")
  [[ -n $expected && $(trust_root "$KUBECONFIG_PATH") == "$expected" ]] || {
    echo "Kubeconfig does not identify the provisioned lab: $KUBECONFIG_PATH" >&2
    exit 1
  }
else
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  install -m 600 "$private_dir/admin.conf" "$KUBECONFIG_PATH"
fi
kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes k8s-cp1 k8s-worker1 k8s-worker2
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${REPO_ROOT}/kubernetes/platform"
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${REPO_ROOT}/kubernetes/security"

echo "==> Provisioning tenants with Terraform (authoritative tenant path)"
terraform -chdir="${TENANT_ENV}" init -input=false
terraform -chdir="${TENANT_ENV}" apply -auto-approve \
  -var "kubeconfig_path=${KUBECONFIG_PATH}"

echo "==> Milestone 3 platform bootstrap complete"
