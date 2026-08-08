#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$REPO/run"
BOTS_DIR="$RUN_DIR/bots"
HERMES_HOME_DEFAULT="${HERMES_HOME:-$HOME/.hermes}"
DOCKER_COMPOSE_LIVE="$REPO/docker/docker-compose.yml"
BOTS=(master story helldivers money food)

PORT="${HERMES_DASHBOARD_PORT:-9119}"
UI_LOG="$RUN_DIR/dashboard.log"
UI_PID="$RUN_DIR/dashboard.pid"
PROXY_LOG="$RUN_DIR/zen-proxy.log"
PROXY_PID="$RUN_DIR/zen-proxy.pid"
HEALTH_LOG="$RUN_DIR/health-api.log"
HEALTH_PID="$RUN_DIR/health-api.pid"

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
  init       Install Hermes, patch hermes-god, set up venvs + per-bot .env + cron
  start      Start searxng (docker) → zen-proxy → health-api → 5 bots → dashboard
  stop       Stop dashboard → bots → health-api → zen-proxy → searxng
  restart    Stop then start
  status     Show all service states
  clean      Wipe everything (state, run dirs, hermes install). Destructive.
EOF
}

load_root_env() {
    if [[ -f "$REPO/.env" ]]; then
        set -a; source "$REPO/.env"; set +a
    fi
}

is_pid_alive() {
    local pf="$1"
    [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null
}

# ────────────────────────────────────────────────────────────
# RETENTION CRON (Plan C wiring)
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
# INIT
# ────────────────────────────────────────────────────────────
cmd_init() {
    load_root_env

    if command -v hermes &>/dev/null; then
        info "Hermes already installed at $(command -v hermes)"
        hermes --version 2>&1 | head -1
    else
        info "Installing Hermes..."
        bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh)
        if ! command -v hermes &>/dev/null; then
            error "'hermes' not on PATH. Add $HOME/.local/bin to your PATH."
            exit 1
        fi
    fi

    TOOLSETS_PY="$HERMES_HOME_DEFAULT/hermes-agent/toolsets.py"
    PLATFORMS_PY="$HERMES_HOME_DEFAULT/hermes-agent/hermes_cli/platforms.py"

    if [[ -f "$TOOLSETS_PY" ]] && ! grep -q "hermes-god" "$TOOLSETS_PY" 2>/dev/null; then
        info "Patching toolsets.py: adding hermes-god toolset..."
        sed -i '/^    "hermes-discord": {$/,/^    },$/c\
    "hermes-god": {\
        "description": "GOD Discord bot toolset - CLI + debugging + coding + Discord",\
        "tools": [\
            "discord",\
            "discord_admin",\
        ],\
        "includes": ["hermes-cli", "debugging", "coding"]\
    },' "$TOOLSETS_PY"
        sed -i 's/hermes-discord/hermes-god/g' "$PLATFORMS_PY"
        sed -i 's/"hermes-telegram", "hermes-discord"/"hermes-telegram", "hermes-god"/' "$TOOLSETS_PY"
        info "hermes-god toolset patched."
    fi

    mkdir -p "$BOTS_DIR" "$RUN_DIR"

    local b
    for b in "${BOTS[@]}"; do
        mkdir -p "$REPO/profiles/$b" "$REPO/workspace/$b"
        if [[ ! -f "$REPO/profiles/$b/.env" ]]; then
            if [[ -f "$REPO/profiles/$b/.env.example" ]]; then
                cp "$REPO/profiles/$b/.env.example" "$REPO/profiles/$b/.env"
                warn "profiles/$b/.env created from example — EDIT IT (tokens, channel IDs, MONGODB_URI)."
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
                if [[ -d "$target" ]]; then
                    :
                else
                    mkdir -p "$REPO/profiles/$b/skills"
                    cp -r "$skill_dir" "$target"
                    info "  $b: installed skill $skill_name"
                fi
            done
        done
    fi

    if ! python3 -c "import edge_tts" 2>/dev/null; then
        info "Installing edge-tts for TTS..."
        pip3 install edge-tts 2>&1 || warn "edge-tts install failed."
    fi

    if ! python3 -c "import nacl" 2>/dev/null || ! python3 -c "import davey" 2>/dev/null; then
        info "Installing Discord voice deps (PyNaCl, davey)..."
        pip3 install "PyNaCl>=1.5.0" davey 2>&1 || warn "Discord voice deps install failed."
    fi

    if ! python3 -c "import pymongo" 2>/dev/null; then
        info "Installing pymongo (remote MongoDB driver)..."
        pip3 install pymongo 2>&1 || warn "pymongo install failed."
    fi

    if ! dpkg -l libopus0 &>/dev/null 2>&1; then
        if command -v apt-get &>/dev/null; then
            info "Installing system audio deps (libopus0, ffmpeg)..."
            sudo apt-get install -y libopus0 ffmpeg 2>&1 || warn "System audio deps install failed."
        fi
    fi

    if ! command -v agent-browser &>/dev/null; then
        info "Installing agent-browser (browser automation)..."
        npm install -g agent-browser 2>&1 || warn "agent-browser npm install failed."
        agent-browser install --with-deps 2>&1 || warn "agent-browser Chromium install failed."
    fi

    info "Setting up Python venvs for zen-proxy and health-api..."
    setup_venv "venv-zen" "fastapi>=0.115,<1.0" "uvicorn[standard]>=0.34,<1.0" "httpx>=0.28,<1.0"
    setup_venv "venv-health" "$(cat "$REPO/docker/health-api/requirements.txt" | tr '\n' ' ')"

    install_retention_cron

    info "Running diagnostics..."
    hermes doctor --fix 2>&1 || true
    echo ""
    info "Tool status by platform:"
    hermes tools --summary 2>&1 || true

    if [[ -d "$HERMES_HOME_DEFAULT/hermes-agent/web" && ! -d "$HERMES_HOME_DEFAULT/hermes-agent/web/dist" ]]; then
        info "Pre-building dashboard UI..."
        (cd "$HERMES_HOME_DEFAULT/hermes-agent/web" && npm install --silent && npm run build --silent) || \
            warn "Dashboard UI build skipped."
    fi

    echo
    info "Initialization complete."
    echo "  Next: edit profiles/*/.env with real tokens, then ./scripts/hermes.sh start"
}

setup_venv() {
    local name="$1"; shift
    local dir="$RUN_DIR/$name"
    if [[ -x "$dir/bin/python" ]]; then
        info "  venv $name already exists."
        return 0
    fi
    info "  creating venv $name ..."
    python3 -m venv "$dir"
    "$dir/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    "$dir/bin/pip" install --quiet "$@" || warn "  venv $name pip install failed."
}

# ────────────────────────────────────────────────────────────
# START
# ────────────────────────────────────────────────────────────
start_zen_proxy() {
    if is_pid_alive "$PROXY_PID" && curl -sf http://localhost:4000/health >/dev/null 2>&1; then
        info "zen-proxy already running."
        return 0
    fi
    if [[ ! -x "$RUN_DIR/venv-zen/bin/uvicorn" ]]; then
        error "zen-proxy venv missing — run init first."
        return 1
    fi
    info "Starting zen-proxy (native uvicorn) on :4000 ..."
    (
        cd "$REPO/docker/proxy"
        nohup "$RUN_DIR/venv-zen/bin/uvicorn" main:app --host 0.0.0.0 --port 4000 \
            >> "$PROXY_LOG" 2>&1 &
        echo $! > "$PROXY_PID"
    )
    for _ in $(seq 1 20); do
        curl -sf http://localhost:4000/health >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf http://localhost:4000/health >/dev/null 2>&1 \
        && active "zen-proxy healthy" \
        || warn "zen-proxy not healthy yet — see $PROXY_LOG"
}

start_health_api() {
    if is_pid_alive "$HEALTH_PID" && curl -sf http://localhost:8001/health >/dev/null 2>&1; then
        info "health-api already running."
        return 0
    fi
    if [[ ! -x "$RUN_DIR/venv-health/bin/uvicorn" ]]; then
        error "health-api venv missing — run init first."
        return 1
    fi
    info "Starting health-api (native uvicorn) on :8001 ..."
    (
        cd "$REPO/docker/health-api"
        set -a
        source "$REPO/.env"
        [[ -f "$REPO/profiles/food/.env" ]] && source "$REPO/profiles/food/.env"
        set +a
        nohup "$RUN_DIR/venv-health/bin/uvicorn" main:app --host 0.0.0.0 --port 8001 \
            >> "$HEALTH_LOG" 2>&1 &
        echo $! > "$HEALTH_PID"
    )
    sleep 1
    curl -sf http://localhost:8001/health >/dev/null 2>&1 \
        && active "health-api healthy" \
        || warn "health-api not healthy yet — see $HEALTH_LOG"
}

start_ui() {
    if is_pid_alive "$UI_PID"; then
        info "Dashboard already running (PID $(cat "$UI_PID"))."
        return 0
    fi
    info "Starting dashboard on 0.0.0.0:$PORT (password auth from profiles/master/.env) ..."
    (
        set -a
        [[ -f "$REPO/profiles/master/.env" ]] && source "$REPO/profiles/master/.env"
        set +a
        HERMES_HOME="$REPO/profiles/master" nohup hermes dashboard \
            --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" --port "$PORT" --no-open --skip-build \
            >> "$UI_LOG" 2>&1 &
        echo $! > "$UI_PID"
    )
    for _ in $(seq 1 15); do
        is_pid_alive "$UI_PID" || break
        sleep 1
    done
    is_pid_alive "$UI_PID" \
        && active "dashboard (PID $(cat "$UI_PID"), http://0.0.0.0:$PORT)" \
        || error "dashboard failed to start — see $UI_LOG"
}

cmd_start() {
    load_root_env
    mkdir -p "$RUN_DIR" "$BOTS_DIR"

    info "Starting searxng (docker) ..."
    docker compose -f "$DOCKER_COMPOSE_LIVE" up -d 2>&1 || warn "searxng start failed."

    start_zen_proxy || exit 1
    start_health_api || exit 1

    info "Starting 5 Hermes gateways ..."
    bash "$SCRIPTS_DIR/bots.sh" start

    info "Running data retention ..."
    bash "$SCRIPTS_DIR/retention.sh" 2>&1 | sed 's/^/  /' || true

    start_ui

    echo ""
    cmd_status
}

# ────────────────────────────────────────────────────────────
# STOP
# ────────────────────────────────────────────────────────────
stop_ui() {
    if is_pid_alive "$UI_PID"; then
        local pid; pid="$(cat "$UI_PID")"
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
        info "Dashboard stopped."
    else
        inactive "Dashboard (not running)"
    fi
    rm -f "$UI_PID"
    # Best-effort: some installs spawn the dashboard under HERMES_HOME's own manager.
    hermes dashboard --stop 2>&1 | grep -qi "stopped" && info "dashboard --stop ok" || true
}

stop_health_api() {
    if is_pid_alive "$HEALTH_PID"; then
        kill "$(cat "$HEALTH_PID")" 2>/dev/null || true
        rm -f "$HEALTH_PID"
        info "health-api stopped."
    else
        inactive "health-api (not running)"
    fi
}

stop_zen_proxy() {
    if is_pid_alive "$PROXY_PID"; then
        kill "$(cat "$PROXY_PID")" 2>/dev/null || true
        rm -f "$PROXY_PID"
        info "zen-proxy stopped."
    else
        inactive "zen-proxy (not running)"
    fi
}

cmd_stop() {
    stop_ui
    info "Stopping 5 Hermes gateways ..."
    bash "$SCRIPTS_DIR/bots.sh" stop
    stop_health_api
    stop_zen_proxy

    if docker compose -f "$DOCKER_COMPOSE_LIVE" ps --status running 2>/dev/null | grep -q "searxng"; then
        info "Stopping searxng ..."
        docker compose -f "$DOCKER_COMPOSE_LIVE" down 2>&1 || warn "searxng stop failed."
    else
        inactive "searxng (not running)"
    fi

    # Stop the old single-instance systemd unit if it lingers from a previous setup.
    if systemctl --user is-active hermes-gateway &>/dev/null 2>&1; then
        warn "Stopping legacy hermes-gateway systemd unit."
        systemctl --user stop hermes-gateway 2>&1 || true
    fi

    echo ""
    info "All services stopped."
}

# ────────────────────────────────────────────────────────────
# RESTART
# ────────────────────────────────────────────────────────────
cmd_restart() {
    echo "=== Stopping ===" && cmd_stop
    echo "" && echo "=== Starting ===" && cmd_start
}

# ────────────────────────────────────────────────────────────
# STATUS
# ────────────────────────────────────────────────────────────
cmd_status() {
    echo "Hermes Agent Status" && echo ""

    if docker compose -f "$DOCKER_COMPOSE_LIVE" ps --status running 2>/dev/null | grep -q "searxng"; then
        active "SearXNG    (docker)"
    else
        inactive "SearXNG    (not running)"
    fi

    if is_pid_alive "$PROXY_PID" && curl -sf http://localhost:4000/health >/dev/null 2>&1; then
        active "Zen Proxy  (PID $(cat "$PROXY_PID"), http://localhost:4000)"
    else
        inactive "Zen Proxy  (not running)"
    fi

    if is_pid_alive "$HEALTH_PID" && curl -sf http://localhost:8001/health >/dev/null 2>&1; then
        active "Health API (PID $(cat "$HEALTH_PID"), http://localhost:8001)"
    else
        inactive "Health API (not running)"
    fi

    bash "$SCRIPTS_DIR/bots.sh" status

    if is_pid_alive "$UI_PID"; then
        active "Dashboard  (PID $(cat "$UI_PID"), http://0.0.0.0:$PORT)"
    else
        inactive "Dashboard  (not running)"
    fi

    echo ""
    echo "Logs: $RUN_DIR/"
    echo "Bot logs: $BOTS_DIR/"
}

# ────────────────────────────────────────────────────────────
# CLEAN (destructive)
# ────────────────────────────────────────────────────────────
cmd_clean() {
    echo -e "${RED}This wipes:${NC}"
    echo "  - run/ (venvs, PIDs, logs)"
    echo "  - all profiles/* runtime state (sessions, memories, DBs, rendered config)"
    echo "  - profiles/*/.env (secrets) and the retention cron entry"
    echo "  - Docker searxng data (compose down -v)"
    echo "  - the Hermes install (~/.hermes + hermes CLI)"
    echo -e "${RED}Remote MongoDB is NOT touched. Committed files are NOT touched.${NC}"
    read -r -p "Type 'yes' to wipe everything: " answer
    if [[ "$answer" != "yes" ]]; then
        warn "Clean aborted."
        exit 0
    fi

    cmd_stop

    remove_retention_cron
    rm -rf "$RUN_DIR"
    info "run/ removed."

    local b
    for b in "${BOTS[@]}"; do
        wipe_profile "$b"
    done

    docker compose -f "$DOCKER_COMPOSE_LIVE" down -v 2>&1 || true
    info "Docker searxng data removed."

    if command -v hermes &>/dev/null; then
        info "Uninstalling Hermes..."
        hermes uninstall --full --yes 2>&1 || true
    fi
    rm -rf "$HERMES_HOME_DEFAULT"
    info "Hermes install removed."

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
    rm -rf "$d"/.cache "$d"/.local "$d"/sessions "$d"/memories \
        "$d"/state "$d"/state.db* "$d"/logs "$d"/cron "$d"/kanban* \
        "$d"/gateway* "$d"/bin "$d"/data "$d"/image_cache "$d"/audio_cache \
        "$d"/hooks "$d"/sandboxes "$d"/platforms "$d"/pairing "$d"/cache \
        "$d"/skills/.usage.json* "$d"/skills/.curator_state \
        "$d"/skills/nousresearch
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
