#!/usr/bin/env bash
set -euo pipefail

: "${HERMES_HOME:=/hermes-home}"

# NOTE: env is injected entirely by docker-compose (from the single root
# .env). There is no per-profile .env to source anymore.
#
# Multiplex layout: HERMES_HOME is the DEFAULT profile (master) home and
# every sibling bot is a NAMED profile under $HERMES_HOME/profiles/<name>.
# compimose mounts ../profiles/master:/hermes-home and ../workspace:/workspace,
# so this renders config.yaml for ALL profiles and writes each named profile's
# .env (Discord token/channel in the per-profile-secret scope Hermes reads).

if [[ "${1:-}" == "chown-data" ]]; then
    uid="${HERMES_UID:-1000}"
    gid="${HERMES_GID:-1000}"
    chown -R "$uid:$gid" "$HERMES_HOME" /workspace
    exit 0
fi

# Docker-environment defaults, used by both the live and test stacks.
export HERMES_BASE_URL="${HERMES_BASE_URL:-http://zen-proxy:4000/v1}"
export MONGODB_URI="${MONGODB_URI:-mongodb://mongodb:27017}"
export MONGODB_DB="${MONGODB_DB:-hermes}"

render_config() {
    # Render one profile's $1/config.yaml.template → $1/config.yaml.
    # Env vars come from the process env; each profile's token/channel are
    # already present as DISCORD_BOT_TOKEN / DISCORD_HOME_CHANNEL.
    local home="$1" t c
    t="$home/config.yaml.template"
    c="$home/config.yaml"
    if [[ ! -f "$t" ]]; then
        warning "missing template $t"
        return 0
    fi
    python3 - "$t" "$c" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
def sub(m):
    return os.environ.get(m.group(1), m.group(0))
out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, src)
open(sys.argv[2], "w").write(out)
PY
    info "rendered $c"
}

write_profile_env() {
    # Write one profile's .env with its own Discord creds. $1 = home,
    # $2 = profile name (master/story/helldivers/money/food).
    local home="$1" name="$2" envf
    envf="$home/.env"
    # Mapping is deterministic: DISCORD_BOT_TOKEN_<NAME upper> in the
    # container env (from root .env via compose) → DISCORD_BOT_TOKEN here.
    local tok ch upper tokv chv
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    tokv="DISCORD_BOT_TOKEN_${upper}"
    chv="DISCORD_HOME_CHANNEL_${upper}"
    tok="${!tokv:-}"
    ch="${!chv:-}"
    {
        printf 'DISCORD_BOT_TOKEN=%s\n' "$tok"
        printf 'DISCORD_HOME_CHANNEL=%s\n' "$ch"
    } > "$envf"
    info "wrote $envf"
}

warning() { echo "[entrypoint] WARN: $*" >&2; }
info() { echo "[entrypoint] $*"; }

# ── Default profile (master) ───────────────────────────
export HERMES_CWD="${HERMES_CWD:-/workspace/master}"
render_config "$HERMES_HOME"
write_profile_env "$HERMES_HOME" master

# ── Named profiles (story, helldivers, money, food) ────
for home in "$HERMES_HOME"/profiles/*/; do
    [[ -d "$home" ]] || continue
    name="$(basename "$home")"
    # Hermes auto-creates profiles/default/ for the dashboard/gateway; it is
    # not a bot profile, so skip it.
    [[ "$name" == "default" ]] && continue
    # Each named profile runs in its own workspace subdir.
    HERMES_CWD="/workspace/$name" render_config "$home"
    write_profile_env "$home" "$name"
done

export HERMES_HOME

if [[ "${HERMES_MODE:-gateway}" == "dashboard" ]]; then
    # Web dashboard for the master profile — unified mode lists every named
    # profile under HERMES_HOME/profiles/. The package ships a prebuilt
    # hermes_cli/web_dist, so --skip-build needs no Node/npm.
    exec hermes dashboard \
        --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
        --port "${HERMES_DASHBOARD_PORT:-9119}" \
        --no-open --skip-build
fi

exec hermes gateway run --force --accept-hooks