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

RUN --mount=type=cache,target=/root/.cache/pip pip install hermes-agent pymongo mcp python-dotenv requests

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
