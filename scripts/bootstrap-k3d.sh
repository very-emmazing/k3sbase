#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="local"

if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER}"; then
  echo "k3d cluster '${CLUSTER}' already exists, skipping"
else
  # --flannel-backend=none      : no built-in CNI; Cilium provides the dataplane
  # --disable-kube-proxy        : Cilium runs in full kube-proxy replacement mode (eBPF)
  # --disable-network-policy    : Cilium owns network policies
  # --disable traefik/servicelb/local-storage : not needed, avoids conflicts
  # --no-lb                     : skip the k3d load-balancer container (not needed for local dev)
  k3d cluster create "${CLUSTER}" \
    --k3s-arg '--disable=traefik@server:*' \
    --k3s-arg '--disable=servicelb@server:*' \
    --k3s-arg '--disable=local-storage@server:*' \
    --k3s-arg '--flannel-backend=none@server:*' \
    --k3s-arg '--disable-network-policy@server:*' \
    --k3s-arg '--disable-kube-proxy@server:*' \
    --no-lb \
    --wait

  echo "k3d cluster '${CLUSTER}' created"
fi

mkdir -p "${REPO_ROOT}/.kube"
k3d kubeconfig get "${CLUSTER}" > "${REPO_ROOT}/.kube/config"
chmod 600 "${REPO_ROOT}/.kube/config"
echo "Kubeconfig written to ${REPO_ROOT}/.kube/config"
