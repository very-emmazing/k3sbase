#!/usr/bin/env bash
set -euo pipefail

AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"

if [[ -f "${AGE_KEY_FILE}" ]]; then
  echo "age key already exists at ${AGE_KEY_FILE}"
else
  mkdir -p "$(dirname "${AGE_KEY_FILE}")"
  age-keygen -o "${AGE_KEY_FILE}"
  chmod 600 "${AGE_KEY_FILE}"
  echo "Generated new age key at ${AGE_KEY_FILE}"
fi

PUBLIC_KEY="$(grep '^# public key:' "${AGE_KEY_FILE}" | awk '{print $NF}')"
echo "Public key: ${PUBLIC_KEY}"

# Write .sops.yaml with the actual recipient
cat > "${SOPS_YAML}" <<SOPS
# Never commit the age private key (${AGE_KEY_FILE}).
creation_rules:
  - path_regex: clusters/.*\.yaml$
    age: ${PUBLIC_KEY}
SOPS

echo ""
echo "Updated ${SOPS_YAML}"
echo ""
echo "Next steps:"
echo "  1. Commit the updated .sops.yaml: git add .sops.yaml && git commit -m 'chore(sops): set age recipient'"
echo "  2. Set the Cloudflare token in clusters/local/infrastructure/external-dns-secret.yaml"
echo "  3. Encrypt it: sops -e -i clusters/local/infrastructure/external-dns-secret.yaml"
echo "  4. Commit the encrypted secret"
