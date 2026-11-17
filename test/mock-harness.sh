#!/usr/bin/env bash
# =============================================================================
# Mock-Harness für install/satellites.sh
# =============================================================================
# Testet die Host-Seite des Installers (Argumente, pct create, In-Container-Setup,
# Verifikation, Update, Status, Uninstall) mit gemocktem pct/git/pveam —
# ohne echten Proxmox-Host, ohne sudo.
#
# Nutzung:
#   bash test/mock-harness.sh            # alle Tests
#   bash test/mock-harness.sh --verbose  # mehr Ausgabe
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/install/satellites.sh"
export REPO_ROOT
WORK_DIR="$(mktemp -d)"
MOCK_BIN="$WORK_DIR/mock-bin"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

green() { printf '\033[0;32m%s\033[0m' "$1"; }
red()   { printf '\033[0;31m%s\033[0m' "$1"; }
pass()  { PASS=$((PASS+1)); echo "  $(green PASS)  $1"; }
fail()  { FAIL=$((FAIL+1)); echo "  $(red FAIL)  $1"; }

# ── Mock-Umgebung aufbauen ──────────────────────────────────────────────────
setup_mocks() {
    mkdir -p "$MOCK_BIN"
    # pct: list, create, start, status, exec, push, stop, destroy, config
    cat > "$MOCK_BIN/pct" <<'MOCKPCT'
#!/usr/bin/env bash
# state file: $MOCK_STATE_DIR/<id>.status, .ip, .service-active, .static
STATE="${MOCK_STATE_DIR:-/tmp/mock-pct}"
mkdir -p "$STATE"
case "$1" in
    list)
        # Echtes pct list hat KEINE Kopfzeile – direkt die CT-Zeilen ausgeben.
        if [ -f "$STATE/list.txt" ]; then cat "$STATE/list.txt"; fi
        ;;
    create)
        id="$2"
        echo "$id" > "$STATE/next_id"
        echo "running" > "$STATE/$id.status"
        echo "10.0.0.$id" > "$STATE/$id.ip"
        # In die CT-Liste eintragen, damit Status/Update/Idempotenz ihn sehen.
        # Echtes pct list-Format: VMID(1) NAME(2) STATUS(3) MEM(4) BOOTDISK(5) PID(6)
        echo "$id satellites running 1024 1234 5678" >> "$STATE/list.txt"
        # Netzwerkgabe simulieren
        echo "eth0: 10.0.0.$id/24"
        ;;
    start)
        echo "running" > "$STATE/$2.status"
        ;;
    stop)
        echo "stopped" > "$STATE/$2.status"
        # In list.txt auf stopped setzen (Spalte 3)
        if [ -f "$STATE/list.txt" ]; then
            sed -i "s/\($2 [^ ]*\) running/\1 stopped/" "$STATE/list.txt"
        fi
        ;;
    destroy)
        if [ -f "$STATE/list.txt" ]; then
            sed -i "/^$2 /d" "$STATE/list.txt"
        fi
        rm -f "$STATE/$2.status" "$STATE/$2.ip" "$STATE/$2.service-active" "$STATE/$2.static"
        ;;
    status)
        echo "status: $(cat "$STATE/$2.status" 2>/dev/null || echo unknown)"
        ;;
    exec)
        id="$2"; shift 2
        # pct exec <id> [--] [env VAR=.. ..] CMD args...
        if [ "${1:-}" = "--" ]; then shift; fi
        # env-Praxis: pct exec <id> -- env VAR=x ... CMD -> Variablen übernehmen
        if [ "${1:-}" = "env" ]; then
            shift
            # "*.=*" statt "*=*": der Loop muss bei "PORT=8020" weiterlaufen
            # (endet NICHT mit '='), sonst wird der erste Env-Eintrag als cmd gelesen.
            while [[ $# -gt 0 && "$1" == *=* ]]; do export "$1"; shift; done
        fi
        cmd="${1:-}"
        shift || true
        case "$cmd" in
            hostname)
                cat "$STATE/$id.ip" 2>/dev/null || echo "10.0.0.$id"
                ;;
            systemctl)
                case "${1:-}" in
                    is-active)
                        # echtes `systemctl is-active --quiet` gibt bei aktivem
                        # Service NICHTS aus (Exit 0); inaktiv -> "inactive" + Exit 3
                        if [ -f "$STATE/$id.service-active" ]; then
                            exit 0
                        else
                            echo "inactive"
                            exit 3
                        fi
                        ;;
                    restart|enable|daemon-reload)
                        touch "$STATE/$id.service-active"
                        ;;
                esac
                ;;
            getent)
                if [ -f "$STATE/$id.dns-broken" ]; then exit 2; fi
                exit 0
                ;;
            bash)
                # bash -c 'set -o pipefail; bash /root/setup-inner.sh ...'
                # -> Setup simulieren: Repo da, Frontend gebaut (static/), Service aktiv.
                mkdir -p "$STATE/$id.opt/satellites/src/backend/static/assets"
                echo '<html><body>mock frontend</body></html>' > \
                    "$STATE/$id.opt/satellites/src/backend/static/index.html"
                # package.json für get_installed_version
                mkdir -p "$STATE/$id.opt/satellites/src/frontend"
                echo '{"name":"satellites","version":"1.0.0"}' > \
                    "$STATE/$id.opt/satellites/src/frontend/package.json"
                echo "mock: setup-inner.sh ausgeführt (inkl. npm build)"
                touch "$STATE/$id.service-active"
                touch "$STATE/$id.static"
                ;;
            sh)
                # get_installed_version: sh -c 'cat .../package.json | grep ...'
                if [ -f "$STATE/$id.opt/satellites/src/frontend/package.json" ]; then
                    echo "1.0.0"
                else
                    echo "mock: sh-befehl"
                fi
                ;;
            curl)
                echo "200"
                ;;
            journalctl)
                echo "mock: keine logs"
                ;;
            sh)
                echo "mock: sh-befehl"
                ;;
            *)
                echo "mock pct-exec($id): $cmd $*"
                ;;
        esac
        ;;
    push)
        # pct push <id> <local> <remote> – lokal nach "$STATE/pushed/" kopieren
        id="$2"; local_f="$3"; remote_f="$4"
        mkdir -p "$STATE/pushed"
        cp -r "$local_f" "$STATE/pushed/" 2>/dev/null || true
        echo "mock: pct push $id $local_f -> $remote_f"
        ;;
    config)
        echo "mock: config $2"
        ;;
    *)
        echo "mock pct: $*" >&2
        exit 0
        ;;
esac
MOCKPCT
    chmod +x "$MOCK_BIN/pct"

    # git: clone/fetch/checkout/reset/clean/rev-parse simulieren
    cat > "$MOCK_BIN/git" <<'MOCKGIT'
#!/usr/bin/env bash
case "$1" in
    clone)
        # clone <url> <dir> oder --depth 1 --branch <ref> <url> <dir>
        shift
        while [[ "$1" == -* ]]; do
            if [ "$1" = "--branch" ]; then shift 2; else shift; fi
        done
        # $1 = url, $2 = target (oder $1 = target falls --depth Variante)
        target="${@: -1}"
        mkdir -p "$target/.git" "$target/app/backend" "$target/app/frontend"
        echo "mock-repo" > "$target/app/backend/main.py"
        echo '{"name":"satellites","version":"1.0.0"}' > "$target/app/frontend/package.json"
        echo "mock-commit-123" > "$target/.git/MOCK_COMMIT"
        ;;
    -C)
        # git -C <dir> <cmd> ...
        dir="$2"; shift 2
        case "$1" in
            rev-parse) echo "abc1234" ;;
            fetch|checkout|reset|clean) ;;  # ok
            *) echo "mock git -C: $*" ;;
        esac
        ;;
    *)
        echo "mock git: $*" ;;
esac
MOCKGIT
    chmod +x "$MOCK_BIN/git"


    # pveam: Template-Liste (list local / available / download simulieren)
    cat > "$MOCK_BIN/pveam" <<'MOCKPVEAM'
#!/usr/bin/env bash
case "$1" in
    list)
        # list local: Template + CTs (Name in Spalte 1)
        echo "local:vztmpl/debian-12.12-standard_amd64.tar.zst"
        ;;
    available)
        echo "debian-12.12-standard_amd64.tar.zst"
        ;;
    update|download)
        ;;
    *)
        echo "mock pveam: $*"
        ;;
esac
MOCKPVEAM
    chmod +x "$MOCK_BIN/pveam"

    # pvesh: vom Installer geprüft (Existenz), aber nicht genutzt
    cat > "$MOCK_BIN/pvesh" <<'MOCKPVESH'
#!/usr/bin/env bash
echo "mock pvesh: $*"
MOCKPVESH
    chmod +x "$MOCK_BIN/pvesh"

    # npm/node Fallback-Mocks (falls Host-node genutzt würde)
    cat > "$MOCK_BIN/npm" <<'MOCKNPM'
#!/usr/bin/env bash
echo "mock npm: $*"
MOCKNPM
    chmod +x "$MOCK_BIN/npm"
    cat > "$MOCK_BIN/node" <<'MOCKNODE'
#!/usr/bin/env bash
echo "mock node: $*"
MOCKNODE
    chmod +x "$MOCK_BIN/node"

    # State-Dir anlegen (pct-Mock liest/schreibt hier CT-Listen)
    mkdir -p "$WORK_DIR/mock-state"
    # Absolute Pfade exportieren: unshare -rm (root-Simulation) startet eine
    # NEUE Session – relative Pfade würden dort ins Nichts zeigen.
    export PATH="$MOCK_BIN:$PATH"
    local state_dir
    state_dir="$(cd "$WORK_DIR/mock-state" && pwd)"
    export MOCK_STATE_DIR="$state_dir"
}

# ── Main ────────────────────────────────────────────────────────────────────
setup_mocks

# Root simulieren: Der Installer verlangt EUID 0 (pct create etc.). In der
# Sandbox gibt es kein sudo – wir mappen den User per user-namespace auf root
# (unshare -rm), damit der getestete Pfad exakt der Production-Pfad ist.
RUN_PREFIX=(bash "$INSTALLER")
if [[ "$(id -u)" -ne 0 ]] && command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
    RUN_PREFIX=(unshare -rm bash "$INSTALLER")
fi

echo "🧪 Mock-Harness satellites.sh"
echo "   Installationsverzeichnis: $INSTALLER"
echo

# Startzustand: KEIN CT vorhanden (pct list-Mock liest list.txt, das hier
# leer bleibt) – der Happy-Path legt CT 200 selbst an.
mkdir -p "$MOCK_STATE_DIR"
: > "$MOCK_STATE_DIR/list.txt"

test_help() {
    echo "→ --help"
    local out
    out=$("${RUN_PREFIX[@]}" --help 2>&1)
    if [[ "$out" == *"Satellites"* && "$out" == *"--update"* ]]; then
        pass "--help zeigt Titel + Optionen"
    else
        fail "--help Ausgabe unerwartet"
    fi
}

test_status_not_found() {
    echo "→ --status (kein CT)"
    local out
    out=$("${RUN_PREFIX[@]}" --status 2>&1) || true
    if [[ "$out" == *"Kein Container"* ]]; then
        pass "--status ohne CT: saubere Meldung"
    else
        fail "--status ohne CT: '$out'"
    fi
}

test_install_happy() {
    echo "→ Install (happy path, In-Container-Build-Mock)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --yes --hostname satellites 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "Install exit 0"
    else
        fail "Install exit $rc – Ausgabe: $out"
        return
    fi
    if [[ "$out" == *"Container 200 erstellt"* ]]; then
        pass "pct create 200 aufgerufen"
    elif [[ "$out" == *"Container 201 erstellt"* ]]; then
        pass "pct create 201 aufgerufen (IDScan ab 200, da list.txt 200 belegt)"
    else
        fail "CT nicht gemeldet: $(echo "$out" | grep -o 'Container [0-9]* erstellt' | head -1)"
    fi
    if [[ "$out" == *"Frontend gebaut"* || "$out" == *"setup-inner.sh"* || "$out" == *"App installiert"* || "$out" == *"static/index.html"* ]]; then
        pass "In-Container-Setup (inkl. Frontend-Build) lief durch"
    else
        fail "In-Container-Setup nicht gemeldet: $(echo "$out" | grep -iE "frontend|setup-inner|static" | head -3)"
    fi
    if [[ "$out" == *"HTTP 200"* ]]; then
        pass "Verifikation HTTP 200"
    else
        fail "HTTP-Verifikation nicht gemeldet: $(echo "$out" | grep -i http | head -3)"
    fi
    if [[ "$out" == *"Satellites ist bereit"* ]]; then
        pass "Summary-Box ausgegeben"
    else
        fail "Summary fehlt"
    fi
    if [[ "$out" == *"Web-UI:        http://"* || "$out" == *"Satellites:  http://"* ]]; then
        pass "Web-UI-URL in Summary"
    else
        fail "Web-UI-URL fehlt in Summary"
    fi
}

test_install_idempotent() {
    echo "→ Install erneut (gleicher Hostname → Abbruch ohne --force)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --yes --hostname satellites 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 && "$out" == *"existiert bereits"* ]]; then
        pass "zweiter Install ohne --force bricht sauber ab"
    else
        fail "Idempotenz-Bruch (rc=$rc): $(echo "$out" | tail -2)"
    fi
}

test_update() {
    echo "→ --update"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --update --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "--update exit 0"
    else
        fail "--update exit $rc – $(echo "$out" | tail -3)"
    fi
    if [[ "$out" == *"App installiert"* || "$out" == *"setup-inner.sh"* || "$out" == *"git"* ]]; then
        pass "--update aktualisiert App (In-Container-Setup)"
    else
        fail "--update: Update-Meldung fehlt"
    fi
}

test_status_running() {
    echo "→ --status (CT läuft)"
    local out
    out=$("${RUN_PREFIX[@]}" --status 2>&1)
    if [[ "$out" == *"running"* && "$out" == *"Web-UI"* ]]; then
        pass "--status zeigt laufenden CT + Web-UI"
    else
        fail "--status: '$out'"
    fi
}

test_uninstall() {
    echo "→ --uninstall --yes"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --uninstall --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 && "$out" == *"gelöscht"* ]]; then
        pass "--uninstall löscht CT"
    else
        fail "--uninstall (rc=$rc): $(echo "$out" | tail -2)"
    fi
    out=$("${RUN_PREFIX[@]}" --status 2>&1) || true
    if [[ "$out" == *"Kein Container"* ]]; then
        pass "--status nach uninstall: kein CT"
    else
        fail "--status nach uninstall: '$out'"
    fi
}

test_invalid_port() {
    echo "→ --port abc (Validierung)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --port abc --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 && "$out" == *"Ungültiger Port"* ]]; then
        pass "ungültiger Port → sauberer Abbruch"
    else
        fail "Port-Validierung: '$out'"
    fi
}

test_help
test_status_not_found
test_install_happy
test_install_idempotent
test_update
test_status_running
test_uninstall
test_invalid_port

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ergebnis: $(green "$PASS passed") / $(red "$FAIL failed")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "$FAIL" -eq 0 ]]