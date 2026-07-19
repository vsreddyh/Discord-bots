#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PIDFILE="$HERMES_HOME/dashboard.pid"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

RC=0

# ────────────────────────────────────────────────────────────
# Dashboard
# ────────────────────────────────────────────────────────────
if hermes dashboard --stop 2>&1 | grep -qi "stopped"; then
    info "Dashboard stopped."
else
    if [[ -f "$PIDFILE" ]]; then
        PID=$(cat "$PIDFILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
            warn "Dashboard process $PID killed (fallback)."
        fi
    fi
fi
rm -f "$PIDFILE"

# ────────────────────────────────────────────────────────────
# Gateway
# ────────────────────────────────────────────────────────────
if systemctl --user is-active hermes-gateway &>/dev/null; then
    info "Stopping gateway..."
    hermes gateway stop 2>&1 || warn "Gateway stop command failed."
else
    info "Gateway is not running."
fi

echo ""
info "All Hermes services stopped."
