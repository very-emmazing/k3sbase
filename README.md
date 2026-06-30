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
mise run setup -- local   # age-Key, SOPS, Cloudflare-Token für lokalen Cluster
mise run setup -- pi      # + Pi-Node-IPs zusätzlich abfragen
```

### Lokaler Entwicklungs-Cluster (k3d)

```bash
mise run cluster-up   -- local   # k3d-Cluster ohne CNI erstellen
mise run cilium-up    -- local   # Cilium imperativ installieren (kein Pod läuft ohne CNI)
mise run flux-bootstrap -- local # Flux Operator + FluxInstance + sops-age Secret
```

### Pi-Cluster (1 Server + 3 Agents)

```bash
mise run cluster-up  -- pi   # Chrony + k3s via SSH; patcht clusters/pi/infrastructure/cilium.yaml
git add clusters/pi/infrastructure/cilium.yaml
git commit -m "chore(pi): set cilium api server host"
mise run cilium-up    -- pi
mise run flux-bootstrap -- pi
```

Ab `flux-bootstrap` / `pi-flux-bootstrap` übernimmt Flux die Reconciliation.  
Alle weiteren Änderungen per Commit → Flux synct automatisch.

## Secrets

### Cloudflare API Token für external-dns

1. Echten Token in die Datei eintragen:
   ```bash
   # in clusters/local/infrastructure/external-dns-secret.yaml den Wert von 'token' setzen
   ```

2. Datei mit SOPS verschlüsseln (nach `mise run setup`):
   ```bash
   sops -e -i clusters/local/infrastructure/external-dns-secret.yaml
   ```

3. Verschlüsselte Datei committen – der Ciphertext ist sicher im Repo.

### age-Private-Key

Der Private Key liegt unter `~/.config/sops/age/keys.txt` und gehört **niemals ins Repo**.  
Auf neuen Maschinen `mise run setup` ausführen und dann den Public Key in `.sops.yaml` eintragen.

## Lokale Validierung mit flux-local

`flux-local` validiert Kustomizations und HelmReleases **rein lokal gegen den Git-Stand** – kein laufender Cluster nötig.

```bash
mise install   # installiert auch kustomize und flux-local (pipx)
```

| Task | Was er tut |
|---|---|
| `mise run flux-build` | Rendert alle Kustomizations und zählt die Ressourcen – schlägt fehl, wenn etwas nicht rendert |
| `mise run flux-diff-ks` | Zeigt den Diff einer einzelnen Kustomization gegen `main` (dyff-Format) |
| `mise run flux-diff-hr` | Zeigt den Diff einer einzelnen HelmRelease gegen `main` (Helm-template-inflated, dyff-Format) |
| `mise run flux-diff-hr-sub` | Wie `flux-diff-hr`, baut aber zuerst explizit die Kustomization, damit `postBuild`-Substitutionsvariablen im HelmRelease sichtbar sind |
| `mise run flux-test` | Volle Test-Suite inkl. Helm-Template-Validierung für alle Cluster |
| `mise run flux-check` | Führt `flux-build` + `flux-test` aus – als Pre-Push-Check |

Der Default-Cluster-Pfad ist überall `clusters/local`; einen anderen Pfad als zusätzliches Argument übergeben.

**Beispiele:**

```bash
# Prüfen ob alle Kustomizations in clusters/local sauber rendern
mise run flux-build

# Dasselbe für den Pi-Cluster
mise run flux-build -- clusters/pi

# Diff der Kustomization "infrastructure" gegen main
mise run flux-diff-ks -- infrastructure

# Diff der HelmRelease "cilium" im Namespace "kube-system"
mise run flux-diff-hr -- cilium kube-system

# Dasselbe, aber zuerst Kustomization rendern (wenn cilium-Werte via postBuild-Variablen gesetzt werden)
mise run flux-diff-hr-sub -- cilium kube-system

# Volle Test-Suite (alle Cluster)
mise run flux-test

# Alles auf einmal (entspricht dem Pre-Push-Hook)
mise run flux-check
```

Der Pre-Push-Hook (`mise run flux-check`) wird über pre-commit aktiviert:

```bash
pre-commit install --hook-type pre-push
```

## Cluster-Targets

Aktuell: `local` und `pi`. Weitere Targets werden als eigene Verzeichnisse unter
`clusters/` angelegt; die `infrastructure/`-Manifeste sollen target-übergreifend wiederverwendet werden.
