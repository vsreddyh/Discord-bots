#!/usr/bin/env bash
set -euo pipefail

: "${HERMES_HOME:=/hermes-home}"

# NOTE: env is injected entirely by docker-compose (from the single root
# .env). There is no per-profile .env to source anymore.
#
# Multiplex layout: HERMES_HOME is the gateway home (profiles/master) and
# every bot is a NAMED profile under $HERMES_HOME/profiles/<name>.
# compose mounts ../profiles/master:/hermes-home and ../workspace:/workspace,
# so this renders config.yaml for the gateway home + each named profile and
# writes each named profile's .env (Discord token/channel in the per-profile-
# secret scope Hermes reads).
#
# With s6-overlay, HERMES_DASHBOARD=1 runs dashboard alongside gateway in
# the SAME container (mirrors official nousresearch/hermes-agent image:
# `gateway run` supervised by s6, dashboard is an s6-rc service). Without
# it the container only runs the multiplexed gateway. HERMES_MODE=dashboard
# is deprecated but kept for backward compat (runs dashboard only).

if [[ "${1:-}" == "chown-data" ]]; then
    uid="${HERMES_UID:-1000}"
    gid="${HERMES_GID:-1000}"
    chown -R "$uid:$gid" "$HERMES_HOME" /workspace
    exit 0
fi

# Docker-environment defaults, used by both the live and test stacks.
export HERMES_BASE_URL="${HERMES_BASE_URL:-https://opencode.ai/zen/v1}"
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
    # $2 = profile name (story/resumes/default).
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

do_render() {
    # ── Gateway home (profiles/master — not a bot, just the multiplex host) ──
    export HERMES_CWD="${HERMES_CWD:-/workspace}"
    render_config "$HERMES_HOME"

    # ── Named profiles (story, resumes, default-god) ───────
    for home in "$HERMES_HOME"/profiles/*/; do
        [[ -d "$home" ]] || continue
        name="$(basename "$home")"
        upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
        tokv="DISCORD_BOT_TOKEN_${upper}"
        chv="DISCORD_HOME_CHANNEL_${upper}"
        # Export per-profile channel so ${DISCORD_HOME_CHANNEL} in the template
        # renders correctly for named profiles (was previously hardcoded).
        export DISCORD_HOME_CHANNEL="${!chv:-}"
        export DISCORD_BOT_TOKEN="${!tokv:-}"
        if [[ "$name" == "default" ]]; then
            HERMES_CWD="/workspace" render_config "$home"
        else
            HERMES_CWD="/workspace/$name" render_config "$home"
        fi
        write_profile_env "$home" "$name"
    done

    export HERMES_HOME
}

# render-only is used by s6 cont-init ( /etc/cont-init.d/01-render-config )
if [[ "${1:-}" == "render-only" ]]; then
    do_render
    exit 0
fi

# Normal startup: render first
do_render

# Backward compat: HERMES_MODE=dashboard runs dashboard only (deprecated)
if [[ "${HERMES_MODE:-gateway}" == "dashboard" ]]; then
    warning "HERMES_MODE=dashboard is deprecated, use HERMES_DASHBOARD=1"
    exec hermes dashboard \
        --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
        --port "${HERMES_DASHBOARD_PORT:-9119}" \
        --no-open --skip-build
fi

# HERMES_DASHBOARD=1 (or true/yes) → run both gateway + dashboard supervised by s6
dashboard_enabled=0
case "${HERMES_DASHBOARD:-0}" in
    1|true|TRUE|True|yes|YES|Yes) dashboard_enabled=1 ;;
esac

if [[ "$dashboard_enabled" == "1" ]]; then
    info "HERMES_DASHBOARD=1 — starting s6 supervision (gateway + dashboard on :${HERMES_DASHBOARD_PORT:-9119})"
    # Ensure dashboard service is enabled for s6 (remove down file if present)
    rm -f /etc/services.d/dashboard/down 2>/dev/null || true
    exec /init
fi

exec hermes gateway run --force --accept-hooks
