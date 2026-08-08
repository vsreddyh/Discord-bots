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

python3 - <<'PY'
import os
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
src = open(p).read()
import re
def sub(m):
    key = m.group(1)
    return os.environ.get(key, m.group(0))
out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, src)
if out != src:
    open(p, "w").write(out)
PY

export HERMES_HOME

exec hermes gateway run --force --accept-hooks
