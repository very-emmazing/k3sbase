#!/usr/bin/env bash
set -euo pipefail

# Cilium must be installed imperatively before Flux can run:
# without a CNI all pods (including Flux controllers) remain Pending.
# After flux-bootstrap, Flux adopts this release via the HelmRelease in
# clusters/local/infrastructure/cilium.yaml (same name "cilium", namespace "kube-system").

if cilium status &>/dev/null; then
  echo "Cilium already installed, skipping"
else
  cilium install \
    --set kubeProxyReplacement=true

  cilium status --wait
  echo "Cilium ready"
fi
