#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PIDFILE="$HERMES_HOME/dashboard.pid"
LOGFILE="$HERMES_HOME/dashboard.log"
PORT="${HERMES_DASHBOARD_PORT:-9119}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

show_status() {
    "$(dirname "$0")/status.sh" 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────
# Gateway (messaging platforms, cron, etc.)
# ────────────────────────────────────────────────────────────
if systemctl --user is-active hermes-gateway &>/dev/null; then
    info "Gateway is already running."
else
    info "Starting gateway..."
    hermes gateway start 2>&1 || warn "Gateway start had issues (may need sudo loginctl enable-linger)."
fi

# ────────────────────────────────────────────────────────────
# Dashboard (web UI)
# ────────────────────────────────────────────────────────────
if [[ -f "$PIDFILE" ]]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        info "Dashboard is already running (PID $OLD_PID)."
        echo "  URL  : http://127.0.0.1:$PORT"
        echo ""
        show_status
        exit 0
    fi
    warn "Stale PID file found ($OLD_PID). Cleaning up."
    rm -f "$PIDFILE"
fi

RUNNING=$(hermes dashboard --status 2>&1 || true)
if echo "$RUNNING" | grep -qi "running"; then
    PID=$(echo "$RUNNING" | grep -oP 'PID \K\d+' | head -1)
    info "Dashboard is already running (PID $PID)."
    echo "$PID" > "$PIDFILE"
    echo "  URL  : http://127.0.0.1:$PORT"
    echo ""
    show_status
    exit 0
fi

info "Starting dashboard on 127.0.0.1:$PORT ..."
nohup hermes dashboard \
    --host 127.0.0.1 \
    --port "$PORT" \
    --no-open \
    --skip-build \
    >> "$LOGFILE" 2>&1 &

DASH_PID=$!
echo "$DASH_PID" > "$PIDFILE"

for i in $(seq 1 15); do
    sleep 1
    if hermes dashboard --status 2>&1 | grep -q "PID $DASH_PID"; then
        info "Dashboard started (PID $DASH_PID)."
        echo "  URL  : http://127.0.0.1:$PORT"
        echo "  Logs : $LOGFILE"
        echo ""
        show_status
        exit 0
    fi
done

error "Dashboard did not appear within 15 seconds. Check: $LOGFILE"
exit 1
