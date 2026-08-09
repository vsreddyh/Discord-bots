#!/usr/bin/env bash
# Shared helpers for the orchestrator scripts (hermes.sh, retention.sh).
# Source this file after setting REPO.

# Resolve the repo root from the directory of whatever script sources us.
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Load the single root .env into the shell environment (no per-profile .env).
load_root_env() {
    if [[ -f "$REPO/.env" ]]; then
        set -a; source "$REPO/.env"; set +a
    fi
}

# Run docker compose, transparently falling back to sudo when the current
# session predates docker-group membership (fresh install / first run).
#
# --env-file: interpolation reads the single root .env. Without it, compose
# looks for .env in the compose file's dir (docker/ or test/) and every
# ${VAR} (tokens, MONGODB_URI, ...) silently falls back to empty/default.
docker_compose() {
    if docker info &>/dev/null 2>&1; then
        docker compose --env-file "$REPO/.env" "$@"
    else
        sudo docker compose --env-file "$REPO/.env" "$@"
    fi
}
