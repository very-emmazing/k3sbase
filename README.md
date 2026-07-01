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
mise run cluster-up   -- local   # k3d-Cluster ohne CNI erstellen; patcht ggf. cilium.yaml
mise run cilium-up    -- local   # Cilium imperativ installieren (kein Pod läuft ohne CNI)
mise run flux-bootstrap -- local # Flux Operator + FluxInstance + sops-age Secret
```

Wenn `cluster-up` die Server-IP in `clusters/local/infrastructure/cilium.yaml`
aktualisiert hat: **committen und pushen**, bevor `flux-bootstrap` läuft –
Flux reconciliert `origin/main`, nicht den lokalen Checkout
(`flux-bootstrap` prüft das).

### Pi-Cluster (1 Server + 3 Agents)

```bash
mise run cluster-up  -- pi   # Chrony + k3s via SSH; patcht clusters/pi/infrastructure/cilium.yaml
git add clusters/pi/infrastructure/cilium.yaml
git commit -m "chore(pi): set cilium api server host"
git push
mise run cilium-up    -- pi
mise run flux-bootstrap -- pi
```

Ab `flux-bootstrap` übernimmt Flux die Reconciliation.  
Alle weiteren Änderungen per Commit + Push → Flux synct automatisch.

## Secrets

### Cloudflare API Token für external-dns

`mise run setup -- <cluster>` fragt den Token interaktiv ab, verschlüsselt ihn
mit SOPS und bietet den Commit an – kein manueller `sops`-Aufruf nötig.
(Manuell nachträglich ändern: `sops clusters/<cluster>/infrastructure/external-dns-secret.yaml`.)

### age-Private-Key

Der Private Key liegt unter `~/.config/sops/age/keys.txt` und gehört **niemals ins Repo**.  
Auf neue Maschinen den vorhandenen Key kopieren – ein neu generierter Key kann
bestehende Secrets nicht entschlüsseln. `mise run setup` ersetzt bei abweichendem
Key den Recipient in `.sops.yaml` und warnt, dass alle Secrets neu verschlüsselt
werden müssen.

## Lokale Validierung mit flux-local

`flux-local` validiert Kustomizations und HelmReleases **rein lokal gegen den Git-Stand** – kein laufender Cluster nötig.

```bash
mise install   # installiert auch kustomize und flux-local (pipx)
```

| Task | Was er tut |
|---|---|
| `mise run flux-build` | Rendert alle Kustomizations aller Cluster und zählt die Ressourcen – schlägt fehl, wenn etwas nicht rendert |
| `mise run flux-diff-ks` | Zeigt den Diff einer einzelnen Kustomization gegen `main` (dyff-Format) |
| `mise run flux-diff-hr` | Zeigt den Diff einer einzelnen HelmRelease gegen `main` (Helm-template-inflated, dyff-Format) |
| `mise run flux-diff-hr-sub` | Wie `flux-diff-hr`, baut aber zuerst explizit die Kustomization, damit `postBuild`-Substitutionsvariablen im HelmRelease sichtbar sind |
| `mise run flux-test` | Volle Test-Suite inkl. Helm-Template-Validierung für alle Cluster |
| `mise run flux-check` | Führt `flux-build` + `flux-test` aus – als Pre-Push-Check |

`flux-build` und `flux-test` prüfen ohne Argument alle Cluster; die Diff-Tasks
defaulten auf `clusters/local`, ein anderer Pfad kommt als zusätzliches Argument.

**Beispiele:**

```bash
# Prüfen ob alle Kustomizations (alle Cluster) sauber rendern
mise run flux-build

# Nur den Pi-Cluster bauen
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
