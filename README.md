# k3sbase

GitOps-verwalteter k3s-Cluster mit Flux Operator, Cilium, cert-manager und external-dns/Cloudflare.

## Voraussetzungen

```
mise install   # installiert kubectl, helm, flux2, age, sops, cilium-cli
```

Benötigt: echter k3s-Host (lokal, VM oder Hetzner) – kein k3d/kind.

## Bootstrap-Reihenfolge

```bash
mise run k3s-up          # k3s ohne CNI installieren
mise run age-init        # age-Key generieren, .sops.yaml befüllen
mise run cilium-up       # Cilium imperativ installieren (kein Pod läuft ohne CNI)
mise run flux-bootstrap  # Flux Operator + FluxInstance + sops-age Secret
```

Ab `flux-bootstrap` übernimmt Flux die Reconciliation aus dem Repo.  
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
