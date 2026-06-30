#!/usr/bin/env bash
# bootstrap-pi-cilium.sh – Cilium imperativ auf dem Pi-Cluster installieren
# Muss vor pi-flux-bootstrap laufen: ohne CNI bleiben alle Pods Pending.
# Ausführen via: mise run pi-cilium-up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/.kube/pi-config"

[[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run pi-up"; exit 1; }

# shellcheck source=/dev/null
source "${REPO_ROOT}/clusters/pi/nodes.env"
[[ -z "${PI_SERVER:-}" ]] && { echo "Fehler: PI_SERVER nicht gesetzt in clusters/pi/nodes.env"; exit 1; }

# Nach dem Bootstrap übernimmt Flux die cilium HelmRelease per Adoption
# (gleicher Release-Name "cilium" im Namespace "kube-system").
if cilium status &>/dev/null 2>&1; then
  echo "Cilium bereits installiert – übersprungen"
else
  cilium install \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="${PI_SERVER}" \
    --set k8sServicePort=6443

  cilium status --wait
  echo "Cilium bereit"
fi
