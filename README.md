# 🛰️ Satellites – Proxmox-Installer

Lokale Satelliten-Tracking-Web-App als **LXC-Container** auf Proxmox VE –
installiert mit einem Einzeiler im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Die App ([dev-Armaan/satellites](https://github.com/dev-Armaan/satellites)) zeigt
TLE-Daten von CelesTrak, die Live-Position der ISS und Positionsabfragen pro
NORAD-ID. Sie läuft vollständig lokal (FastAPI-Backend + React/Vite-Frontend).

## Installation (Einzeiler auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)"
```

Mit Optionen (direkt hinter dem schließenden Anführungszeichen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)" --id 210 --memory 1024
```

Der Installer:

- erstellt selbstständig einen **unprivilegierten LXC-Container** (CT-ID wählbar, Standard: nächste freie ab 200; 2 vCPU, 1 GB RAM, 4 GB Disk)
- installiert alle Abhängigkeiten (Python-venv, Node für den Build) und die App
- baut das React/Vite-Frontend und richtet einen **systemd-Service** (`satellites.service`, `Restart=always`, `After=network-online.target`) ein
- ist **idempotent** (erkennt vorhandene Container, `--force` zum Neuanlegen)
- prüft am Ende selbst: Service aktiv, Web UI antwortet (HTTP 200), URL + Container-IP

### Optionen

| Option | Bedeutung |
|---|---|
| `--id ID` | Container-ID (Default: nächste freie ab 200) |
| `--hostname NAME` | Container-Hostname (Default: satellites) |
| `--storage NAME` | Storage für rootfs (Default: local-lvm) |
| `--rootfs GB` | Disk-Größe (Default: 4) |
| `--cores N` | vCPUs (Default: 2) |
| `--memory MB` | RAM (Default: 1024) |
| `--swap MB` | Swap (Default: 512) |
| `--bridge BR` | Netzwerk-Bridge (Default: vmbr0) |
| `--ip CIDR` | Feste IP statt DHCP (+ `--gateway`) |
| `--gateway GW` | Gateway für statische IP |
| `--password PW` | Root-Passwort (Default: generiert) |
| `--sshkey PFAD\|URL` | Public-Key für ssh-key-Login als root |
| `--port PORT` | Web-UI-Port im Container (Default: 8020) |
| `--force` | Vorhandenen Container mit gleichem Hostname löschen und neu anlegen |
| `--yes` / `-y` | Rückfragen überspringen |
| `--update` | App im bestehenden Container aktualisieren (Upstream main) |
| `--uninstall` | Container stoppen und löschen |
| `--status` | Status anzeigen |
| `--debug` | Vollständiges `bash -x`-Trace |

## Web UI

Nach der Installation: `http://<CONTAINER-IP>:8020`

Die App verbindet sich beim Start/Refresh mit CelesTrak (TLE-Cache 1 h) –
danach läuft sie offline-fähig aus dem Cache.

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)" --update
```

Baut die App aus dem aktuellen Upstream-Stand neu (Frontend + Backend),
startet den Service neu und behält den TLE-Cache.

## Deinstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)" --uninstall
```

Stoppt und löscht den Container (Rückfrage; `--yes` überspringt sie).

## Status / Logs

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)" --status
pct exec <CT-ID> -- journalctl -u satellites -f
```

## Aufbau

```
Satellites-Proxmox/
├── install/satellites.sh      # Proxmox-Einzeiler-Installer (Community-Scripts-Stil)
├── systemd/satellites.service # systemd-Unit (Referenz; der Installer schreibt sie identisch)
├── app/backend/               # FastAPI (TLE-Cache, Bahnberechnung, API)
├── app/frontend/              # React/Vite (Build → app/backend/static/)
├── test/mock-harness.sh       # Mock-Harness (pct/git/pveam) ohne echten Proxmox-Host
└── README.md
```

## Tests

```bash
bash -n install/satellites.sh
shellcheck install/satellites.sh
bash test/mock-harness.sh
```