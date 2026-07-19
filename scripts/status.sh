#!/usr/bin/env bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PIDFILE="$HERMES_HOME/dashboard.pid"
PORT="${HERMES_DASHBOARD_PORT:-9119}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

active()   { echo -e "  ${GREEN}●${NC} $1"; }
inactive() { echo -e "  ${RED}○${NC} $1"; }
warn()     { echo -e "  ${YELLOW}⚠${NC} $1"; }

echo "Hermes Agent Status"
echo ""

# Gateway
if systemctl --user is-active hermes-gateway &>/dev/null; then
    active "Gateway    (systemd: hermes-gateway)"
else
    inactive "Gateway    (systemd: hermes-gateway)"
fi

# Dashboard
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

# Profile
CUR_PROFILE=$(hermes config get profile.active 2>/dev/null || echo "")
if [[ -n "$CUR_PROFILE" && "$CUR_PROFILE" != "None" ]]; then
    echo ""
    warn "Active profile: $CUR_PROFILE"
fi

echo ""
echo "Logs: $HERMES_HOME/logs/"
echo "Config: $(hermes config path 2>/dev/null || echo "$HERMES_HOME/config.yaml")"
echo "Env: $(hermes config env-path 2>/dev/null || echo "$HERMES_HOME/.env")"
