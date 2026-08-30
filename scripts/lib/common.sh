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
    # Dev isolation: HERMES_ENV=dev uses a temporary local MongoDB container
    # (mongodb:27017) instead of the remote Atlas cluster. Prod/unset uses
    # the remote MONGODB_URI as-is. This keeps dev writes off the prod DB
    # without needing a separate test_ database on Atlas.
    # Exported after load so compose interpolation sees it over --env-file.
    if [[ "${HERMES_ENV:-}" == "dev" ]]; then
        export MONGODB_URI="mongodb://mongodb:27017"
        export MONGODB_DB="${MONGODB_DB:-hermes}"
        # Enable the `dev` compose profile so the local `mongodb` service is started.
        if [[ -z "${COMPOSE_PROFILES:-}" ]]; then
            export COMPOSE_PROFILES=dev
        elif [[ ",$COMPOSE_PROFILES," != *",dev,"* ]]; then
            export COMPOSE_PROFILES="${COMPOSE_PROFILES},dev"
        fi
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
