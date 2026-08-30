# syntax=docker/dockerfile:1
FROM python:3.11-alpine

ENV PYTHONUNBUFFERED=1

# s6-overlay provides s6 supervision so HERMES_DASHBOARD=1 can run
# dashboard alongside gateway in the same container (mirrors the
# official nousresearch/hermes-agent image where `gateway run` is
# supervised by s6 and dashboard is an s6-rc service).
ARG S6_OVERLAY_VERSION=3.2.1.0
RUN apk add --no-cache bash git openssh-client curl sqlite tectonic opus opus-dev libsodium-dev ffmpeg xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
 && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz \
 && rm /tmp/s6-overlay-*.tar.xz

RUN --mount=type=cache,target=/root/.cache/pip pip install hermes-agent 'discord.py[voice]==2.7.1' pymongo

RUN python - <<'PY'
import pathlib, re

sp = pathlib.Path("/usr/local/lib/python3.11/site-packages")
toolsets = sp / "toolsets.py"
platforms = sp / "hermes_cli" / "platforms.py"

src = toolsets.read_text()
if "hermes-god" not in src:
    new_block = (
        '    "hermes-god": {\n'
        '        "description": "GOD Discord bot toolset - CLI + debugging + coding + Discord",\n'
        '        "tools": [\n'
        '            "discord",\n'
        '            "discord_admin",\n'
        '        ],\n'
        '        "includes": ["hermes-cli", "debugging", "coding"]\n'
        '    },\n'
    )
    src, n = re.subn(r'    "hermes-discord": \{\n.*?\n    \},\n', new_block, src, count=1, flags=re.S)
    if n != 1:
        raise SystemExit("PATCH FAILED: hermes-discord block not found in toolsets.py — hermes-agent layout changed")
    src2 = src.replace('"hermes-telegram", "hermes-discord"', '"hermes-telegram", "hermes-god"')
    if src2 == src:
        raise SystemExit("PATCH FAILED: hermes-discord reference not found in toolsets.py — layout changed")
    src = src2
    toolsets.write_text(src)

pf = platforms.read_text()
if "hermes-god" not in pf:
    pf2 = pf.replace("hermes-discord", "hermes-god")
    if pf2 == pf:
        raise SystemExit("PATCH FAILED: 'hermes-discord' not found in platforms.py — layout changed")
    platforms.write_text(pf2)
PY

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# s6 service definitions - gateway always runs, dashboard runs when
# HERMES_DASHBOARD=1 (dashboard/down keeps it stopped by default).
# Use per-profile s6 naming (gateway-default) as Hermes service_manager expects
# (S6_SERVICE_PREFIX=gateway-); plain "gateway" is legacy and not listed.
RUN mkdir -p /etc/services.d/gateway-default /etc/services.d/dashboard
RUN printf '#!/command/with-contenv bash\nexec s6-setuidgid 1000:1000 hermes gateway run --force --accept-hooks --no-supervise\n' > /etc/services.d/gateway-default/run \
  && chmod +x /etc/services.d/gateway-default/run
RUN printf '#!/command/with-contenv bash\nexec s6-setuidgid 1000:1000 hermes dashboard --host ${HERMES_DASHBOARD_HOST:-0.0.0.0} --port ${HERMES_DASHBOARD_PORT:-9119} --no-open --skip-build\n' > /etc/services.d/dashboard/run \
  && chmod +x /etc/services.d/dashboard/run
RUN touch /etc/services.d/dashboard/down

# cont-init renders configs before s6 starts services (when launched via /init)
RUN mkdir -p /etc/cont-init.d
RUN printf '#!/command/with-contenv bash\n/usr/local/bin/entrypoint.sh render-only\n' > /etc/cont-init.d/01-render-config \
 && chmod +x /etc/cont-init.d/01-render-config
RUN printf '#!/command/with-contenv bash\nif [ "${HERMES_DASHBOARD:-0}" = "1" ] || [ "${HERMES_DASHBOARD:-}" = "true" ] || [ "${HERMES_DASHBOARD:-}" = "yes" ]; then rm -f /etc/services.d/dashboard/down; fi\n' > /etc/cont-init.d/02-enable-dashboard \
 && chmod +x /etc/cont-init.d/02-enable-dashboard

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
