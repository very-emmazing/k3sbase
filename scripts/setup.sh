#!/usr/bin/env bash
# setup.sh – interaktiver Setup-Assistent für k3sbase
# Prüft jede Voraussetzung, gibt Hinweise falls fehlend, speichert Secrets via SOPS.
# Ausführen via: mise run setup
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"

# Alle Cloudflare-Secrets über alle Cluster – Token wird einmal abgefragt
CF_SECRETS=(
  "clusters/local/infrastructure/external-dns-secret.yaml"
  "clusters/pi/infrastructure/external-dns-secret.yaml"
)

# ── Farben (nur im interaktiven Terminal) ─────────────────────────────────────
if [[ -t 1 ]]; then
  GRN='\033[0;32m' YEL='\033[1;33m' BLU='\033[0;34m' BOLD='\033[1m' RST='\033[0m'
else
  GRN='' YEL='' BLU='' BOLD='' RST=''
fi

ok()   { printf "  ${GRN}✓${RST}  %s\n" "$*"; }
hint() { printf "  ${BLU}→${RST}  %s\n" "$*"; }
warn() { printf "  ${YEL}!${RST}  %s\n" "$*"; }
step() { printf "\n${BOLD}[%s/4] %s${RST}\n" "$1" "$2"; }
die()  { printf "\n${YEL}Abbruch: %s${RST}\n" "$*" >&2; exit 1; }

# ── Voraussetzungen ───────────────────────────────────────────────────────────
for tool in age-keygen sops; do
  command -v "${tool}" &>/dev/null || die "${tool} nicht gefunden – zuerst: mise install"
done

printf "\n${BOLD}════ k3sbase · Setup-Assistent ════════════════${RST}\n"

# ── [1/4] age-Schlüssel ───────────────────────────────────────────────────────
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

# ── [2/4] .sops.yaml Recipient ────────────────────────────────────────────────
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

# ── [3/4] Pi-Nodes konfigurieren ──────────────────────────────────────────────
step 3 "Pi-Cluster Node-Konfiguration (clusters/pi/nodes.env)"

NODES_ENV="${REPO_ROOT}/clusters/pi/nodes.env"
NODES_ENV_UPDATED=false

_nodes_configured() {
  # shellcheck source=/dev/null
  source "${NODES_ENV}"
  [[ -n "${PI_SERVER:-}" && -n "${PI_AGENT_0:-}" && -n "${PI_AGENT_1:-}" && -n "${PI_AGENT_2:-}" ]]
}

if _nodes_configured 2>/dev/null; then
  # shellcheck source=/dev/null
  source "${NODES_ENV}"
  ok "Konfiguriert: server=${PI_SERVER}  agents=${PI_AGENT_0} ${PI_AGENT_1} ${PI_AGENT_2}"
else
  hint "IP-Adressen der Pi-Nodes eingeben"
  hint "  Voraussetzung: Ubuntu installiert, SSH-Pubkey bereits hinterlegt"
  echo
  read -r -p "  SSH-User    [ubuntu]: " INPUT_USER
  PI_USER="${INPUT_USER:-ubuntu}"

  read -r -p "  Server-IP  (1x): " PI_SERVER
  [[ -z "${PI_SERVER}" ]] && die "Server-IP darf nicht leer sein"

  read -r -p "  Agent-IP 1 (1x): " PI_AGENT_0
  read -r -p "  Agent-IP 2 (2x): " PI_AGENT_1
  read -r -p "  Agent-IP 3 (3x): " PI_AGENT_2
  [[ -z "${PI_AGENT_0}" || -z "${PI_AGENT_1}" || -z "${PI_AGENT_2}" ]] && die "Alle drei Agent-IPs angeben"

  cat > "${NODES_ENV}" <<ENV
# Pi-Cluster Node-Konfiguration
# Trage hier deine tatsächlichen IP-Adressen ein, dann: mise run pi-up
#
# Voraussetzungen:
#   - Ubuntu auf allen Nodes (kein weiteres Setup nötig)
#   - SSH-Pubkey bereits hinterlegt (ssh-copy-id)
#   - Nodes per SSH erreichbar

PI_USER="${PI_USER}"

PI_SERVER="${PI_SERVER}"     # Server-Node (1x)
PI_AGENT_0="${PI_AGENT_0}"   # Agent-Node  (1x)
PI_AGENT_1="${PI_AGENT_1}"   # Agent-Node  (2x)
PI_AGENT_2="${PI_AGENT_2}"   # Agent-Node  (3x)
ENV
  ok "nodes.env aktualisiert"
  NODES_ENV_UPDATED=true
fi

# ── [4/4] Cloudflare API Token (alle Cluster) ─────────────────────────────────
CF_SECRETS_UPDATED=()

step 4 "Cloudflare API Token (external-dns – alle Cluster)"

# Prüfen welche Secrets noch nicht verschlüsselt sind
UNENCRYPTED=()
for secret in "${CF_SECRETS[@]}"; do
  if grep -q 'ENC\[' "${REPO_ROOT}/${secret}" 2>/dev/null; then
    ok "Bereits verschlüsselt: ${secret}"
  else
    UNENCRYPTED+=("${secret}")
  fi
done

if [[ ${#UNENCRYPTED[@]} -gt 0 ]]; then
  # Token nur einmal abfragen (gilt für alle Cluster – selbes Cloudflare-Konto)
  CF_TOKEN=""
  for secret in "${UNENCRYPTED[@]}"; do
    EXISTING="$(grep 'token:' "${REPO_ROOT}/${secret}" | awk '{print $2}' | tr -d '"' | xargs 2>/dev/null || true)"
    if [[ -n "${EXISTING}" ]]; then
      CF_TOKEN="${EXISTING}"
      warn "Plaintext-Token aus ${secret} übernommen"
      break
    fi
  done

  if [[ -z "${CF_TOKEN}" ]]; then
    hint "Token erstellen unter: https://dash.cloudflare.com/profile/api-tokens"
    hint "  → \"Create Token\" → Template \"Edit zone DNS\""
    hint "  Berechtigungen: Zone:DNS:Edit   (Zone:Zone:Read optional für Autodiscovery)"
    hint "  Dieser Token gilt für alle Cluster (selbes Cloudflare-Konto)"
    echo
    read -r -s -p "  Token (Eingabe unsichtbar): " CF_TOKEN
    echo
    [[ -z "${CF_TOKEN}" ]] && die "Kein Token eingegeben"
  fi

  for secret in "${UNENCRYPTED[@]}"; do
    cat > "${REPO_ROOT}/${secret}" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: external-dns
stringData:
  token: "${CF_TOKEN}"
YAML
    SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" sops -e -i "${REPO_ROOT}/${secret}"
    ok "Verschlüsselt: ${secret}"
    CF_SECRETS_UPDATED+=("${secret}")
  done
fi

# ── Commits ───────────────────────────────────────────────────────────────────
_commit() {
  local msg="$1"; shift
  git -C "${REPO_ROOT}" add "$@"
  git -C "${REPO_ROOT}" commit -m "${msg}"
  ok "Committed: ${msg}"
}

HAS_CHANGES=false
[[ "${SOPS_YAML_UPDATED}"  == true ]]     && HAS_CHANGES=true
[[ "${NODES_ENV_UPDATED}"  == true ]]     && HAS_CHANGES=true
[[ ${#CF_SECRETS_UPDATED[@]} -gt 0 ]]     && HAS_CHANGES=true

if [[ "${HAS_CHANGES}" == true ]]; then
  printf "\n"
  read -r -p "  Änderungen jetzt committen? (j/N) " REPLY
  if [[ "${REPLY}" =~ ^[jJ]$ ]]; then
    [[ "${SOPS_YAML_UPDATED}" == true ]] && \
      _commit "chore(sops): set age recipient" .sops.yaml
    [[ "${NODES_ENV_UPDATED}" == true ]] && \
      _commit "chore(pi): set node ips in nodes.env" clusters/pi/nodes.env
    if [[ ${#CF_SECRETS_UPDATED[@]} -gt 0 ]]; then
      _commit "feat(external-dns): add sops-encrypted cloudflare api token" \
        "${CF_SECRETS_UPDATED[@]}"
    fi
  else
    printf "\n"
    hint "Manuell committen:"
    [[ "${SOPS_YAML_UPDATED}" == true ]] && \
      hint "  git add .sops.yaml && git commit -m 'chore(sops): set age recipient'"
    [[ "${NODES_ENV_UPDATED}" == true ]] && \
      hint "  git add clusters/pi/nodes.env && git commit -m 'chore(pi): set node ips in nodes.env'"
    for s in "${CF_SECRETS_UPDATED[@]}"; do
      hint "  git add ${s}"
    done
    [[ ${#CF_SECRETS_UPDATED[@]} -gt 0 ]] && \
      hint "  git commit -m 'feat(external-dns): add sops-encrypted cloudflare api token'"
  fi
fi

# ── Nächste Schritte ──────────────────────────────────────────────────────────
printf "\n${BOLD}════ Abgeschlossen ════════════════════════════${RST}\n\n"
hint "Lokaler Cluster:"
hint "  mise run k3d-up && mise run cilium-up && mise run flux-bootstrap"
hint "Pi-Cluster:"
hint "  mise run pi-up"
hint "  # cilium.yaml committen falls geändert"
hint "  mise run pi-cilium-up && mise run pi-flux-bootstrap"
printf "\n"
