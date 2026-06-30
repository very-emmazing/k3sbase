# k3sbase

GitOps-verwalteter k3d-Cluster mit Flux Operator, Cilium, cert-manager und external-dns/Cloudflare.

## Voraussetzungen

```
mise install   # installiert kubectl, helm, flux2, age, sops, k3d, cilium-cli
```

Benötigt: Docker (für k3d) und einen Linux-Host mit Kernel ≥ 5.10 (für Cilium eBPF/kube-proxy-replacement).

## Bootstrap-Reihenfolge

### Einmalig (Secrets + Konfiguration)

```bash
mise run setup   # age-Key, SOPS, Pi-Node-IPs, Cloudflare-Token – einmal für alle Cluster
```

### Lokaler Entwicklungs-Cluster (k3d)

```bash
mise run k3d-up          # k3d-Cluster ohne CNI erstellen
mise run cilium-up       # Cilium imperativ installieren (kein Pod läuft ohne CNI)
mise run flux-bootstrap  # Flux Operator + FluxInstance + sops-age Secret
```

### Pi-Cluster (1 Server + 3 Agents)

```bash
mise run pi-up           # Chrony + k3s via SSH; patcht clusters/pi/infrastructure/cilium.yaml
git add clusters/pi/infrastructure/cilium.yaml
git commit -m "chore(pi): set cilium api server host"
mise run pi-cilium-up    # Cilium imperativ auf Pi-Cluster
mise run pi-flux-bootstrap
```

Ab `flux-bootstrap` / `pi-flux-bootstrap` übernimmt Flux die Reconciliation.  
Alle weiteren Änderungen per Commit → Flux synct automatisch.

## Secrets

### Cloudflare API Token für external-dns

1. Echten Token in die Datei eintragen:
   ```bash
   # in clusters/local/infrastructure/external-dns-secret.yaml den Wert von 'token' setzen
   ```

2. Datei mit SOPS verschlüsseln (nach `mise run age-init`):
   ```bash
   sops -e -i clusters/local/infrastructure/external-dns-secret.yaml
   ```

3. Verschlüsselte Datei committen – der Ciphertext ist sicher im Repo.

### age-Private-Key

Der Private Key liegt unter `~/.config/sops/age/keys.txt` und gehört **niemals ins Repo**.  
Auf neuen Maschinen `mise run age-init` ausführen und dann den Public Key in `.sops.yaml` eintragen.

## Cluster-Targets

Aktuell: `local`. Weitere Targets (Hetzner, Turing Pi) werden als eigene Verzeichnisse unter
`clusters/` angelegt; die `infrastructure/`-Manifeste sollen target-übergreifend wiederverwendet werden.
