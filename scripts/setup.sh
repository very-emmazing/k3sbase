#!/usr/bin/env bash
# setup.sh – interaktiver Setup-Assistent für k3sbase
# Prüft jede Voraussetzung, gibt Hinweise falls fehlend, speichert Secrets via SOPS.
# Ausführen via: mise run setup
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"
CF_SECRET="clusters/local/infrastructure/external-dns-secret.yaml"

# ── Farben (nur im interaktiven Terminal) ─────────────────────────────────────
if [[ -t 1 ]]; then
  GRN='\033[0;32m' YEL='\033[1;33m' BLU='\033[0;34m' BOLD='\033[1m' RST='\033[0m'
else
  GRN='' YEL='' BLU='' BOLD='' RST=''
fi

ok()   { printf "  ${GRN}✓${RST}  %s\n" "$*"; }
hint() { printf "  ${BLU}→${RST}  %s\n" "$*"; }
warn() { printf "  ${YEL}!${RST}  %s\n" "$*"; }
step() { printf "\n${BOLD}[%s/3] %s${RST}\n" "$1" "$2"; }
die()  { printf "\n${YEL}Abbruch: %s${RST}\n" "$*" >&2; exit 1; }

# ── Voraussetzungen ───────────────────────────────────────────────────────────
for tool in age-keygen sops; do
  command -v "${tool}" &>/dev/null || die "${tool} nicht gefunden – zuerst: mise install"
done

printf "\n${BOLD}════ k3sbase · Setup-Assistent ════════════════${RST}\n"

# ── [1/3] age-Schlüssel ───────────────────────────────────────────────────────
SOPS_YAML_UPDATED=false

step 1 "age-Schlüssel"

if [[ -f "${AGE_KEY_FILE}" ]]; then
  ok "Vorhanden: ${AGE_KEY_FILE}"
else
  hint "Noch nicht vorhanden – wird lokal generiert"
  hint "Der Private Key verlässt diese Maschine nicht (niemals ins Repo)"
  mkdir -p "$(dirname "${AGE_KEY_FILE}")"
  age-keygen -o "${AGE_KEY_FILE}"
  chmod 600 "${AGE_KEY_FILE}"
  ok "Generiert: ${AGE_KEY_FILE}"
fi

AGE_PUB="$(grep '^# public key:' "${AGE_KEY_FILE}" | awk '{print $NF}')"
hint "Public Key: ${AGE_PUB}"

# ── [2/3] .sops.yaml Recipient ────────────────────────────────────────────────
step 2 "SOPS-Konfiguration (.sops.yaml)"

CURRENT_RCP="$(grep -E '^\s+age:' "${SOPS_YAML}" | awk '{print $2}' | tr -d '"' | head -1 || true)"

if [[ "${CURRENT_RCP}" == "${AGE_PUB}" ]]; then
  ok "Recipient stimmt überein"
else
  if [[ -n "${CURRENT_RCP}" ]]; then
    warn "Recipient unterscheidet sich (${CURRENT_RCP})"
    warn "Bereits verschlüsselte Secrets müssen mit dem neuen Key neu verschlüsselt werden"
  fi
  cat > "${SOPS_YAML}" <<SOPS
# Never commit the age private key (${AGE_KEY_FILE}).
creation_rules:
  - path_regex: clusters/.*\.yaml$
    age: ${AGE_PUB}
SOPS
  ok ".sops.yaml aktualisiert"
  SOPS_YAML_UPDATED=true
fi

# ── [3/3] Cloudflare API Token (external-dns) ─────────────────────────────────
CF_SECRET_UPDATED=false

step 3 "Cloudflare API Token (external-dns)"

if grep -q 'ENC\[' "${REPO_ROOT}/${CF_SECRET}" 2>/dev/null; then
  ok "Bereits SOPS-verschlüsselt – übersprungen"
else
  EXISTING_TOKEN="$(grep 'token:' "${REPO_ROOT}/${CF_SECRET}" | awk '{print $2}' | tr -d '"' | xargs 2>/dev/null || true)"

  if [[ -z "${EXISTING_TOKEN}" ]]; then
    hint "Token erstellen unter: https://dash.cloudflare.com/profile/api-tokens"
    hint "  → \"Create Token\" → Template \"Edit zone DNS\""
    hint "  Berechtigungen: Zone:DNS:Edit   (Zone:Zone:Read optional für Autodiscovery)"
    echo
    read -r -s -p "  Token (Eingabe unsichtbar): " CF_TOKEN
    echo
    [[ -z "${CF_TOKEN}" ]] && die "Kein Token eingegeben"
  else
    warn "Plaintext-Token gefunden – wird verschlüsselt ohne erneute Abfrage"
    CF_TOKEN="${EXISTING_TOKEN}"
  fi

  # Datei neu schreiben (sauber, ohne alten Kommentar-Header), dann in-place verschlüsseln
  cat > "${REPO_ROOT}/${CF_SECRET}" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: external-dns
stringData:
  token: "${CF_TOKEN}"
YAML

  SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" sops -e -i "${REPO_ROOT}/${CF_SECRET}"
  ok "Verschlüsselt: ${CF_SECRET}"
  CF_SECRET_UPDATED=true
fi

# ── Commits ───────────────────────────────────────────────────────────────────
_commit() {
  local msg="$1"; shift
  git -C "${REPO_ROOT}" add "$@"
  git -C "${REPO_ROOT}" commit -m "${msg}"
  ok "Committed: ${msg}"
}

if [[ "${SOPS_YAML_UPDATED}" == true || "${CF_SECRET_UPDATED}" == true ]]; then
  printf "\n"
  read -r -p "  Änderungen jetzt committen? (j/N) " REPLY
  if [[ "${REPLY}" =~ ^[jJ]$ ]]; then
    [[ "${SOPS_YAML_UPDATED}"  == true ]] && _commit "chore(sops): set age recipient"          .sops.yaml
    [[ "${CF_SECRET_UPDATED}"  == true ]] && _commit "feat(external-dns): add sops-encrypted cloudflare api token" "${CF_SECRET}"
  else
    printf "\n"
    hint "Manuell committen:"
    [[ "${SOPS_YAML_UPDATED}"  == true ]] && hint "  git add .sops.yaml && git commit -m 'chore(sops): set age recipient'"
    [[ "${CF_SECRET_UPDATED}"  == true ]] && hint "  git add ${CF_SECRET} && git commit -m 'feat(external-dns): add sops-encrypted cloudflare api token'"
  fi
fi

# ── Nächste Schritte ──────────────────────────────────────────────────────────
printf "\n${BOLD}════ Abgeschlossen ════════════════════════════${RST}\n\n"
hint "Nächste Schritte:"
hint "  mise run k3d-up"
hint "  mise run cilium-up"
hint "  mise run flux-bootstrap"
printf "\n"
