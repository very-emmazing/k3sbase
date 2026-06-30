#!/usr/bin/env bash
# flux-bootstrap.sh – Flux Operator + FluxInstance + SOPS-age-Secret
# Voraussetzung: Cilium läuft (mise run cilium-up -- <cluster>)
# Verwendung: mise run flux-bootstrap -- <local|pi>
set -euo pipefail

CLUSTER="${1:?Fehler: Cluster angeben – z.B.: mise run flux-bootstrap -- local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"

case "${CLUSTER}" in
  local|pi) ;;
  *) printf "Unbekannter Cluster '%s'. Erlaubt: local | pi\n" "${CLUSTER}" >&2; exit 1 ;;
esac

if [[ "${CLUSTER}" == "local" ]]; then
  export KUBECONFIG="${REPO_ROOT}/.kube/config"
  [[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run cluster-up -- local"; exit 1; }
fi

if [[ "${CLUSTER}" == "pi" ]]; then
  export KUBECONFIG="${REPO_ROOT}/.kube/pi-config"
  [[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run cluster-up -- pi"; exit 1; }

  # Sicherstellen dass cilium.yaml nicht mehr den Platzhalter enthält
  if grep -q 'REPLACE_WITH_PI_SERVER_IP' "${REPO_ROOT}/clusters/pi/infrastructure/cilium.yaml"; then
    echo "Fehler: k8sServiceHost in clusters/pi/infrastructure/cilium.yaml noch nicht gesetzt."
    echo "  mise run cluster-up -- pi ausführen und cilium.yaml danach committen."
    exit 1
  fi
fi

[[ -f "${AGE_KEY_FILE}" ]] || { echo "Fehler: age-Key fehlt – zuerst: mise run setup -- ${CLUSTER}"; exit 1; }

# ── Flux Operator ──────────────────────────────────────────────────────────────
# Imperativ einmalig installiert; danach selbst-verwaltet über die FluxInstance.
if helm status flux-operator -n flux-system &>/dev/null 2>&1; then
  echo "Flux Operator bereits installiert – übersprungen"
else
  helm upgrade --install flux-operator \
    oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --version 0.52.0 \
    --namespace flux-system \
    --create-namespace \
    --wait
fi

# ── FluxInstance ───────────────────────────────────────────────────────────────
kubectl apply -f "${REPO_ROOT}/clusters/${CLUSTER}/flux-system/flux-instance.yaml"

# ── SOPS age Secret ───────────────────────────────────────────────────────────
kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Flux Bootstrap abgeschlossen."
echo "Flux reconciliert jetzt clusters/${CLUSTER}/ aus dem Repo."
