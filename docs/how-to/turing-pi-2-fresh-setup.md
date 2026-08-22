# Wie richte ich einen frischen Turing Pi 2 (ohne OS) für dieses Repo ein

Ziel: ein Turing Pi 2 Board mit vier leeren Compute-Modulen bis zu dem Punkt
bringen, an dem `mise run setup -- pi` und die
[Bootstrap-Reihenfolge im README](../../README.md#pi-cluster-1-server--3-agents-ipv6-only)
übernehmen können — d.h. Ubuntu auf allen vier Nodes, per SSH mit Pubkey
erreichbar, statische IPv6-ULA pro Node konfiguriert.

## Voraussetzungen

- Turing Pi 2 Board (4 Slots) mit 4 kompatiblen Compute-Modulen (z.B. Turing
  RK1) und Netzteil, per Ethernet am LAN
- Workstation mit `tpi`-CLI installiert (BMC-Steuerung; Alternative:
  BMC-Web-UI unter `https://<bmc-ip>`) — siehe
  [Turing Pi BMC-Doku](https://docs.turingpi.com/)
- Ubuntu-Server-Image (arm64, "preinstalled-server"-Variante — cloud-init im
  NoCloud-Format auf der Boot-Partition) passend zum Modultyp heruntergeladen
- ssh-agent läuft, Ziel-Key geladen (`ssh-add -l`) — wird beim Flashen und
  Provisionieren automatisch aus dem Agent gezogen, kein Datei-Pfad nötig
- `sudo` auf der Workstation (für `losetup`/`mount` beim Einbetten des
  Cloud-Init-user-data in Schritt 2)
- BMC-Zugangsdaten als `TPI_USERNAME`/`TPI_PASSWORD` exportiert (`tpi` liest
  diese Env-Vars automatisch; ohne sie hängt jeder `tpi`-Aufruf an einem
  interaktiven Passwort-Prompt — bricht `pi-flash` mitten in der
  Slot-Schleife ab). Default ab Werk: `root`/`turing` — vor Produktivbetrieb
  ändern (BMC-Web-UI oder `tpi`).
- Router mit IPv6-Präfix-Delegation (GUA-Egress) und DHCP für die
  Management-IPv4-Adressen der Nodes
- Dieses Repo geklont, `mise install` bereits gelaufen (installiert u.a.
  `tpi` und `ansible-core`)

## 1. BMC erreichen

BMC hängt am selben LAN wie die Nodes, bezieht per DHCP eine eigene IP.

```bash
# IP über Router-DHCP-Leases oder mDNS ermitteln, dann:
tpi --host <bmc-ip> info          # Firmware-Version, erkannte Module pro Slot
```

Alternativ Web-UI unter `https://<bmc-ip>` (Default-Login siehe Board-Aufkleber
bzw. Turing-Pi-Doku).

## 2. Alle vier Nodes flashen (inkl. Cloud-Init)

```bash
mise run pi-flash -- <bmc-ip> ./ubuntu-server-arm64.img
```

Pro Slot (1–4): kopiert das Image, bettet ein `user-data` mit dem ersten
Key aus dem ssh-agent (User `ubuntu`, passwordless sudo, Passwort-Auth aus)
in die Boot-Partition der Kopie ein, flasht über die BMC. Damit ist jeder
Node ab dem ersten Boot per Pubkey erreichbar — kein manueller
UART-Erstzugang mehr nötig.

Setzt das Standard-Partitionslayout der Ubuntu-"preinstalled-server"-Images
voraus (Partition 1 = `system-boot`, FAT). Anderes Image → Partitionsnummer
in `.mise-tasks/pi-flash` anpassen.

## 3. Erststart

```bash
for n in 1 2 3 4; do
  tpi --host <bmc-ip> power on -n "${n}"
done
```

IPs werden in Schritt 4 automatisch gefunden — manuelles Notieren nur als
Fallback nötig (Router-DHCP-Leases oder `tpi --host <bmc-ip> info`).
Boot-Probleme debuggen: serielle Konsole via
`tpi --host <bmc-ip> uart -n <slot> get` (Pflichtargument `get`/`set` — ohne
bricht der Befehl mit „missing required argument" ab).

## 4. ULAs + Domain/Tunnel im Repo hinterlegen

```bash
mise run setup -- pi   # sucht Node-IPs automatisch (Hostnamen pi-node-1..4,
                        # Fallback: manuelle Eingabe), fragt danach eine ULA
                        # je Node + Domain/Gateway-ULA/Tunnel-ID/ACME-E-Mail ab,
                        # schreibt clusters/pi/nodes.env + cluster-settings.yaml
```

Alleinstehende Wiederholung der IP-Suche (z.B. nach DHCP-Lease-Wechsel):
`mise run pi-discover`.

## 5. SSH-Härtung, sudo und statische ULAs per Ansible

Konvergiert alle vier Nodes auf den Zustand, den `cluster-up` erwartet:
Pubkey (wieder frisch aus dem ssh-agent, unabhängig davon was Cloud-Init in
Schritt 2 gesetzt hat) in `authorized_keys`, passwordless sudo, die in
Schritt 4 gewählte Per-Node-ULA als statische Adresse auf dem Node-Interface
(netplan, Default-Interface `eth0` — siehe
`ansible/playbooks/provision-nodes.yml`, falls ein Node ein anderes
Interface nutzt). Der Server-Node bekommt zusätzlich die `GATEWAY_ULA` aus
`cluster-settings.yaml` als zweite Adresse auf demselben Interface (bewusst
nur ein Node, sonst schlägt IPv6 Duplicate Address Detection zu).

```bash
mise run pi-provision
```

Idempotent — mehrfach laufen lassen (z.B. nach Austausch eines Moduls oder
Key-Rotation) ist unproblematisch.

## 6. Übergabe an die bestehende Bootstrap-Kette

```bash
mise run cluster-up -- pi   # Chrony + k3s via SSH
# ... weiter wie im README: cilium-up, flux-bootstrap
```

Details und Split-Horizon-/Gateway-Setup (Gateway-ULA, Cloudflare-Tunnel):
siehe [README](../../README.md#pi-cluster-ipv6-only-gateway--split-horizon).
