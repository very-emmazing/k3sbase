#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="local"

# Step 1: Install Flux Operator via Helm.
# Flux is installed imperatively once; afterwards it self-manages via the
# FluxInstance in clusters/${CLUSTER}/flux-system/flux-instance.yaml.
# Pin --version <x.y.z> for reproducible bootstraps (see https://github.com/controlplaneio-fluxcd/flux-operator/releases).
if helm status flux-operator -n flux-system &>/dev/null; then
  echo "Flux Operator already installed, skipping Helm install"
else
  helm upgrade --install flux-operator \
    oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --namespace flux-system \
    --create-namespace \
    --wait
fi

# Step 2: Apply FluxInstance – tells the operator which Flux components to
# install and where to find the GitOps repo.
kubectl apply -f "${REPO_ROOT}/clusters/${CLUSTER}/flux-system/flux-instance.yaml"

# Step 3: Create SOPS age secret so Flux can decrypt secrets in the repo.
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  echo "ERROR: age key not found at ${AGE_KEY_FILE}. Run 'mise run age-init' first."
  exit 1
fi

kubectl create secret generic sops-age \
  --namespace flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Flux bootstrap complete."
echo "Flux will now reconcile the cluster from ${REPO_ROOT}/clusters/${CLUSTER}/"
