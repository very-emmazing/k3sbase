# k3sbase

GitOps-verwalteter k3s-/k3d-Cluster mit Flux Operator, Cilium, cert-manager und external-dns/Cloudflare.
Der Pi-Cluster läuft IPv6-only mit Cilium Gateway API und Split-Horizon-Zugriff
(extern via Cloudflare Tunnel, intern via statischer IPv6-ULA) – siehe
[Pi-Cluster: IPv6-only, Gateway & Split-Horizon](#pi-cluster-ipv6-only-gateway--split-horizon).

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

### Pi-Cluster (1 Server + 3 Agents, IPv6-only)

Board ohne OS (frische Compute-Module): siehe
[docs/how-to/turing-pi-2-fresh-setup.md](docs/how-to/turing-pi-2-fresh-setup.md) –
flasht alle vier Nodes inkl. Cloud-Init, findet ihre IPs automatisch,
härtet SSH/sudo und setzt die statischen ULAs per Ansible. Endet bei genau
diesem Punkt hier.

Voraussetzung: `mise run setup -- pi` hat Node-IPs **und** Node-ULAs
(nodes.env) sowie Domain/Gateway-ULA/Tunnel-ID/ACME-E-Mail
(clusters/pi/cluster-settings.yaml) gesetzt; `mise run pi-provision` hat die
ULAs (Per-Node + Gateway-ULA auf dem Server) auf den Node-Interfaces
konfiguriert.

```bash
mise run cluster-up  -- pi   # Chrony + k3s (IPv6-only) via SSH; patcht clusters/pi/infrastructure/cilium.yaml
git add clusters/pi/infrastructure/cilium.yaml clusters/pi/cluster-settings.yaml
git commit -m "chore(pi): set cilium api server host"
git push
mise run cilium-up    -- pi  # appliziert auch die Gateway-API-CRDs (Bootstrap-Ausnahme)
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

## Pi-Cluster: IPv6-only, Gateway & Split-Horizon

Der Pi-Cluster fährt ein reines IPv6-Pod-/Service-Netz (ULA, RFC 4193):
`CLUSTER_CIDR`/`SERVICE_CIDR` in `clusters/pi/cluster-settings.yaml` werden
von `cluster-up` als k3s-Args (`--cluster-cidr`, `--service-cidr`,
`--node-ip`) und von Cilium (`ipv6NativeRoutingCIDR`, Native Routing statt
VXLAN – Tunnel-Modus braucht in Cilium 1.16 einen IPv4-Underlay) benutzt.

Derselbe Hostname ist über **zwei Pfade** erreichbar (Split-Horizon), damit
große Uploads (z.B. Nextcloud) nicht über den Tunnel-Umweg laufen müssen:

1. **Extern:** Cloudflare Tunnel (`cloudflared`-Deployment) → Cilium-Gateway-
   Service (`ClusterIP:443`, HTTPS, TLS-verifiziert gegen das cert-manager-
   Zertifikat).
2. **Intern/LAN:** dieselben Hostnames zeigen im LAN-DNS auf die statische
   `GATEWAY_ULA`, die per Cilium LB-IPAM fest an den Gateway-Service gebunden
   ist (Single-IP-Pool + `lbipam.cilium.io/ips`; kein L2-Announcement –
   `Gateway.spec.addresses`/`spec.externalIPs` sind auf dem von Cilium
   generierten Service nicht setzbar, LB-IPAM-Pinning ist der unterstützte
   Weg und verhält sich im Datapath identisch zu `externalIPs`).

### Einrichtung (einmalig)

```bash
cloudflared tunnel login          # Cloudflare-Konto autorisieren (lokal, Browser-OAuth)
cloudflared tunnel create pi      # schreibt ~/.cloudflared/<TUNNEL_ID>.json
mise run setup -- pi              # fragt TUNNEL_ID (aus der Ausgabe oben), Domain
                                   # etc. ab, verschlüsselt anschließend
                                   # ~/.cloudflared/<TUNNEL_ID>.json direkt in
                                   # cloudflared-credentials-secret.yaml (SOPS)
                                   # und bietet den Commit an
```

**Was Flux übernimmt:**

- Gateway-API-CRDs (`gateway-api-crds`-Kustomization, vor Cilium via `dependsOn`)
- Cilium (IPv6-only, Gateway API, Envoy), cert-manager, external-dns, cloudflared
- ClusterIssuer (Let's Encrypt, **DNS-01 via Cloudflare** – HTTP-01 ist ohne
  öffentlich erreichbaren Pfad nicht möglich) + Wildcard-Zertifikat
- **Externer DNS-Eintrag:** external-dns legt den CNAME
  `<hostname> → <TUNNEL_ID>.cfargotunnel.com` (proxied) selbst an – über den
  ExternalName-Service `cloudflared-tunnel-cname` mit
  `external-dns.alpha.kubernetes.io/hostname`-Annotation. Ein manueller
  Cloudflare-Eintrag bzw. `cloudflared tunnel route dns` entfällt.

**Automatisiert (siehe [Turing-Pi-2-How-To](docs/how-to/turing-pi-2-fresh-setup.md)):**
Node-ULAs und Gateway-ULA werden von `mise run pi-provision` (Ansible) als
statische netplan-Adressen gesetzt – Gateway-ULA nur auf dem Server-Node
(sonst schlägt IPv6 Duplicate Address Detection zu; der Node beantwortet
dann NDP für die ULA, Cilium-eBPF leitet ankommenden Traffic an die
Gateway-Backends weiter).

**Was manuell bleibt (außerhalb des Repos):**

- **Cloudflare Tunnel anlegen** (`cloudflared tunnel login` +
  `tunnel create`) – Browser-OAuth, nicht scriptbar. Ab der geschriebenen
  JSON-Datei übernimmt `mise run setup -- pi` (siehe oben).
- **Interner DNS** (z.B. Fritzbox/Pi-hole): `echo-a.<domain>` und
  `echo-b.<domain>` auf die `GATEWAY_ULA` auflösen lassen. Ohne internen
  DNS-Override geht der LAN-Traffic den externen Weg über den Tunnel.
- **IPv6-Egress:** die Nodes brauchen ausgehendes IPv6 (GUA vom Router) –
  cloudflared (`edge-ip-version: 6`) und Let's Encrypt/Cloudflare-API werden
  aus dem IPv6-only-Pod-Netz heraus erreicht (Cilium masqueradet auf die
  Node-Adresse).

Der Echo-Beispiel-Workload (`clusters/pi/apps/echo.yaml`) testet die ganze
Kette über beide Pfade – Testfälle in [TESTPLAN.md](TESTPLAN.md).

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
