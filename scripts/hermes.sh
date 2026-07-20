#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BINDIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/../docker" && pwd)"
PIDFILE="$HERMES_HOME/dashboard.pid"
LOGFILE="$HERMES_HOME/dashboard.log"
PORT="${HERMES_DASHBOARD_PORT:-9119}"

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
  init              Install Hermes and write preset configs
  start             Start Zen proxy → gateway → dashboard
  stop              Stop dashboard → gateway → Zen proxy
  restart           Stop then start
  status            Show all service states
  docker <action>   Docker management (logs, rebuild, shell, ps, prune)
EOF
}

# ────────────────────────────────────────────────────────────
# INIT
# ────────────────────────────────────────────────────────────
cmd_init() {
    HERMES_PROVIDER="${HERMES_PROVIDER:-custom}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek-v4-flash-free}"
    HERMES_API_KEY="${HERMES_API_KEY:-}"
    HERMES_BASE_URL="${HERMES_BASE_URL:-http://localhost:4000/v1}"
    HERMES_TERMINAL_BACKEND="${HERMES_TERMINAL_BACKEND:-local}"
    HERMES_TERMINAL_TIMEOUT="${HERMES_TERMINAL_TIMEOUT:-180}"
    HERMES_MAX_TURNS="${HERMES_MAX_TURNS:-90}"
    HERMES_REASONING="${HERMES_REASONING:-medium}"
    HERMES_MEMORY_ENABLED="${HERMES_MEMORY_ENABLED:-true}"
    HERMES_DISABLED_TOOLSETS="${HERMES_DISABLED_TOOLSETS:-feishu_doc,feishu_drive,homeassistant,image_gen,memory,project,session_search,skills,spotify,video,video_gen,vision,web,x_search,yuanbao}"
    HERMES_EXTRA_KEYS="${HERMES_EXTRA_KEYS:-}"

    if command -v hermes &>/dev/null; then
        info "Hermes already installed at $(command -v hermes)"
        hermes --version 2>&1 | head -1
    else
        info "Installing Hermes..."
        bash <(curl -fsSL https://hermes-agent.nousresearch.com/install.sh)
        if ! command -v hermes &>/dev/null; then
            error "'hermes' not on PATH. Add $BINDIR to your PATH."
            exit 1
        fi
    fi

    CONFIG_TEMPLATE="$SCRIPT_DIR/../default-config.yaml"
    mkdir -p "$HERMES_HOME"

    HERMES_DISABLED_YAML=""
    if [[ -n "$HERMES_DISABLED_TOOLSETS" ]]; then
        IFS=',' read -ra TOOLS <<< "$HERMES_DISABLED_TOOLSETS"
        for t in "${TOOLS[@]}"; do
            t="$(echo "$t" | xargs)"
            [[ -n "$t" ]] && HERMES_DISABLED_YAML="$HERMES_DISABLED_YAML    - $t\n"
        done
    fi
    HERMES_DISABLED_YAML="${HERMES_DISABLED_YAML%\\n}"

    if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
        info "Writing config.yaml ..."
        export HERMES_MODEL HERMES_BASE_URL HERMES_API_KEY
        export HERMES_MAX_TURNS HERMES_REASONING HERMES_MEMORY_ENABLED
        export HERMES_TERMINAL_BACKEND HERMES_TERMINAL_TIMEOUT
        export HERMES_DISABLED_YAML
        envsubst < "$CONFIG_TEMPLATE" > "$HERMES_HOME/config.yaml"
    else
        info "config.yaml exists — skipping."
    fi

    TOOLSETS_PY="$HERMES_HOME/hermes-agent/toolsets.py"
    PLATFORMS_PY="$HERMES_HOME/hermes-agent/hermes_cli/platforms.py"

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

    PROJECT_SKILLS="$SCRIPT_DIR/../skills"
    if [[ -d "$PROJECT_SKILLS" ]]; then
        info "Copying project skills to $HERMES_HOME/skills/ ..."
        for skill_dir in "$PROJECT_SKILLS"/*/; do
            skill_name="$(basename "$skill_dir")"
            target="$HERMES_HOME/skills/$skill_name"
            if [[ -d "$target" ]]; then
                info "  Skill '$skill_name' already exists — skipping."
            else
                cp -r "$skill_dir" "$target"
                info "  Installed skill: $skill_name"
            fi
        done
    else
        info "No project skills directory found — skipping."
    fi

    PROJECT_ENV="$SCRIPT_DIR/../.env"
    ENV_FILE="$HERMES_HOME/.env"

    if [[ -f "$PROJECT_ENV" ]]; then
        info "Copying .env to $ENV_FILE ..."
        cp "$PROJECT_ENV" "$ENV_FILE"
    else
        info "No project .env found — skipping copy."
    fi

    if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
        info "Discord configured."
        if systemctl --user is-active hermes-gateway &>/dev/null; then
            info "Restarting gateway for Discord..."
            hermes gateway restart 2>&1 || true
        fi
    fi

    if ! python3 -c "import edge_tts" 2>/dev/null; then
        info "Installing edge-tts for TTS..."
        pip3 install edge-tts 2>&1 || warn "edge-tts install failed."
    fi

    if ! python3 -c "import nacl" 2>/dev/null || ! python3 -c "import davey" 2>/dev/null; then
        info "Installing Discord voice deps (PyNaCl, davey)..."
        pip3 install "PyNaCl>=1.5.0" davey 2>&1 || warn "Discord voice deps install failed."
    fi

    if dpkg -l libopus0 &>/dev/null 2>&1; then
        :
    else
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

    info "Running diagnostics..."
    hermes doctor --fix 2>&1 || true

    echo ""
    info "Tool status by platform:"
    hermes tools --summary 2>&1 || true

    if [[ -d "$HERMES_HOME/hermes-agent/web" && ! -d "$HERMES_HOME/hermes-agent/web/dist" ]]; then
        info "Pre-building dashboard UI..."
        (cd "$HERMES_HOME/hermes-agent/web" && npm install --silent && npm run build --silent) || \
            warn "Dashboard UI build skipped."
    fi

    echo
    info "Initialization complete."
    echo "  Provider: Zen Proxy ($HERMES_BASE_URL)  |  Model: $HERMES_MODEL"
}

# ────────────────────────────────────────────────────────────
# START
# ────────────────────────────────────────────────────────────
cmd_start() {
    if docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "zen-proxy"; then
        info "Docker services already running."
    else
        info "Starting Docker services (zen-proxy, searxng)..."
        docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d 2>&1 || warn "Docker services start failed."
    fi

    if systemctl --user is-active hermes-gateway &>/dev/null; then
        info "Gateway already running."
    else
        info "Starting gateway..."
        hermes gateway start 2>&1 || warn "Gateway start had issues."
    fi

    if [[ -f "$PIDFILE" ]]; then
        OLD_PID=$(cat "$PIDFILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            info "Dashboard already running (PID $OLD_PID)."
            echo "  URL: http://127.0.0.1:$PORT"
            echo ""
            cmd_status
            exit 0
        fi
        rm -f "$PIDFILE"
    fi

    RUNNING=$(hermes dashboard --status 2>&1 || true)
    if echo "$RUNNING" | grep -qi "running"; then
        PID=$(echo "$RUNNING" | grep -oP 'PID \K\d+' | head -1)
        echo "$PID" > "$PIDFILE"
        info "Dashboard already running (PID $PID)."
        echo "  URL: http://127.0.0.1:$PORT"
        echo ""
        cmd_status
        exit 0
    fi

    info "Starting dashboard on 127.0.0.1:$PORT ..."
    nohup hermes dashboard --host 127.0.0.1 --port "$PORT" --no-open --skip-build >> "$LOGFILE" 2>&1 &
    DASH_PID=$!
    echo "$DASH_PID" > "$PIDFILE"

    for i in $(seq 1 15); do
        sleep 1
        if hermes dashboard --status 2>&1 | grep -q "PID $DASH_PID"; then
            info "Dashboard started (PID $DASH_PID)."
            echo "  URL: http://127.0.0.1:$PORT"
            echo "  Logs: $LOGFILE"
            echo ""
            cmd_status
            exit 0
        fi
    done

    error "Dashboard didn't appear. Check: $LOGFILE"
    exit 1
}

# ────────────────────────────────────────────────────────────
# STOP
# ────────────────────────────────────────────────────────────
cmd_stop() {
    if hermes dashboard --stop 2>&1 | grep -qi "stopped"; then
        info "Dashboard stopped."
    else
        if [[ -f "$PIDFILE" ]]; then
            PID=$(cat "$PIDFILE")
            kill -0 "$PID" 2>/dev/null && kill "$PID" 2>/dev/null && warn "Dashboard killed (fallback)." || true
        fi
    fi
    rm -f "$PIDFILE"

    if systemctl --user is-active hermes-gateway &>/dev/null; then
        info "Stopping gateway..."
        hermes gateway stop 2>&1 || warn "Gateway stop failed."
    else
        info "Gateway not running."
    fi

    if docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "zen-proxy"; then
        info "Stopping Zen proxy..."
        docker compose -f "$DOCKER_DIR/docker-compose.yml" down 2>&1 || warn "Zen proxy stop failed."
    else
        info "Zen proxy not running."
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

    if docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "zen-proxy"; then
        ZP=$(docker compose -f "$DOCKER_DIR/docker-compose.yml" port zen-proxy 4000 2>/dev/null | sed 's/.*://' || echo "4000")
        active "Zen Proxy  (port $ZP)"
    else
        inactive "Zen Proxy  (not running)"
    fi

    if systemctl --user is-active hermes-gateway &>/dev/null; then
        active "Gateway    (systemd)"
    else
        inactive "Gateway    (not running)"
    fi

    DASH_PID=""
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        DASH_PID=$(cat "$PIDFILE")
    elif hermes dashboard --status 2>&1 | grep -qi "running"; then
        DASH_PID=$(hermes dashboard --status 2>&1 | grep -oP 'PID \K\d+' | head -1)
        echo "$DASH_PID" > "$PIDFILE" 2>/dev/null || true
    fi

    if [[ -n "$DASH_PID" ]]; then
        active "Dashboard  (PID $DASH_PID, http://127.0.0.1:$PORT)"
    else
        inactive "Dashboard  (not running)"
    fi

    echo ""
    if command -v curl &>/dev/null; then
        ZOK=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health 2>/dev/null || echo "000")
        [[ "$ZOK" == "200" ]] && active "Zen Proxy   (healthy)" || warn "Zen Proxy   (unreachable)"
    fi

    if docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "searxng"; then
        SP=$(docker compose -f "$DOCKER_DIR/docker-compose.yml" port searxng 8080 2>/dev/null | sed 's/.*://' || echo "${SEARXNG_PORT:-8888}")
        active "SearXNG    (port $SP)"
    else
        inactive "SearXNG    (not running)"
    fi

    CUR_PROFILE=$(hermes config get profile.active 2>/dev/null || echo "")
    [[ -n "$CUR_PROFILE" && "$CUR_PROFILE" != "None" ]] && echo "" && warn "Profile: $CUR_PROFILE"
    echo ""
    echo "Tools:"
    hermes tools --summary 2>&1 | sed 's/^/  /' || true
    echo ""
    echo "Logs: $HERMES_HOME/logs/"
    echo "Config: $(hermes config path 2>/dev/null || echo "$HERMES_HOME/config.yaml")"
}

# ────────────────────────────────────────────────────────────
# DOCKER
# ────────────────────────────────────────────────────────────
cmd_docker() {
    local action="${1:-help}"
    shift 2>/dev/null || true

    case "$action" in
        logs)
            local svc="${1:-zen-proxy}"
            docker compose -f "$DOCKER_DIR/docker-compose.yml" logs -f "$svc"
            ;;
        rebuild)
            info "Rebuilding zen-proxy..."
            docker compose -f "$DOCKER_DIR/docker-compose.yml" build --no-cache zen-proxy
            info "Restarting..."
            docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d zen-proxy
            ;;
        shell)
            local svc="${1:-zen-proxy}"
            docker compose -f "$DOCKER_DIR/docker-compose.yml" exec "$svc" sh
            ;;
        ps)
            docker compose -f "$DOCKER_DIR/docker-compose.yml" ps
            ;;
        prune)
            info "Pruning unused Docker resources..."
            docker system prune -f --volumes 2>&1 || warn "Prune had issues."
            ;;
        help|--help|-h)
            cat <<EOF
Usage: $(basename "$0") docker <action>

Actions:
  logs [svc]     Tail logs (default: zen-proxy)
  rebuild        Rebuild zen-proxy image
  shell [svc]    Open shell in container (default: zen-proxy)
  ps             List containers
  prune          Clean up unused Docker resources
EOF
            ;;
        *)
            error "Unknown docker action: $action"
            cmd_docker help
            exit 1
            ;;
    esac
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
    docker)  shift; cmd_docker "$@" ;;
    help|--help|-h) usage ;;
    *)       error "Unknown command: $1" && usage && exit 1 ;;
esac
