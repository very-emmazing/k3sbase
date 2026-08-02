# Wird von pi-flash und pi-provision gesourct (kein eigener mise-Task,
# daher nicht ausführbar).
#
# Gibt den ersten Public Key aus dem laufenden ssh-agent auf stdout aus.
# Bei mehreren geladenen Keys: Warnung auf stderr, erster Key gewinnt.
ssh_agent_pubkey() {
  local keys
  mapfile -t keys < <(ssh-add -L 2>/dev/null || true)
  if [[ "${#keys[@]}" -eq 0 || "${keys[0]}" == "The agent has no identities."* ]]; then
    echo "Fehler: kein Key im ssh-agent geladen – zuerst: ssh-add <keyfile>" >&2
    return 1
  fi
  if [[ "${#keys[@]}" -gt 1 ]]; then
    echo "Mehrere Keys im ssh-agent, verwende ersten: ${keys[0]}" >&2
  fi
  printf '%s\n' "${keys[0]}"
}
