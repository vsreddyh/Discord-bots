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

# shellcheck source=scripts/lib/common.sh
. "$REPO/scripts/lib/common.sh"

if [[ "${1:-}" == "--dry-run" ]]; then
    docker_compose -f "$COMPOSE" run --rm retention --dry-run
else
    docker_compose -f "$COMPOSE" run --rm retention
fi
