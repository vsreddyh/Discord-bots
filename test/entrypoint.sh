#!/usr/bin/env bash
set -euo pipefail

: "${HERMES_HOME:=/hermes-home}"

# NOTE: env is injected entirely by docker-compose (from the single root
# .env). There is no per-profile .env to source anymore.

if [[ "${1:-}" == "chown-data" ]]; then
    uid="${HERMES_UID:-1000}"
    gid="${HERMES_GID:-1000}"
    chown -R "$uid:$gid" "$HERMES_HOME" /workspace
    exit 0
fi

# Render the committed config.yaml.template into the config Hermes reads.
# Docker-environment defaults, used by both the live and test stacks.
export HERMES_BASE_URL="${HERMES_BASE_URL:-http://zen-proxy:4000/v1}"
export HERMES_CWD="${HERMES_CWD:-/workspace}"
export MONGODB_URI="${MONGODB_URI:-mongodb://mongodb:27017}"
export MONGODB_DB="${MONGODB_DB:-hermes}"

python3 - <<'PY'
import os
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
t = os.path.join(os.environ["HERMES_HOME"], "config.yaml.template")
if not os.path.exists(t):
    raise SystemExit(f"missing {t}")
src = open(t).read()
import re
def sub(m):
    key = m.group(1)
    return os.environ.get(key, m.group(0))
out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, src)
open(p, "w").write(out)
PY

export HERMES_HOME

if [[ "${HERMES_MODE:-gateway}" == "dashboard" ]]; then
    # Web dashboard for the master profile. The hermes-agent package ships a
    # prebuilt hermes_cli/web_dist, so --skip-build needs no Node/npm.
    exec hermes dashboard \
        --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
        --port "${HERMES_DASHBOARD_PORT:-9119}" \
        --no-open --skip-build
fi

exec hermes gateway run --force --accept-hooks
