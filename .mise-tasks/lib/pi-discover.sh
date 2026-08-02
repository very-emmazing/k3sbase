# Wird von "setup" (pi) und "pi-discover" gesourct (kein eigener mise-Task,
# daher nicht ausführbar).
#
# Scannt das lokale /24-Subnetz nach Hosts mit offenem Port 22, prüft deren
# Hostname per SSH gegen "pi-node-<1-4>" (von "pi-flash" via Cloud-Init
# gesetzt, Slot 1 = Server, Slot 2-4 = Agent 0-2 – gleiche Konvention wie
# dort). Subnetz-Präfix (erste drei Oktette) wird aus der Default-Route der
# Workstation abgeleitet, override via PI_SUBNET_PREFIX="a.b.c".
#
# ACHTUNG: probiert SSH-Login auf jeden Host mit offenem Port 22 im Subnetz,
# nicht nur die eigenen Nodes – akzeptiert dabei unbekannte Host-Keys
# (StrictHostKeyChecking=accept-new) und landet damit ggf. in
# ~/.ssh/known_hosts. Harmlos (Login schlägt für fremde Hosts einfach fehl),
# aber gut zu wissen.
#
# Setzt bei vollständigem Treffer PI_SERVER/PI_AGENT_0/PI_AGENT_1/PI_AGENT_2
# und gibt 0 zurück. Sonst Ausgabe des Teil-Ergebnisses auf stderr, 1.
discover_pi_nodes() {
  local user="${1:-ubuntu}"
  local prefix="${PI_SUBNET_PREFIX:-}"

  if [[ -z "${prefix}" ]]; then
    local dev local_ip
    dev="$(ip -4 route show default | awk '{print $5; exit}')"
    local_ip="$(ip -4 -o addr show dev "${dev}" scope global | awk '{print $4; exit}' | cut -d/ -f1)"
    [[ -z "${local_ip}" ]] && { echo "Fehler: lokales Subnetz nicht ermittelbar – PI_SUBNET_PREFIX=<a.b.c> setzen" >&2; return 1; }
    prefix="${local_ip%.*}"
  fi

  echo "Scanne ${prefix}.0/24 nach Pi-Nodes (Port 22) …" >&2

  local tmpdir; tmpdir="$(mktemp -d)"
  local i host
  for i in $(seq 1 254); do
    host="${prefix}.${i}"
    ( timeout 1 bash -c "echo >/dev/tcp/${host}/22" 2>/dev/null && : > "${tmpdir}/${host}" ) &
    if (( i % 32 == 0 )); then wait; fi
  done
  wait

  local open=()
  mapfile -t open < <(ls "${tmpdir}" 2>/dev/null)
  rm -rf "${tmpdir}"

  if [[ "${#open[@]}" -eq 0 ]]; then
    echo "Fehler: keine Hosts mit offenem Port 22 in ${prefix}.0/24 gefunden" >&2
    return 1
  fi

  local -A found
  local ip hn
  for ip in "${open[@]}"; do
    hn="$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
              "${user}@${ip}" hostname 2>/dev/null || true)"
    [[ "${hn}" =~ ^pi-node-([1-4])$ ]] && found["${BASH_REMATCH[1]}"]="${ip}"
  done

  echo -n "Gefunden: " >&2
  local s
  for s in 1 2 3 4; do printf 'pi-node-%s=%s  ' "${s}" "${found[${s}]:-?}" >&2; done
  echo >&2

  local missing=() slot
  for slot in 1 2 3 4; do
    [[ -z "${found[${slot}]:-}" ]] && missing+=("${slot}")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Fehler: Slot(s) ${missing[*]} nicht gefunden/erreichbar" >&2
    return 1
  fi

  PI_SERVER="${found[1]}"
  PI_AGENT_0="${found[2]}"
  PI_AGENT_1="${found[3]}"
  PI_AGENT_2="${found[4]}"
}
