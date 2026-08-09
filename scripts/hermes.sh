#!/usr/bin/env bash
set -euo pipefail

# Fully-Dockerized live stack orchestrator.
#
# Everything (searxng, zen-proxy, health-api, 5 bots, dashboard, retention)
# runs as compose services in docker/docker-compose.yml. init only builds the
# images, seeds per-profile .env files, copies skills, and installs the
# retention cron. No host Hermes install, venvs, or native processes.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$REPO/run"
COMPOSE="$REPO/docker/docker-compose.yml"
BOTS=(master story helldivers money food)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
active()  { echo -e "  ${GREEN}●${NC} $1"; }
inactive(){ echo -e "  ${RED}○${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  init       Build images, seed per-bot .env + skills, set up Tailscale + host tools (opencode, python), install retention cron
  start      Start the whole Docker stack (searxng, proxy, bots, dashboard)
  stop       Stop the Docker stack
  restart    Stop then start
  status     Show all service states
  clean      Wipe everything (profiles state, docker volumes, cron). Destructive.
EOF
}

load_root_env() {
    if [[ -f "$REPO/.env" ]]; then
        set -a; source "$REPO/.env"; set +a
    fi
}

# ────────────────────────────────────────────────────────────
# RETENTION CRON
# ────────────────────────────────────────────────────────────
retention_cron_line() {
    echo "0 3 * * * bash $SCRIPTS_DIR/retention.sh run >> $RUN_DIR/retention.log 2>&1"
}

install_retention_cron() {
    local line cmd
    line="$(retention_cron_line)"
    cmd="$(command -v crontab || true)"
    if [[ -z "$cmd" ]]; then
        warn "crontab not found — install cron or run scripts/retention.sh manually."
        return 0
    fi
    if crontab -l 2>/dev/null | grep -qF "retention.sh run"; then
        info "Retention cron already installed."
    else
        ( crontab -l 2>/dev/null | grep -vF "retention.sh run"; echo "$line" ) | crontab -
        info "Retention cron installed (daily 03:00): $line"
    fi
}

remove_retention_cron() {
    if command -v crontab &>/dev/null; then
        ( crontab -l 2>/dev/null | grep -vF "retention.sh run" ) | crontab - || true
        info "Retention cron removed."
    fi
}

# ────────────────────────────────────────────────────────────
# TAILSCALE (private access to dashboard :9119 + health-api :8001)
# ────────────────────────────────────────────────────────────
_tailscale_online() {
    # Exit 0 when the tailnet is up and authenticated. Try without sudo first,
    # then non-interactive sudo (no prompt spam in the poll loop).
    tailscale status --json 2>/dev/null | python3 -c 'import json,sys
try:
    sys.exit(0 if json.load(sys.stdin).get("Self", {}).get("Online") else 1)
except Exception:
    sys.exit(1)' 2>/dev/null \
        || sudo -n tailscale status --json 2>/dev/null | python3 -c 'import json,sys
try:
    sys.exit(0 if json.load(sys.stdin).get("Self", {}).get("Online") else 1)
except Exception:
    sys.exit(1)' 2>/dev/null
}

_tailscale_ip() {
    local ip
    ip="$(tailscale ip -4 2>/dev/null | head -1)"
    [[ -z "$ip" ]] && ip="$(sudo -n tailscale ip -4 2>/dev/null | head -1)"
    echo "$ip"
}

ensure_tailscale() {
    [[ "${HERMES_NO_TAILSCALE:-0}" == "1" ]] && { info "Tailscale setup skipped (HERMES_NO_TAILSCALE=1)."; return 0; }

    if ! command -v tailscale &>/dev/null; then
        if command -v sudo &>/dev/null; then
            info "Installing Tailscale..."
            curl -fsSL https://tailscale.com/install.sh | sudo sh 2>&1 | sed 's/^/  /' \
                || { warn "Tailscale install failed — install manually: https://tailscale.com/download"; return 1; }
        else
            warn "tailscale not found and sudo unavailable — install manually: https://tailscale.com/download"
            return 1
        fi
    fi

    if ! _tailscale_online; then
        info "Tailscale is not up — starting it and waiting for your browser login (up to 60s)..."
        local out url
        out="$(sudo tailscale up 2>&1 || true)"
        echo "$out" | sed 's/^/  /'
        url="$(echo "$out" | grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9?&=.-]+' | head -1)"
        [[ -n "$url" ]] && info "Log in here: $url"
        for _ in $(seq 1 12); do
            _tailscale_online && break
            sleep 5
        done
        if ! _tailscale_online; then
            warn "Tailscale login not completed — run 'sudo tailscale up' manually, then re-run init."
            return 1
        fi
    fi

    local ip
    ip="$(_tailscale_ip)"
    info "Tailscale up — tailnet IP: ${ip:-<unknown>}"
    info "  dashboard:   http://${ip:-<ip>}:9119"
    info "  health-api:  http://${ip:-<ip>}:8001  (set this as the URL in the Android app)"
}

ensure_tailscale_firewall() {
    [[ "${HERMES_NO_TAILSCALE:-0}" == "1" ]] && return 0
    if ! command -v ufw &>/dev/null; then
        warn "ufw not installed — add firewall rules manually (see README 'Access (Tailscale)')."
        return 0
    fi
    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        warn "ufw is not active — not enabling default-deny automatically (risk of lockout)."
        warn "  To lock down to tailnet-only, run:"
        warn "    sudo ufw default deny incoming"
        warn "    sudo ufw allow 22/tcp"
        warn "    sudo ufw allow in on tailscale0"
        warn "    sudo ufw enable"
        return 0
    fi
    info "Adding tailnet firewall rules (idempotent)..."
    sudo ufw allow in on tailscale0 2>&1 | sed 's/^/  /' || warn "  could not add tailscale0 rule (run with sudo)."
    sudo ufw allow 22/tcp 2>&1 | sed 's/^/  /' || true
}

# ────────────────────────────────────────────────────────────
# HOST TOOLS (opencode CLI, python)
# ────────────────────────────────────────────────────────────
ensure_python() {
    if command -v python3 &>/dev/null &&
        python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
        info "python3 $(python3 --version 2>&1 | sed 's/Python //') available."
        return 0
    fi
    warn "python3 >= 3.9 not found — installing python3 + pip (host tooling)."
    sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv 2>&1 | sed 's/^/  /' \
        || { warn "python install failed — install python3 manually."; return 1; }
    info "python3 installed: $(python3 --version 2>&1)."
}

ensure_opencode() {
    [[ "${HERMES_NO_OPENCODE:-0}" == "1" ]] && { info "opencode install skipped (HERMES_NO_OPENCODE=1)."; return 0; }
    if command -v opencode &>/dev/null; then
        info "opencode already installed ($(opencode --version 2>/dev/null || echo '?'))."
        return 0
    fi
    info "Installing opencode CLI..."
    if ! curl -fsSL https://opencode.ai/install | bash; then
        warn "opencode install failed — install manually: https://opencode.ai/docs/install"
        return 1
    fi
    if ! command -v opencode &>/dev/null; then
        warn "opencode installed but not on PATH — restart the shell or source ~/.bashrc, then re-run init."
        return 1
    fi
    info "opencode installed: $(opencode --version 2>/dev/null)."
}

# ────────────────────────────────────────────────────────────
# INIT
# ────────────────────────────────────────────────────────────
cmd_init() {
    load_root_env
    mkdir -p "$RUN_DIR"

    info "Building Docker images (bot image, zen-proxy, health-api)..."
    docker compose -f "$COMPOSE" build 2>&1 || { error "docker compose build failed."; exit 1; }

    ensure_tailscale || true
    ensure_tailscale_firewall || true
    ensure_python || true
    ensure_opencode || true

    local b
    for b in "${BOTS[@]}"; do
        mkdir -p "$REPO/profiles/$b" "$REPO/workspace/$b"
        if [[ ! -f "$REPO/profiles/$b/.env" ]]; then
            if [[ -f "$REPO/profiles/$b/.env.example" ]]; then
                cp "$REPO/profiles/$b/.env.example" "$REPO/profiles/$b/.env"
                warn "profiles/$b/.env created from example — EDIT IT (tokens, channel IDs)."
            else
                warn "profiles/$b/.env missing and no example exists — create it."
            fi
        fi
    done

    info "Installing project skills into each profile..."
    if [[ -d "$REPO/skills" ]]; then
        for b in "${BOTS[@]}"; do
            for skill_dir in "$REPO/skills"/*/; do
                skill_name="$(basename "$skill_dir")"
                target="$REPO/profiles/$b/skills/$skill_name"
                if [[ ! -d "$target" ]]; then
                    mkdir -p "$REPO/profiles/$b/skills"
                    cp -r "$skill_dir" "$target"
                    info "  $b: installed skill $skill_name"
                fi
            done
        done
    fi

    install_retention_cron

    echo
    info "Initialization complete."
    echo "  Next: edit profiles/*/.env with real tokens, then ./scripts/hermes.sh start"
    local _tip
    _tip="$(_tailscale_ip)"
    if [[ -n "$_tip" ]]; then
        echo "  Access: dashboard at http://$_tip:9119 (Tailscale only)"
    else
        echo "  Access: dashboard on port 9119 (run 'sudo tailscale up' for the tailnet URL)"
    fi
}

# ────────────────────────────────────────────────────────────
# START / STOP / RESTART
# ────────────────────────────────────────────────────────────
legacy_native_bots() {
    # PIDs left behind by the pre-Docker native launcher.
    local pf found=0
    for pf in "$RUN_DIR"/bots/*.pid; do
        [[ -f "$pf" ]] || continue
        if kill -0 "$(cat "$pf")" 2>/dev/null; then
            warn "Stale NATIVE bot process found: $pf (PID $(cat "$pf"))."
            warn "  Stop it before starting the Docker stack or Discord tokens will conflict."
            found=1
        fi
    done
    [[ "$found" == "1" ]] && return 1
    return 0
}

cmd_start() {
    load_root_env
    mkdir -p "$RUN_DIR"

    legacy_native_bots || {
        warn "Native gateways still running — stopping them (legacy migration)."
        local pf
        for pf in "$RUN_DIR"/bots/*.pid; do
            [[ -f "$pf" ]] || continue
            if kill -0 "$(cat "$pf")" 2>/dev/null; then
                kill "$(cat "$pf")" 2>/dev/null || true
                sleep 2
                kill -0 "$(cat "$pf")" 2>/dev/null && kill -9 "$(cat "$pf")" 2>/dev/null || true
                info "  stopped native bot $(basename "$pf")"
            fi
        done
    }

    info "Starting Docker stack (searxng, zen-proxy, health-api, 5 bots, dashboard)..."
    docker compose -f "$COMPOSE" up -d --build 2>&1 || { error "docker compose up failed."; exit 1; }

    info "Running data retention ..."
    bash "$SCRIPTS_DIR/retention.sh" run 2>&1 | sed 's/^/  /' || true

    echo ""
    cmd_status
}

cmd_stop() {
    docker compose -f "$COMPOSE" down 2>&1 || warn "docker compose down failed."

    # Best-effort: some previous setups still have a hermes-gateway systemd unit.
    if systemctl --user is-active hermes-gateway &>/dev/null 2>&1; then
        warn "Stopping legacy hermes-gateway systemd unit."
        systemctl --user stop hermes-gateway 2>&1 || true
    fi

    echo ""
    info "All services stopped."
}

cmd_restart() {
    echo "=== Stopping ===" && cmd_stop
    echo "" && echo "=== Starting ===" && cmd_start
}

# ────────────────────────────────────────────────────────────
# STATUS
# ────────────────────────────────────────────────────────────
cmd_status() {
    echo "Hermes Agent Status (docker stack)" && echo ""
    docker compose -f "$COMPOSE" ps
    echo ""
    echo "Logs: docker compose -f docker/docker-compose.yml logs -f <service>"
}

# ────────────────────────────────────────────────────────────
# CLEAN (destructive)
# ────────────────────────────────────────────────────────────
cmd_clean() {
    echo -e "${RED}This wipes:${NC}"
    echo "  - all profiles/* transient runtime state (sessions, logs, DBs, rendered config)"
    echo "  - profiles/*/.env (secrets) and the retention cron entry"
    echo "  - Docker volumes (searxng data) and containers"
    echo -e "${RED}Remote MongoDB is NOT touched. Committed files (skills, memories,"
    echo -e "SOUL.md, templates) are KEPT. Committed files are NOT touched.${NC}"
    read -r -p "Type 'yes' to wipe everything: " answer
    if [[ "$answer" != "yes" ]]; then
        warn "Clean aborted."
        exit 0
    fi

    docker compose -f "$COMPOSE" down -v 2>&1 || true
    info "Docker containers and volumes removed."

    remove_retention_cron
    rm -rf "$RUN_DIR"
    info "run/ removed."

    local b
    for b in "${BOTS[@]}"; do
        wipe_profile "$b"
    done

    echo ""
    info "Clean complete. Re-run ./scripts/hermes.sh init to start over."
}

wipe_profile() {
    local b="$1"
    local d="$REPO/profiles/$b"
    [[ -d "$d" ]] || return 0
    info "Wiping $b runtime state ..."
    rm -f "$d/config.yaml" "$d/config.rendered.yaml" "$d/.env" \
        "$d/auth.lock" "$d/gateway.lock" "$d/channel_directory.json" \
        "$d/.skills_prompt_snapshot.json" "$d/.clean_shutdown"
    rm -rf "$d"/.cache "$d"/.local "$d"/sessions \
        "$d"/state "$d"/state.db* "$d"/logs "$d"/cron "$d"/kanban* \
        "$d"/gateway* "$d"/bin "$d"/data "$d"/image_cache "$d"/audio_cache \
        "$d"/hooks "$d"/sandboxes "$d"/platforms "$d"/pairing "$d"/cache
}

# ────────────────────────────────────────────────────────────
# MAIN
# ────────────────────────────────────────────────────────────
case "${1:-help}" in
    init)    cmd_init ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    clean)   cmd_clean ;;
    help|--help|-h) usage ;;
    *)       error "Unknown command: $1" && usage && exit 1 ;;
esac
