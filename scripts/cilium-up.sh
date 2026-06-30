#!/usr/bin/env bash
# cilium-up.sh – Cilium imperativ installieren (vor flux-bootstrap)
# Ohne CNI bleiben alle Pods Pending – auch Flux selbst.
# Nach dem Bootstrap übernimmt Flux die HelmRelease per Adoption
# (gleicher Release-Name "cilium" im Namespace "kube-system").
# Verwendung: mise run cilium-up -- <local|pi>
set -euo pipefail

CLUSTER="${1:?Fehler: Cluster angeben – z.B.: mise run cilium-up -- local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${CLUSTER}" in
  local|pi) ;;
  *) printf "Unbekannter Cluster '%s'. Erlaubt: local | pi\n" "${CLUSTER}" >&2; exit 1 ;;
esac

if [[ "${CLUSTER}" == "local" ]]; then
  export KUBECONFIG="${REPO_ROOT}/.kube/config"
  [[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run cluster-up -- local"; exit 1; }

  if cilium status &>/dev/null; then
    echo "Cilium bereits installiert – übersprungen"
  else
    cilium install \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost="k3d-local-server-0" \
      --set k8sServicePort=6443

    cilium status --wait
    echo "Cilium bereit"
  fi
fi

if [[ "${CLUSTER}" == "pi" ]]; then
  export KUBECONFIG="${REPO_ROOT}/.kube/pi-config"
  [[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run cluster-up -- pi"; exit 1; }

  # shellcheck source=/dev/null
  source "${REPO_ROOT}/clusters/pi/nodes.env"
  [[ -z "${PI_SERVER:-}" ]] && { echo "Fehler: PI_SERVER nicht gesetzt in clusters/pi/nodes.env"; exit 1; }

  if cilium status &>/dev/null; then
    echo "Cilium bereits installiert – übersprungen"
  else
    cilium install \
      --set kubeProxyReplacement=true \
      --set k8sServiceHost="${PI_SERVER}" \
      --set k8sServicePort=6443

    cilium status --wait
    echo "Cilium bereit"
  fi
fi
