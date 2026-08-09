#!/usr/bin/env bash
set -euo pipefail

# Data retention for the Hermes bots. Runs via cron (installed by
# scripts/hermes.sh init) and once on every start.
#
# The live stack is fully Dockerized, so this just runs the `retention`
# one-shot service from docker/docker-compose.yml (same bot image, mounts
# tools/ read-only, MONGODB_URI/MONGODB_DB injected from the root .env).
# The actual policy logic lives in tools/retention.py.
#
#   story       no domain DB                   — no-op
#   helldivers  static wiki DB (reference)     — no-op, never wiped
#   money       transactions autowiped when the oldest entry is >90 days old
#   food        date-based rows pruned after 30 days; food_weight is NEVER touched

REPO="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO/docker/docker-compose.yml"

# Fall back to sudo docker when the current session predates docker-group
# membership (fresh install / first run).
docker_compose() {
    if docker info &>/dev/null 2>&1; then
        docker compose "$@"
    else
        sudo docker compose "$@"
    fi
}

if [[ "${1:-}" == "--dry-run" ]]; then
    exec docker_compose -f "$COMPOSE" run --rm retention --dry-run
fi

exec docker_compose -f "$COMPOSE" run --rm retention
