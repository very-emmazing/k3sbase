# TESTPLAN – Pi-Cluster: Split-Horizon-Routing (Tunnel + ULA)

End-to-End-Tests der Routing-Kette über beide Zugriffspfade. Platzhalter:
`<domain>` = `PI_DOMAIN`, `<gateway-ula>` = `GATEWAY_ULA` aus
`clusters/pi/cluster-settings.yaml`.

## 0. Vorbedingungen (auf dem Admin-Rechner)

```bash
export KUBECONFIG=.kube/pi-config

flux get kustomizations         # gateway-api-crds, infrastructure, apps: Ready=True
kubectl -n echo get gateway web-gateway
kubectl -n echo get svc cilium-gateway-web-gateway
kubectl -n echo get certificate echo-wildcard-tls
kubectl -n cloudflared get pods
```

**Erfolgreich:** alle Kustomizations `Ready`, Gateway `PROGRAMMED=True`,
der Service `cilium-gateway-web-gateway` hat als EXTERNAL-IP exakt die
`<gateway-ula>`, das Zertifikat ist `READY=True`, beide cloudflared-Pods
`Running` (Log: „Registered tunnel connection").

**Gescheitert:** Gateway `PROGRAMMED=False` (→ `kubectl describe gateway`,
meist fehlende CRDs oder certificateRef), EXTERNAL-IP `<pending>`
(→ CiliumLoadBalancerIPPool prüfen), Certificate not ready
(→ `kubectl describe certificaterequest -n echo`, meist Cloudflare-Token),
cloudflared CrashLoop (→ Credentials-Secret leer/nicht entschlüsselbar).

## 1. Externer Pfad: Cloudflare Tunnel

Von einem beliebigen Client **außerhalb** des LAN (z.B. Mobilnetz):

```bash
curl -sv https://echo-a.<domain>/ 2>&1 | grep -E 'HTTP/|Name:'
```

**Erfolgreich:** HTTP `200`, Response-Body enthält `Name: echo-a`
(traefik/whoami). Das TLS-Zertifikat, das der Client sieht, kommt von
Cloudflare (Edge); die Origin-Verbindung cloudflared → Gateway ist separat
TLS-verifiziert gegen das cert-manager-Zertifikat.

**Gescheitert:**
- `NXDOMAIN` → external-dns hat den CNAME nicht angelegt
  (`kubectl -n external-dns logs deploy/external-dns`; Annotationen am
  Service `cloudflared-tunnel-cname` prüfen).
- HTTP `530`/Cloudflare-Fehlerseite 1033 → Tunnel nicht verbunden
  (cloudflared-Pods/Logs prüfen; `TUNNEL_ID` vs. Credentials).
- HTTP `502` → cloudflared erreicht das Gateway nicht oder
  **TLS-Verifikation gescheitert** (Zertifikat nicht ready, Staging-Issuer
  statt Prod, oder `originServerName` passt nicht zum Hostnamen). Log-Zeile
  in cloudflared: `tls: failed to verify certificate`.
- HTTP `404` → Ingress-Regel matcht nicht (Hostname-Tippfehler in
  `cloudflared-config`) **oder** HTTPRoute matcht nicht (siehe Test 3).

## 2. Interner Pfad: Gateway-ULA (LAN)

Von einem Client **im LAN**. Zuerst ohne DNS-Abhängigkeit direkt gegen die
ULA (prüft Routing + TLS unabhängig vom internen DNS):

```bash
curl -sv --resolve "echo-a.<domain>:443:[<gateway-ula>]" https://echo-a.<domain>/ 2>&1 | grep -E 'HTTP/|Name:|subject|issuer'
```

**Erfolgreich:** HTTP `200`, Body enthält `Name: echo-a`, Zertifikat
`subject: CN=*.<domain>`, `issuer: … Let's Encrypt` – **ohne** `-k`/
`--insecure`. Damit ist bewiesen: NDP/Routing zur ULA, Cilium-eBPF-Forwarding
zum Envoy, TLS-Terminierung mit gültigem Zertifikat.

Danach mit internem DNS (Fritzbox/Pi-hole-Eintrag aktiv):

```bash
dig AAAA echo-a.<domain> +short   # muss <gateway-ula> liefern, NICHT Cloudflare
curl -s https://echo-a.<domain>/ | grep Name:
```

**Gescheitert:**
- Timeout → ULA nicht am Node-Interface konfiguriert, Client nicht im
  selben L2/ohne Route, oder LB-IP nicht zugewiesen (Test 0).
- `connection refused` → Cilium-eBPF forwardet nicht
  (`kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep
  <gateway-ula>` muss einen Eintrag für Port 443 zeigen).
- Zertifikatsfehler → Certificate not ready oder falsche SNI.
- `dig` liefert Cloudflare-IPs → interner DNS-Override fehlt; der Traffic
  nähme den Tunnel-Umweg (funktioniert, verfehlt aber den Zweck).

## 3. HTTPRoute-Hostname-Matching (≥ 2 Hostnamen)

Über einen der beiden Pfade (intern gezeigt; extern analog ohne `--resolve`):

```bash
curl -s --resolve "echo-a.<domain>:443:[<gateway-ula>]" https://echo-a.<domain>/ | grep Name:
curl -s --resolve "echo-b.<domain>:443:[<gateway-ula>]" https://echo-b.<domain>/ | grep Name:
curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve "echo-c.<domain>:443:[<gateway-ula>]" https://echo-c.<domain>/
```

**Erfolgreich:**
- `echo-a.<domain>` → `Name: echo-a`
- `echo-b.<domain>` → `Name: echo-b`
- `echo-c.<domain>` (keine HTTPRoute) → `404` – der Wildcard-Listener nimmt
  den Request an, aber keine Route matcht.

**Gescheitert:** beide Hostnames landen beim selben Backend (`Name:` gleich)
→ HTTPRoute-`hostnames` prüfen; `echo-c` liefert `200` → eine Route matcht
zu breit (z.B. Route ohne `hostnames`-Einschränkung).

## 4. Split-Horizon-Nachweis

Beide Pfade liefern denselben Inhalt, aber über unterschiedliche Wege:

```bash
# LAN-Client, interner Pfad: RemoteAddr im whoami-Output ist eine Pod-/Node-
# Adresse aus dem ULA-Bereich (fd00:…), kein Cloudflare-Header
curl -s --resolve "echo-a.<domain>:443:[<gateway-ula>]" https://echo-a.<domain>/

# Externer Pfad: Response enthält Cloudflare-Header (Cf-Ray, Cf-Connecting-Ip
# im whoami-Echo der Request-Header)
curl -s https://echo-a.<domain>/
```

**Erfolgreich:** interner Response **ohne** `Cf-Ray`-Header im Header-Echo,
externer **mit**. Damit ist belegt, dass LAN-Traffic nicht über den Tunnel
läuft.
