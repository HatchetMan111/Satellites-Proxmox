#!/usr/bin/env bash
# =============================================================================
#  🛰️  Satellites – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Satellites-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Satellites (https://github.com/dev-Armaan/satellites): eine lokale
#  Satelliten-Tracking-Web-App – TLE-Daten von CelesTrak, Live-Position
#  der ISS, Positionsabfrage pro NORAD-ID.
#
#  Architektur im Container:
#    - FastAPI-Backend (Python) servt /api/* (TLE-Cache, Bahnberechnung)
#    - React/Vite-Frontend (vom Installer gebaut, statisch via FastAPI)
#    - systemd-Service satellites.service (Restart=always, Boot-Start)
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 1024 --port 8020
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"
APP_NAME="satellites"
# Die App liegt in DIESEM Repo unter app/ (backend/ + frontend/) – NICHT bei
# dev-Armaan/satellites (das ist eine andere TypeScript-App ohne Python).
UPSTREAM_OWNER="HatchetMan111"
UPSTREAM_REPO="Satellites-Proxmox"
UPSTREAM_BRANCH="main"      # Update-Quelle; für einen Fixpin hier z. B. einen Commit-Hash eintragen
UPSTREAM_TARBALL_URL="https://codeload.github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/tar.gz/refs/heads/${UPSTREAM_BRANCH}"
NODE_MAJOR=22               # Build-Werkzeug (Vite)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="satellites"
CT_STORAGE="local-lvm"
CT_ROOTFS=4                 # GB – Debian + Python + node_modules
CT_CORES=2
CT_MEMORY=1024              # MB
CT_SWAP=512                 # MB Puffer für den Build-Spike
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
PORT=8020                   # Web-UI-Port im Container
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + satellites), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + satellites-Service):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/satellites-setup.log 2>/dev/null
            echo "--- journalctl -u satellites ---"
            journalctl -u satellites --no-pager 2>/dev/null | tail -n 25
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # Echtes `pct list`: Spalte 1 = VMID, 2 = Status, 3 = Lock, 4 = Name –
    # die Spaltenzahl/-lage VARIIERT aber (Lock oft leer, v. a. bei LXCs).
    # Deshalb NICHT eine feste Spalte, sondern der Hostname als eigenes
    # (durch Leerraum begrenztes) Wort in der Zeile.
    pct list 2>/dev/null \
        | awk -v h="${1:-}" 'NR>1 && $1 ~ /^[0-9]+$/ && $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") {found=1} END {exit !found}'
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # Hostname als eigenes Wort in der pct list-Zeile suchen (Spaltenlage
    # variiert: VMID/Status/Lock/Name, Lock bei LXCs oft leer). NR>1
    # ueberspringt die Kopfzeile; $1 muss eine Zahl sein (echte CT-Zeile).
    pct list 2>/dev/null \
        | awk -v h="$CT_HOSTNAME" 'NR>1 && $1 ~ /^[0-9]+$/ && $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Tarball + Node-Repo brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts codeload.github.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts codeload.github.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).
  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1
  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt im systemd-Service.
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$PORT' (1–65535 erwartet, z. B. --port 8020)"
    fi
}

print_help() {
    cat <<'EOF'
🛰️  Satellites – Proxmox-Installer (lokale Satelliten-Tracking-Web-App)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Satellites-Proxmox/main/install/satellites.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: satellites)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 4)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 1024)
  --swap MB        Swap (Default: 512)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Web-UI-Port im Container (Default: 8020)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         App im bestehenden Container aktualisieren (neu bauen aus Upstream main)
  --uninstall      Container stoppen und löschen
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (PORT, URLs, Node/Python-Version) kommen als Umgebungsvariablen
# via `pct exec -- env …` in den Container. Das vermeidet Escaping-Gruben.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Satellites In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: PORT, HOST_DNS, UPSTREAM_TARBALL_URL, NODE_MAJOR
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }

: "${PORT:?PORT fehlt (env)}"
: "${HOST_DNS:?HOST_DNS fehlt (env)}"
: "${UPSTREAM_TARBALL_URL:?UPSTREAM_TARBALL_URL fehlt (env)}"
: "${NODE_MAJOR:?NODE_MAJOR fehlt (env)}"

echo ">>> Pakete installieren (python3, venv, curl, ca-certificates) ..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl ca-certificates >/dev/null

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Satellites: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Node.js ${NODE_MAJOR} installieren (nur Build-Werkzeug) ..."
curl -fsSL --retry 3 "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource-setup.sh
bash /tmp/nodesource-setup.sh >/dev/null
apt-get install -y -qq nodejs >/dev/null
hash -r

echo ">>> Python-Version prüfen (>= 3.10 erforderlich) ..."
PY_VER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
echo "    Python $PY_VER"

echo ">>> Satellites-Quellcode von GitHub laden (Repo: ${UPSTREAM_TARBALL_URL}) ..."
mkdir -p /opt/satellites
curl -fSL --retry 3 "${UPSTREAM_TARBALL_URL}" -o /tmp/satellites.tar.gz
rm -rf /tmp/satellites-src && mkdir -p /tmp/satellites-src
tar -xzf /tmp/satellites.tar.gz -C /tmp/satellites-src --strip-components=1
# Der Tarball enthält die App unter app/ (backend/ + frontend/) –
# plus install/, systemd/, README etc. (die brauchen wir nicht im CT).
if [ ! -d /tmp/satellites-src/app/backend ]; then
    die "Unerwartete Repo-Struktur: app/backend fehlt im Tarball.
  Erwartet: app/backend/ + app/frontend/ (eigenes Repo). Tarball-Inhalt:
  $(ls /tmp/satellites-src | head -10 | tr '\n' ' ')"
fi
rm -rf /opt/satellites/src && mkdir -p /opt/satellites/src/backend /opt/satellites/src/frontend
cp -a /tmp/satellites-src/app/backend/. /opt/satellites/src/backend/
cp -a /tmp/satellites-src/app/frontend/. /opt/satellites/src/frontend/

echo ">>> Virtuelles Environment anlegen + Python-Abhängigkeiten installieren ..."
python3 -m venv /opt/satellites/.venv
/opt/satellites/.venv/bin/pip install --quiet --upgrade pip
/opt/satellites/.venv/bin/pip install --quiet -r /opt/satellites/src/backend/requirements.txt

echo ">>> Frontend-Abhängigkeiten installieren (npm) ..."
cd /opt/satellites/src/frontend
if [[ -f package-lock.json ]]; then
    npm ci --no-audit --no-fund --loglevel=error
else
    npm install --no-audit --no-fund --loglevel=error
fi

echo ">>> Frontend bauen (vite build) – das dauert 1-2 Minuten ..."
npm run build
if [[ ! -f /opt/satellites/src/backend/static/index.html ]]; then
    die "Build fehlgeschlagen: /opt/satellites/src/backend/static/index.html fehlt (vite-Ausgabe oben ansehen)."
fi

echo ">>> systemd-Service installieren (User satellites, Restart=always) ..."
id -u satellites &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin satellites
cat > /etc/systemd/system/satellites.service <<UNITEOF
[Unit]
Description=Satellites – lokale Satelliten-Tracking-Web-App
Documentation=https://github.com/HatchetMan111/Satellites-Proxmox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=satellites
Group=satellites
WorkingDirectory=/opt/satellites/src/backend
EnvironmentFile=/opt/satellites/.env.runtime
ExecStart=/opt/satellites/.venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
UNITEOF

# .env.runtime: Defaults, die die App beim Start liest (siehe backend/main.py).
# Keine Secrets – nur Konfiguration.
cat > /opt/satellites/.env.runtime <<ENVEOF
SAT_TLE_CACHE_TTL=3600
SAT_HTTP_TIMEOUT=20
ENVEOF
chown -R satellites:satellites /opt/satellites

echo ">>> Service aktivieren + starten ..."
systemctl daemon-reload
systemctl enable satellites
systemctl restart satellites

echo ">>> Prüfe, dass der Service auf Port ${PORT} lauscht ..."
PORT_OK=""
for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/api/health"; then
        PORT_OK=1
        break
    fi
    sleep 1
done
if [ -z "$PORT_OK" ]; then
    die "satellites-Service lauscht nach Start nicht auf Port ${PORT}.\n  Debug: journalctl -u satellites -e && ss -tlnp | grep ${PORT}"
fi

echo ">>> Aufräumen ..."
rm -rf /tmp/satellites-src /tmp/satellites.tar.gz /tmp/nodesource-setup.sh

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere App im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden.
    pct exec "$ct_id" -- env PORT="$PORT" HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        UPSTREAM_TARBALL_URL="$UPSTREAM_TARBALL_URL" NODE_MAJOR="$NODE_MAJOR" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/satellites-setup.log'
}

get_installed_version() {
    # Version aus der installierten package.json (Frontend) – || true INNERHALB
    # von $() (Grube: pipefail + pct-exec-Fehlschlag würde die Substitution töten).
    local v=""
    v=$(pct exec "$1" -- sh -c 'cat /opt/satellites/src/frontend/package.json 2>/dev/null | grep -m1 "\"version\"" | grep -o "[0-9][^\"]*"' 2>/dev/null | tail -n 1 || true)
    echo "$v"
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # satellites-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet satellites 2>/dev/null; then
            ok "Service satellites läuft (Web/API auf Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service satellites läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u satellites -e"
        fi
        sleep 1
    done

    # Frontend-Build vorhanden?
    if pct exec "$ct_id" -- test -f /opt/satellites/src/backend/static/index.html 2>/dev/null; then
        ok "Produktions-Build vorhanden (/opt/satellites/src/backend/static/index.html)"
    else
        die "static/index.html fehlt im Container – Build schlug fehl.\n  Debug: pct exec $ct_id -- tail -n 50 /var/log/satellites-setup.log"
    fi

    # Web-UI antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits 000 aus –
    # NIE zusätzlich || echo 000 anhängen, sonst wird der Check falsch-positiv.)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${PORT}/api/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI antwortet (HTTP 200 auf http://127.0.0.1:${PORT}/api/health)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            # Selbst-Diagnose: der häufigste Fall ist ein abgestürzter uvicorn
            # (fehlende Abhängigkeit, falscher Port).
            local diag
            diag=$(pct exec "$ct_id" -- sh -c '
                echo "--- Listener auf Port '"$PORT"' (ss -tlnp) ---"
                ss -tlnp 2>/dev/null | grep -E "[:.]'"$PORT"'" || echo "  (KEIN Listener auf Port '"$PORT"')"
                echo "--- journalctl -u satellites (letzte Zeilen) ---"
                journalctl -u satellites --no-pager 2>/dev/null | tail -n 12 || true
            ' 2>/dev/null || true)
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).

${diag}
  Debug: pct exec $ct_id -- journalctl -u satellites -e"
        fi
        sleep 1
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${PORT}/api/health" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🛰️  Satellites ist bereit!"

    local ct_ip installed_version=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi
    installed_version=$(get_installed_version "$CT_ID")

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Satellites:  http://${ct_ip}:${PORT}${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:    pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:     ${CT_PASSWORD}${NC}"
    fi
    if [[ -n "$installed_version" ]]; then
        echo -e "  ${GREEN}  📦 Version:     v${installed_version} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_BRANCH})${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer:   v${INSTALLER_VERSION}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Sobald die App läuft:${NC}"
    echo "  1. http://${ct_ip}:${PORT} öffnen"
    echo "  2. Die ISS-Position wird live angezeigt (alle 10 s aktualisiert)"
    echo "  3. Über die Liste einen Satelliten auswählen → Position anzeigen"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u satellites -f"
    echo ""
    warn "Satellites bezieht TLE-Daten von CelesTrak (einmalig beim Start/Refresh)"
    warn "(Cache: 1 h, danach offline-fähig aus dem Cache)."
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🛰️  Installiere Satellites (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen
    header "🧱 Container-Template"
    local template=""
    # Robust gegen Versions-Suffixe: Templates heißen "debian-12-standard" ODER
    # "debian-12.12-standard_..." – wir matchen auf beides (grep -E) und
    # sortieren nach Version, die höchste gewinnt.
    if ! pveam list local 2>/dev/null | grep -qE "debian-12[^ ]*standard"; then
        info "Kein Debian-12-Template vorhanden – lade es herunter ..."
        pveam update
        local tpl
        tpl=$(pveam available 2>/dev/null | grep -E "debian-12[^ ]*standard" | tail -1 | awk '{print $2}')
        if [[ -z "$tpl" ]]; then
            die "Kein Debian-12-Template in pveam available gefunden.
  Prüfe: pveam available | grep debian-12"
        fi
        pveam download local "$tpl"
    fi
    template=$(pveam list local 2>/dev/null | grep -E "debian-12[^ ]*standard" | sort -V | tail -1 | awk '{print $1}')
    if [[ -z "$template" ]]; then
        die "Kein Debian-12-Template gefunden – bitte prüfen: pveam list local"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="sat-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "$template" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update Satellites (neues Upstream-Build)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – TLE-Cache blieb erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere Satellites"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "TLE-Cache und alle Konfiguration liegen im Container – hier geht nur der Container verloren."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id gelöscht."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status Satellites"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    # Gestoppten CT nicht als "satellites läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)

    pct list 2>/dev/null | awk -v id="$ct_id" -v st="$state" -v hn="$CT_HOSTNAME" \
        '$1==id {print "Container:  " $1 " (" hn ") – " st}'

    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Version/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet satellites 2>/dev/null; then
        ok "Service:   satellites läuft (Web/API auf Port $PORT)"
    else
        err "Service:   satellites läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u satellites -e"
    fi

    local installed_version=""
    installed_version=$(get_installed_version "$ct_id")
    if [[ -n "$installed_version" ]]; then
        info "Version:   v${installed_version} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${UPSTREAM_BRANCH})"
    else
        warn "Version:   nicht ermittelbar (App installiert?)"
    fi

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${PORT}/api/health" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    http://${ip}:${PORT}  (HTTP 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi