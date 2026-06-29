#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "k3s already running, skipping install"
else
  # --flannel-backend=none      : no built-in CNI; Cilium provides the dataplane
  # --disable-kube-proxy        : Cilium runs in full kube-proxy replacement mode (eBPF)
  # --disable-network-policy    : Cilium owns network policies
  # --disable traefik/servicelb/local-storage : not needed, avoids conflicts with cluster add-ons
  curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik \
    --disable servicelb \
    --disable local-storage \
    --flannel-backend=none \
    --disable-network-policy \
    --disable-kube-proxy

  echo "k3s installed"
fi

# Export kubeconfig to repo-local .kube/config (matches KUBECONFIG in .mise.toml)
mkdir -p "${REPO_ROOT}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${REPO_ROOT}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${REPO_ROOT}/.kube/config"
chmod 600 "${REPO_ROOT}/.kube/config"
echo "Kubeconfig written to ${REPO_ROOT}/.kube/config"
