#!/usr/bin/env bash
# bootstrap-pi-flux.sh – Flux Operator auf dem Pi-Cluster bootstrappen
# Voraussetzung: Cilium läuft (mise run pi-cilium-up), cilium.yaml committed.
# Ausführen via: mise run pi-flux-bootstrap
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/.kube/pi-config"
CLUSTER="pi"
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"

[[ -f "${KUBECONFIG}" ]] || { echo "Fehler: ${KUBECONFIG} fehlt – zuerst: mise run pi-up"; exit 1; }
[[ -f "${AGE_KEY_FILE}" ]] || { echo "Fehler: age-Key fehlt – zuerst: mise run setup"; exit 1; }

# Prüfen ob k8sServiceHost noch Platzhalter enthält
if grep -q 'REPLACE_WITH_PI_SERVER_IP' "${REPO_ROOT}/clusters/pi/infrastructure/cilium.yaml"; then
  echo "Fehler: k8sServiceHost in clusters/pi/infrastructure/cilium.yaml noch nicht gesetzt."
  echo "  mise run pi-up ausführen und cilium.yaml danach committen."
  exit 1
fi

# ── Flux Operator ──────────────────────────────────────────────────────────────
if helm status flux-operator -n flux-system &>/dev/null 2>&1; then
  echo "Flux Operator bereits installiert – übersprungen"
else
  helm upgrade --install flux-operator \
    oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
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
