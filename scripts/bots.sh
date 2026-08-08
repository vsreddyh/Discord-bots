#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$REPO/run"
BOTS_DIR="$RUN_DIR/bots"

BOTS=(master story helldivers money food)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
active()  { echo -e "  ${GREEN}●${NC} $1"; }
inactive(){ echo -e "  ${RED}○${NC} $1"; }

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────
bot_env() {
    local b="$1"
    set -a
    [[ -f "$REPO/.env" ]] && source "$REPO/.env"
    [[ -f "$REPO/profiles/$b/.env" ]] && source "$REPO/profiles/$b/.env"
    set +a
}

render_config() {
    local b="$1"
    local template="$REPO/profiles/$b/config.yaml.template"
    [[ -f "$template" ]] || { error "missing $template"; return 1; }
    mkdir -p "$REPO/profiles/$b" "$REPO/workspace/$b"
    export HERMES_BASE_URL="${HERMES_BASE_URL:-http://localhost:4000/v1}"
    export HERMES_CWD="${HERMES_CWD:-$REPO/workspace/$b}"
    envsubst '${HERMES_BASE_URL} ${HERMES_CWD} ${DISCORD_HOME_CHANNEL}' \
        < "$template" > "$REPO/profiles/$b/config.yaml"
}

pid_file() { echo "$BOTS_DIR/$1.pid"; }

is_running() {
    local pf; pf="$(pid_file "$1")"
    [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null
}

start_bot() {
    local b="$1"
    if is_running "$b"; then
        warn "bot '$b' already running (PID $(cat "$(pid_file "$b")"))."
        return 0
    fi
    render_config "$b" || return 1
    bot_env "$b"
    (
        cd "$REPO/workspace/$b"
        HERMES_HOME="$REPO/profiles/$b" nohup hermes gateway run --force --accept-hooks \
            >> "$BOTS_DIR/$b.log" 2>&1 &
        echo $! > "$(pid_file "$b")"
    )
    sleep 1
    if is_running "$b"; then
        info "started $b (PID $(cat "$(pid_file "$b")"), log run/bots/$b.log)."
    else
        error "$b failed to start — see run/bots/$b.log"
    fi
}

stop_bot() {
    local b="$1" pid pf
    pf="$(pid_file "$b")"
    if [[ ! -f "$pf" ]]; then
        inactive "$b (not running)"
        return 0
    fi
    pid="$(cat "$pf")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
        info "stopped $b"
    else
        warn "$b was not alive — stale pid removed."
    fi
    rm -f "$pf"
}

status_bot() {
    local b="$1" pid
    pid="$(cat "$(pid_file "$b")" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        active "$b  (PID $pid)"
    else
        inactive "$b  (not running)"
    fi
}

# ────────────────────────────────────────────────────────────
# Commands
# ────────────────────────────────────────────────────────────
cmd_start() {
    mkdir -p "$BOTS_DIR"
    local b
    for b in "${BOTS[@]}"; do
        start_bot "$b"
    done
}

cmd_stop() {
    local b
    for b in "${BOTS[@]}"; do
        stop_bot "$b"
    done
}

cmd_status() {
    echo "Bots:"
    local b
    for b in "${BOTS[@]}"; do
        status_bot "$b"
    done
}

cmd_restart() {
    cmd_stop
    cmd_start
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <start|stop|restart|status>
Manages the 5 native Hermes gateway processes (master, story, helldivers,
money, food). One HERMES_HOME per bot under profiles/<bot>.
EOF
}

case "${1:-help}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    help|-h|--help) usage ;;
    *)       error "Unknown command: $1"; usage; exit 1 ;;
esac
