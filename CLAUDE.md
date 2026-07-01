# CLAUDE.md

Leitfaden für die Arbeit an diesem Repository.

## Projektkontext

GitOps-verwalteter k3s-Cluster, gesteuert über Flux (Flux Operator). Mehrere Cluster-Targets geplant (lokal, Hetzner, Turing Pi); Module sollen target-übergreifend wiederverwendbar bleiben, target-spezifische Abweichungen nur in der Bootstrap-/Cluster-Schicht.

**Tooling:** mise (Versionsmanagement + Tasks), SOPS+age (Secrets), Cilium (CNI), cert-manager + external-dns/Cloudflare (TLS/DNS).

## Grundprinzipien

- **Alles im Repo, nichts nur in der Shell.** Jeder Schritt ist ein idempotentes Skript oder Manifest, aufrufbar über einen mise-Task. Ein frischer Checkout plus mise-Tasks in Reihenfolge muss einen identischen Cluster ergeben.
- **GitOps zuerst.** Nach dem Flux-Bootstrap wird nichts mehr manuell per `helm install`/`kubectl apply` installiert – alles läuft über Flux-Reconciliation aus dem Repo. Einzige Ausnahmen: die zwangsläufig imperativen Bootstrap-Schritte (CNI vor Flux, Flux selbst), klar als solche kommentiert.
- **Minimaler Overhead.** Keine Komponente aufnehmen, die kein konkretes Problem löst.

## Commit-Konvention: Conventional Commits

Schema:
```
<type>[optional scope]: <description>

[optional body]

[optional footer]
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`

**Regeln:**
- Description in Kleinschreibung, Imperativ, ohne Punkt am Ende
- Scope = betroffene Komponente (z. B. `cilium`, `flux`, `mise`, `sops`, `cert-manager`, `external-dns`)
- Breaking Changes: `!` nach Type/Scope **oder** Footer `BREAKING CHANGE: <beschreibung>`
- Ein Commit pro logischem Schritt, nicht mehrere Themen vermischen

**Beispiele:**
```
feat(cilium): add l2 announcement policy
fix(external-dns): correct cloudflare api token secret reference
chore(mise): pin flux2 version
docs(readme): document age key bootstrap
refactor(flux)!: move infrastructure into dependsOn chain
```

## Secrets

- **age-Private-Key gehört NIEMALS ins Repo.** Liegt lokal unter `~/.config/sops/age/keys.txt`.
- Alle Secrets im Repo sind SOPS-verschlüsselt (age-Recipient in `.sops.yaml`).
- Platzhalter-Secrets (z. B. Cloudflare-Token) werden verschlüsselt committed, der reale Wert lokal via `sops -e -i <datei>` eingetragen.
- `.gitignore` muss `.kube/` und age-Key-Pfade abdecken.

## Repo-Struktur

```
clusters/<cluster-name>/
  flux-system/         # FluxInstance + Bootstrap-Referenz
  infrastructure/      # HelmReleases (cilium, cert-manager, external-dns, ...)
.mise-tasks/           # idempotente Bootstrap-Skripte als mise-Tasks
.mise.toml             # Tools + Env
.sops.yaml             # age-Recipients
```

## Bootstrap-Reihenfolge

Alle Tasks erwarten `-- <local|pi>` als Argument.

### Erstmalig (pro Cluster)

```
mise run setup -- local   # age-Key, .sops.yaml, Cloudflare-Token
mise run setup -- pi      # wie local + Pi-Node-IPs abfragen
```

### Lokaler Entwicklungs-Cluster (k3d)

Zwingend, wegen Henne-Ei-Abhängigkeiten:

1. `mise run cluster-up   -- local` — k3d-Cluster ohne CNI (`--flannel-backend=none`, kube-proxy/traefik/servicelb/local-storage deaktiviert)
2. `mise run cilium-up    -- local` — Cilium imperativ (kein Pod ohne CNI, auch nicht Flux selbst)
3. `mise run flux-bootstrap -- local` — Flux Operator + FluxInstance + age-Secret; ab hier übernimmt Flux

### Pi-Cluster (1 Server + 3 Agents)

1. `mise run cluster-up   -- pi` — Chrony (NTP) + k3s auf allen Nodes via SSH; Kubeconfig → `.kube/pi-config`; patcht `k8sServiceHost` in `clusters/pi/infrastructure/cilium.yaml`
2. `git commit` + `git push` — cilium.yaml mit Server-IP committen und pushen (Flux reconciliert `origin/main`; `flux-bootstrap` prüft das)
3. `mise run cilium-up    -- pi` — Cilium imperativ auf Pi-Cluster
4. `mise run flux-bootstrap -- pi` — Flux auf Pi-Cluster; ab hier übernimmt Flux

Cilium wird nach dem Bootstrap per Helm-Release-Adoption von Flux übernommen (HelmRelease im Repo mit gleichem Name/Namespace wie der CLI-Install).

## Konventionen für Manifeste

- HelmReleases mit gepinnten Chart-Versionen, keine `latest`-Floating-Tags
- `dependsOn` nutzen, wo Reihenfolge nötig ist (Cilium ready vor cert-manager/external-dns)
- Namespaces explizit deklarieren
- Vor Commit lokal validieren (`kubeconform`/`kube-score`/`flux diff`, soweit anwendbar)

# Flux MCP — Betriebsregeln (read-only, k3d)

Regeln für `flux-operator-mcp`-Server. Zweck: Flux-Operator-verwaltete GitOps-Pipelines analysieren + troubleshooten.

## Kontext & Modus

- Server läuft **read-only**. Zustandsverändernde Tools (`reconcile_*`, `suspend_*`, `resume_*`, `apply_kubernetes_manifest`, `delete_kubernetes_resource`) deaktiviert — nie aufrufen.
- Genau **ein k3d-Cluster**, **ein** kubeconfig-Context. Kein Cluster-Wechsel, keine Cross-Cluster-Vergleiche. Context-Name: `k3d-local` (k3d präfixt Contexts mit `k3d-`).
- Secret-Werte vom Server maskiert. Nie entmaskieren.

## Wenn eine mutierende Aktion verlangt wird

Reconcile, Suspend/Resume, Apply, Delete gewünscht: **nicht** via MCP (deaktiviert). Stattdessen passendes `flux`-/`kubectl`-Kommando ausgeben, Nutzerin führt selbst aus. Beispiel:
`flux reconcile kustomization <name> -n <namespace> --with-source`.

## Tool-Grundregeln

- Installationsstatus, Controller-Health, Versionen → `get_flux_instance`.
- Beliebige k8s-/Flux-Ressourcen inkl. Status, Conditions, Events → `get_kubernetes_resources`.
- **apiVersion nie raten** → vorher `get_kubernetes_api_versions`, preferred Version nutzen.
- Flux-CRD-Details → `search_flux_docs` mit Kind als Query, nicht aus Gedächtnis.
- Flux-verwaltet? In `metadata` nach `fluxcd`-Labels/Annotationen suchen.
- CPU/Memory pro Pod → `get_kubernetes_metrics` (k3s hat metrics-server, läuft out of the box).

## Flux-CRDs (Kurzreferenz)

- **FluxInstance / FluxReport** — Installation bzw. gemeldeter Zustand.
- **ResourceSet / ResourceSetInputProvider** — Ressourcengruppen aus Input-Matrizen.
- **GitRepository / OCIRepository / Bucket / HelmRepository / HelmChart** — Sources.
- **Kustomization** — baut + appliziert Manifeste aus Source.
- **HelmRelease** — verwaltet Helm-Releases aus Source.
- **Alert / Provider / Receiver** — Notifications + Webhooks.
- **ImageRepository / ImagePolicy / ImageUpdateAutomation** — Image-Automation.

## Playbook: HelmRelease-Diagnose

1. `get_flux_instance` → helm-controller-Status + apiVersion von Kind HelmRelease prüfen.
2. `get_kubernetes_resources` → HelmRelease holen; spec, status, inventory, events lesen.
3. Managing object über Annotationen bestimmen (Kustomization oder ResourceSet).
4. Falls `valuesFrom` gesetzt: referenzierte ConfigMaps/Secrets nachladen.
5. Source via `chartRef`/`sourceRef` identifizieren, Status/Events prüfen.
6. Bei failed/in-progress: managed resources aus inventory holen, Status prüfen; bei Fehlern Logs via `get_kubernetes_logs`.
7. Root-Cause-Report. Nichts kaputt: Status von HelmRelease, managed resources, Container-Images berichten.

## Playbook: Kustomization-Diagnose

1. `get_flux_instance` → kustomize-controller-Status + apiVersion von Kind Kustomization.
2. `get_kubernetes_resources` → Kustomization holen; spec, status, inventory, events analysieren.
3. Managing object über Annotationen bestimmen (andere Kustomization oder ResourceSet).
4. Falls `substituteFrom` gesetzt: referenzierte ConfigMaps/Secrets nachladen.
5. Source via `sourceRef` identifizieren, Status/Events prüfen.
6. Bei failed/in-progress: managed resources aus inventory holen, Status prüfen, bei Fehlern Logs analysieren.
7. Root-Cause- bzw. Status-Report erstellen.

## Playbook: Log-Analyse

1. Pod-Name bestimmen: managendes Deployment via `get_kubernetes_resources` holen.
2. `matchLabels` + Container-Namen aus Deployment-spec lesen.
3. Pods via `matchLabels` mit `get_kubernetes_resources` listen.
4. Logs via `get_kubernetes_logs` mit Pod-/Container-Namen (`previous: true` falls Container abgestürzt).
