# Documentation

Deep dive into every part of `opencode-remote`. For a 2-minute overview, see [README.md](README.md).

## Table of Contents

1. [System overview](#system-overview)
2. [The Zen proxy](#the-zen-proxy)
3. [Docker stack](#docker-stack)
4. [`hermes.sh` lifecycle](#hermessh-lifecycle)
5. [Configuration reference](#configuration-reference)
6. [Skills](#skills)
7. [Discord integration](#discord-integration)
8. [Discord voice](#discord-voice)
9. [Security](#security)
10. [Extending the stack](#extending-the-stack)

---

## System overview

```
┌───────────────────────────────────────────────────────────────┐
│  Hermes Agent (installed to ~/.hermes)                        │
│  model.provider = custom                                      │
│  model.base_url = http://localhost:4000/v1                    │
└────────────────────────────┬──────────────────────────────────┘
                             │ every LLM call
                             ▼
┌───────────────────────────────────────────────────────────────┐
│  zen-proxy container (:4000)                                  │
│  POST /v1/chat/completions                                    │
│    1. try OpenCode Zen  → https://opencode.ai/zen/v1          │
│    2. credit error?     → DeepInfra  → api.deepinfra.com      │
└───────────────────────────────────────────────────────────────┘
        ▲                                              ▲
        │ web.search_backend: searxng                  │ Discord + voice
        ▼                                              ▼
┌──────────────────────┐                    ┌──────────────────────────┐
│ searxng (:8888)      │                    │ hermes-gateway (systemd) │
│ private metasearch   │                    │ + dashboard (:9119)      │
└──────────────────────┘                    └──────────────────────────┘
```

Four moving parts, started in order by `./scripts/hermes.sh start`:

1. **zen-proxy** (Docker, port 4000) — OpenAI-compatible LLM proxy
2. **searxng** (Docker, port 8888) — private web search for the agent
3. **hermes-gateway** (systemd user unit) — Discord bot + platform gateway
4. **dashboard** (background process, port 9119) — web UI

---

## The Zen proxy

Source: `docker/proxy/main.py` — a ~180-line FastAPI app. Container runs `uvicorn` on port 4000 (Dockerfile: `python:3.11-slim`).

### Backends

| Backend | Base URL | Auth |
|---------|----------|------|
| OpenCode Zen (primary) | `https://opencode.ai/zen/v1` | `Bearer $OPENCODE_API_KEY` |
| DeepInfra (fallback) | `https://api.deepinfra.com/v1/openai` | `Bearer $DEEPINFRA_API_KEY` |

### Endpoints

| Endpoint | Behavior |
|----------|----------|
| `GET /health` | `{"status": "ok"}` — used by the compose healthcheck |
| `GET /v1/models` | Static list of 2 Zen + 2 DeepInfra models (no upstream call) |
| `POST /v1/chat/completions` | The routing logic. Streaming and non-streaming supported |
| `/v1/embeddings`, `/v1/audio/*` | **Not implemented** — chat completions only |

### Fallback logic (chat completions)

1. Parse body; extract `model` and `stream`.
2. Forward the request unchanged to Zen.
3. If status `< 400` or the body is not a payment error → return Zen's response as-is.
4. If it is a payment error → look up the DeepInfra mapping for `model`.
5. No mapping or no `DEEPINFRA_API_KEY` → return the Zen error with a warning log.
6. Otherwise rewrite `body["model"]` to the DeepInfra ID and retry on DeepInfra.

### What counts as a "payment error"

`_is_payment_error()`:

- HTTP **402** → always.
- HTTP 400/403/404/429 → only if the response body contains any of ~20 keywords:
  `credits`, `insufficient funds`, `can only afford`, `billing`, `payment required`,
  `out of funds`, `run out of funds`, `balance_depleted`, `no usable credits`,
  `model_not_supported_on_free_tier`, `not available on the free tier`,
  `requires a subscription`, `upgrade for access`, `quota exceeded`, `quota_exceeded`,
  `too many tokens per day`, `daily limit`, `tokens per day`, `daily quota`,
  `resource exhausted`, `weekly usage limit`, `weekly limit`.

This mirrors Hermes' own `_is_payment_error` so the proxy and agent agree on what is a credit problem.

### Model mapping

| Zen model ID | DeepInfra model ID |
|--------------|--------------------|
| `deepseek-v4-flash-free` | `deepseek-ai/DeepSeek-V4-Flash` |
| `mimo-v2.5-free` | `MiniMaxAI/MiniMax-M3` |

To add a model: extend `MODEL_MAP` in `main.py` (and the `/v1/models` list), then `make -C docker build` + `make -C docker up`.

### Streaming

- `stream: true` → raw SSE passthrough (`text/event-stream`, `cache-control: no-cache`, `x-accel-buffering: no`).
- `stream: false` → JSON passthrough.
- Single shared `httpx.AsyncClient` (timeout 120s, connect 10s), closed on shutdown.

---

## Docker stack

`docker/docker-compose.yml`:

### zen-proxy

- Builds from `./proxy` (Dockerfile), port `4000:4000`
- `env_file: ../.env` **plus** explicit `OPENCODE_API_KEY` / `DEEPINFRA_API_KEY`
- Healthcheck: `curl -f http://localhost:4000/health`, 10s interval, 10 retries, 10s start period
- `restart: unless-stopped`

### searxng

- `searxng/searxng:latest`, host port `${SEARXNG_PORT:-8888}` → container 8080
- Requires `SEARXNG_SECRET_KEY` and `SEARXNG_BASE_URL`
- Volume `searxng_data:/etc/searxng` for settings persistence
- Hardened: drops ALL capabilities, re-adds only `CHOWN`, `SETGID`, `SETUID`

### Makefile targets (`docker/`)

`up` / `down` / `restart` / `logs` / `status` / `build` / `setup`.

Note: `make setup` runs `cp -n .env.example .env` inside `docker/`, but the compose file reads the **root** `.env` (`env_file: ../.env`). The authoritative env file is the repo-root `.env`; `docker/.env` is not used. If you only ever use `scripts/hermes.sh`, use the root `.env`.

### Ports

| Service | Host port |
|---------|-----------|
| zen-proxy | 4000 |
| searxng | 8888 (`SEARXNG_PORT`) |
| hermes dashboard | 9119 (`HERMES_DASHBOARD_PORT`) |

---

## `hermes.sh` lifecycle

Source: `scripts/hermes.sh`. One entry point for everything. Order matters — reverse on stop.

### `init`

1. Install Hermes via `https://hermes-agent.nousresearch.com/install.sh` if missing.
2. Render `default-config.yaml` → `~/.hermes/config.yaml` via `envsubst` (only if config doesn't already exist).
3. Patch the **`hermes-god`** toolset into `~/.hermes/hermes-agent/toolsets.py` (replaces `hermes-discord`; tools: `discord` + `discord_admin`, includes: `hermes-cli`, `debugging`, `coding`) and swap `hermes-discord` → `hermes-god` in `hermes_cli/platforms.py`. ~51 tools total.
4. Copy `skills/*` → `~/.hermes/skills/` (skips existing).
5. Copy project `.env` → `~/.hermes/.env`.
6. Install deps: `edge-tts` (TTS), `PyNaCl>=1.5.0` + `davey` (Discord voice), `libopus0` + `ffmpeg` (apt), `agent-browser` (npm global + Chromium).
7. Run `hermes doctor --fix` and `hermes tools --summary`.
8. Pre-build dashboard UI if `web/dist` is missing.

Re-run `init` after changing `default-config.yaml` or skills — it skips existing config/skills and re-patches toolsets idempotently.

### `start` (order)

1. Docker compose up (zen-proxy + searxng)
2. `hermes gateway start` (systemd user unit)
3. `nohup hermes dashboard --host 127.0.0.1 --port ${HERMES_DASHBOARD_PORT:-9119} --no-open --skip-build` — PID in `~/.hermes/dashboard.pid`, logs in `~/.hermes/dashboard.log`

### `stop` (reverse)

Dashboard (`hermes dashboard --stop`, kill fallback) → gateway (`hermes gateway stop`) → `docker compose down`.

### `status`

Shows: zen-proxy (+port, +`curl /health`), gateway (systemd), dashboard (PID), searxng (+port), active profile, `hermes tools --summary`, log/config paths.

### Gateway systemd

The gateway runs as a **systemd user unit** (`hermes-gateway`). Requires lingering for headless operation:

```bash
sudo loginctl enable-linger $USER
```

---

## Configuration reference

### `default-config.yaml`

Template consumed by `envsubst`. Placeholders:

| Placeholder | Populated from |
|-------------|----------------|
| `${HERMES_MODEL}` | `HERMES_MODEL` (default `deepseek-v4-flash-free`) |
| `${HERMES_BASE_URL}` | `HERMES_BASE_URL` (default `http://localhost:4000/v1`) |
| `${HERMES_API_KEY}` | `HERMES_API_KEY` (default empty) |
| `${HERMES_MAX_TURNS}` | `HERMES_MAX_TURNS` (default `90`) |
| `${HERMES_REASONING}` | `HERMES_REASONING` (default `medium`) |
| `${HERMES_MEMORY_ENABLED}` | `HERMES_MEMORY_ENABLED` (default `true`) |
| `${HERMES_TERMINAL_BACKEND}` | `HERMES_TERMINAL_BACKEND` (default `local`) |
| `${HERMES_TERMINAL_TIMEOUT}` | `HERMES_TERMINAL_TIMEOUT` (default `180`) |
| `${HERMES_DISABLED_YAML}` | generated from `HERMES_DISABLED_TOOLSETS` (comma list → YAML) |
| `${DISCORD_HOME_CHANNEL}` | `DISCORD_HOME_CHANNEL` (channel skill bindings) |

Defaults live in `cmd_init` (hermes.sh lines 36–46), not in the YAML.

### Notable fixed settings

| Section | Value | Why |
|---------|-------|-----|
| `auxiliary.vision.model` | `mimo-v2.5-free` | vision model via the same proxy |
| `web.search_backend` | `searxng` | private search through the searxng container |
| `terminal.backend` | `local` | terminal runs on the host |
| `approvals.mode` | `smart` | approval prompts |
| `session_reset` | idle 1440 min, at 04:00 | daily reset |
| `curator` | enabled, 24h interval, stale 30d / archive 45d | context management |
| `platform_toolsets` | cli → `file`, `terminal`; discord → `hermes-god` | per-platform tool access |
| `discord.channel_skill_bindings` | home channel → `i-have-adhd`, `docker-management` | auto-load skills |
| `_config_version` | `33` | Hermes config schema version |

### `.env` variables

| Var | Required | Purpose |
|-----|----------|---------|
| `OPENCODE_API_KEY` | **yes** | Zen backend auth |
| `DEEPINFRA_API_KEY` | no | DeepInfra fallback auth |
| `DISCORD_BOT_TOKEN` | no | Discord bot |
| `DISCORD_ALLOW_ALL_USERS` | no | `true` = open bot |
| `DISCORD_AUTO_THREAD` | no | auto-threading in Discord |
| `DISCORD_ALLOWED_USERS` | no | allowlist |
| `DISCORD_HOME_CHANNEL` | no | home channel + skill binding |
| `SEARXNG_URL` | no | default `http://localhost:8888` |
| `SEARXNG_SECRET_KEY` | no | searxng encryption secret |
| `SEARXNG_PORT` / `SEARXNG_HOSTNAME` | no | compose overrides |

`LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` / `OPENCODE_LITELLM_KEY` may appear in `.env` — legacy leftovers; no LiteLLM service exists in this stack.

---

## Skills

Copied from `skills/` → `~/.hermes/skills/` on `init` (existing skills are skipped).

- **`i-have-adhd`** — formats output for an ADHD reader: action-first, numbered steps, capped lists, concrete time estimates, matter-of-fact errors.
- **`docker-management`** — compose commands for the stack: status, logs, health checks, rebuild, cleanup, pitfalls.

To auto-load a skill in a channel, set `discord.channel_skill_bindings` in `default-config.yaml`:

```yaml
discord:
  channel_skill_bindings:
    - id: "YOUR_CHANNEL_ID"
      skills:
        - i-have-adhd
```

Then `./scripts/hermes.sh init && hermes gateway restart`.

---

## Discord integration

- The gateway is a systemd user unit; `hermes-god` is the patched toolset giving the bot `discord` + `discord_admin` tools plus CLI/debugging/coding includes.
- Voice FX enabled by default (`discord.voice_fx`): ambient idle sound, acknowledgement phrases before tool calls, Edge TTS responses (`en-US-AriaNeural`).
- Full voice walkthrough: [docs/disc-voice-channel.md](docs/disc-voice-channel.md) — `/voice join`, `/voice tts`, `/voice on|off|status`, `/voice leave`.

---

## Security

- `.env` holds live API keys + bot tokens. Git-ignored (`.gitignore` lines 4–5). Only `.env.example` is tracked. Never commit `.env`.
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped (CHOWN/SETGID/SETUID only).
- Proxy passes through full response bodies — billing messages from Zen reach the log; no key material is logged.
- Dashboard binds to `127.0.0.1` only.

---

## Extending the stack

### Add a model to the proxy

1. Add the mapping to `MODEL_MAP` in `docker/proxy/main.py`.
2. Add it to the `/v1/models` static list.
3. Rebuild + restart: `make -C docker build && make -C docker up`.
4. Point Hermes at it via `HERMES_MODEL` in `.env` (or `~/.hermes/config.yaml`).

### Add a profile (planned)

`profiles/`, `tools/`, `workspace/`, and `skills/improve-codebase-architecture/` are empty placeholders. The deleted `future.md` in HEAD outlines: one profile per gateway instance, `terminal.backend: docker` for isolation, `hermes profile create discord --clone default`. `profile-plans/food-workout-plan.md` is a drafted food/workout profile, not yet implemented.

### Add a skill

Drop a directory with `SKILL.md` (with `name` + `description` frontmatter) into `skills/`, re-run `./scripts/hermes.sh init`, then bind it per channel via `channel_skill_bindings`.
