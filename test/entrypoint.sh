#!/usr/bin/env bash
set -euo pipefail

: "${HERMES_HOME:=/hermes-home}"

if [[ -f "$HERMES_HOME/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$HERMES_HOME/.env"
    set +a
fi

if [[ "${1:-}" == "chown-data" ]]; then
    uid="${HERMES_UID:-1000}"
    gid="${HERMES_GID:-1000}"
    chown -R "$uid:$gid" "$HERMES_HOME" /workspace
    exit 0
fi

# Render the committed config.yaml.template into the config Hermes reads.
# Docker-environment defaults; the native launcher (scripts/bots.sh) uses
# localhost:4000 / the repo workspace instead.
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

exec hermes gateway run --force --accept-hooks
