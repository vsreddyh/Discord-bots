# Documentation

Deep dive into every part of `opencode-remote`. For a 2-minute overview, see [README.md](README.md).

## Table of Contents

1. [System overview](#system-overview)
2. [The Zen proxy](#the-zen-proxy)
3. [Live stack](#live-stack)
4. [`hermes.sh` lifecycle](#hermessh-lifecycle)
5. [Test stack](#test-stack)
6. [Profiles](#profiles)
7. [Health Connect pipeline](#health-connect-pipeline)
8. [Configuration reference](#configuration-reference)
9. [Skills](#skills)
10. [Discord integration](#discord-integration)
11. [Security](#security)
12. [Extending the stack](#extending-the-stack)

---

## System overview

The repo runs **two parallel stacks** that share the same proxy code:

```
LIVE STACK (on the host)                        TEST STACK (all Docker)
──────────────────────────                      ─────────────────────────
Hermes Agent (systemd)      ─┐                  story ─┐
model.base_url = :4000       │                  helldivers │ each = own
                             ▼                  money      ├─ hermes gateway
┌──────────────────────────┐                   food ──────┤ (own Discord token)
│  zen-proxy (Docker)      │                              ▼
│  POST /v1/chat/completions│            ┌─────────────────────────────┐
│    → OpenCode Zen         │            │  zen-proxy (:4000)          │
│    → DeepInfra on credit  │            └─────────────────────────────┘
│    errors                 │
└──────────────────────────┘
        ▲                            Health Gateway (Android, :8001)
        │ web.search: searxng        │
        │                            ▼
searxng (:8888)              ┌───────────────────────┐
        │                   │  health-api (Docker)  │
        │                   │  → profiles/food/     │
hermes-gateway + dashboard  │     data/health.db    │
                            │  → Discord summary    │
                            └───────────────────────┘
```

- **zen-proxy** — OpenAI-compatible LLM proxy (code shared by both stacks).
- **searxng** — private web search (live stack only; test stack doesn't need it).
- **test stack** — four Dockerized Hermes bots, each with its own profile home and Discord token.
- **health-api + Android app** — the food bot's Health Connect sync pipeline.

---

## The Zen proxy

Source: `docker/proxy/main.py` — a ~180-line FastAPI app. Container runs `uvicorn` on port 4000 (Dockerfile: `python:3.11-slim`). Both stacks build this same directory.

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

To add a model: extend `MODEL_MAP` in `main.py` (and the `/v1/models` list), then rebuild the proxy in whichever stack you use.

### Streaming

- `stream: true` → raw SSE passthrough via **`StreamingResponse`** (`text/event-stream`, `cache-control: no-cache`, `x-accel-buffering: no`). Passing a plain `Response` with an async iterator breaks streaming (it renders the whole body before sending).
- `stream: false` → JSON passthrough.
- Single shared `httpx.AsyncClient` (timeout 120s, connect 10s), closed on shutdown.

---

## Live stack

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

Note: `make setup` runs `cp -n .env.example .env` inside `docker/`, but the compose file reads the **root** `.env` (`env_file: ../.env`). The authoritative env file is the repo-root `.env`; `docker/.env` is not used.

### Ports

| Service | Host port |
|---------|-----------|
| zen-proxy | 4000 |
| searxng | 8888 (`SEARXNG_PORT`) |
| hermes dashboard | 9119 (`HERMES_DASHBOARD_PORT`) |

---

## `hermes.sh` lifecycle

Source: `scripts/hermes.sh`. One entry point for the live stack. Order matters — reverse on stop.

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

## Test stack

`test/docker-compose.yml` + `test/Dockerfile` + `test/entrypoint.sh`. Purpose: run the **four real bot profiles** in Docker against the same proxy, fully isolated from the host.

### Services

| Service | Image | Host port | Role |
|---------|-------|-----------|------|
| `zen-proxy` | `../docker/proxy` | 4000 | LLM proxy (same code as live) |
| `story` / `helldivers` / `money` / `food` | `test/Dockerfile` | — | One Hermes Discord bot each |
| `health-api` | `../docker/health-api` | 8001 | Food bot's Health Connect sync endpoint |

### Bot containers

- Built from `test/Dockerfile`: `python:3.11-slim` + `hermes-agent` + **`discord.py[voice]==2.7.1` pre-installed** (the lazy install fails as non-root with `Permission denied: '/.local'`). The Dockerfile also runs the same `hermes-god` toolset patch as `hermes.sh init` (grep-guarded, idempotent).
- Run as **`user: "1000:1000"`** with `HOME=/hermes-home`, so writes land in the profile bind mount (owned by the host user) instead of a private container layer.
- Mounts: `profiles/<bot>:/hermes-home` and `workspace/<bot>:/workspace`. **Nothing else** — no Docker socket, no host home, no other profiles, no root `.env`.
- `depends_on: zen-proxy (service_healthy)` — bots wait for the proxy before starting.

### `entrypoint.sh`

1. Sources `$HERMES_HOME/.env` (per-profile secrets) into the environment.
2. `chown-data` mode: `chown -R $HERMES_UID:$HERMES_GID $HERMES_HOME /workspace` (defaults `1000:1000`). Run once via `docker compose run --rm <bot> chown-data` after first `build` when mounts were created by root.
3. Renders `${VAR}` placeholders in `config.yaml` (the profile configs are `envsubst` templates, like `default-config.yaml`).
4. `exec hermes gateway run --force --accept-hooks`.

### Starting it

```bash
docker compose -f test/docker-compose.yml build
docker compose -f test/docker-compose.yml run --rm story chown-data   # once
docker compose -f test/docker-compose.yml up -d
```

---

## Profiles

`profiles/` holds the **live home directory** for each bot (`config.yaml`, `SOUL.md`, `state.db`, sessions, kanban, etc.). A profile is bind-mounted at `/hermes-home` in its container.

| Profile | Discord bot | Home channel | Purpose |
|---------|-------------|--------------|---------|
| `story` | Portas-Mantainer | `1523762320986214541` | Story/worldbuilding from a lore vault |
| `helldivers` | Rouge Automaton | `1535601629884317696` | Helldivers 2 companion |
| `money` | Miser | `1535611174039719976` | Money management |
| `food` | Caped Baldy (Saitama) | `1535613331610669117` | Food + workouts, Health Connect sync |

Design plans: `profile-plans/*.md`.

### Per-profile `.env`

Each `profiles/<bot>/.env` carries that bot's secrets (`DISCORD_BOT_TOKEN`, `DISCORD_HOME_CHANNEL`, etc.). The entrypoint sources it, so `DISCORD_BOT_TOKEN` in the root `.env` is **not** used by the test stack. Files are git-ignored — there is no committed template, so create them by copying an existing profile's `.env`.

### Config notes

- All four `config.yaml` files set `onboarding.profile_build: off` (plus the seen latch) so the gateway **stops rewriting the tracked config** on startup.
- `config.rendered.yaml` is the entrypoint's post-`envsubst` output — git-ignored, debugging aid.

---

## Health Connect pipeline

The food bot ingests watch data (Redmi Watch 5 Lite) via Android Health Connect. Three components:

```
Android Health Gateway app ──POST /api/health/sync──► health-api (:8001)
                                                          │
                                                          ▼
                                              profiles/food/data/health.db
                                                          │
                                                          ▼
                                              Discord summary to food home channel
```

### health-api

Source: `docker/health-api/main.py` (FastAPI, port 8000 in-container / 8001 on host).

- **Auth**: every `/api/health/sync` requires `Authorization: Bearer <token>`, where the token comes from `HEALTH_API_TOKENS` (comma-separated) falling back to `HEALTH_SYNC_TOKEN` in the root `.env`. One token per install.
- **Storage**: SQLite at `/data/health.db` → bind-mounted to `profiles/food/data/health.db`, the same DB the food bot reads. Schema:
  - `daily_stats (date PK, steps, active_calories, synced_at)` — upsert per day.
  - `sleep_log (date, sleep_start, wake_time, hours, quality, synced_at)` — dedupe on `sleep_start`.
  - `workouts (date, type, duration, notes, synced_at)` — dedupe on date+type+duration.
- **Idempotent**: repeated identical payloads never duplicate rows.
- **Discord**: after each successful sync, best-effort `_post_discord_update()` posts a summary to `DISCORD_HOME_CHANNEL` using `DISCORD_BOT_TOKEN` from `profiles/food/.env`. Failures are logged, never fail the API response.
- Container runs as uid 1000 (must read/write the food profile's mount).

### Android app

Source: `android/health-gateway/` — Kotlin + Jetpack Compose, Health Connect SDK 1.1.0, AGP 8.9.1, Gradle 8.14.3, compileSdk 36 / minSdk 28 / targetSdk 35.

- **Reads**: steps, active calories, total calories, distance, sleep (with stage counts), workouts (with distance + calories).
- **Sync flow**: first sync backfills **30 days** (per-day steps/calories + all sleep/workouts), then sets the `first_sync_done` pref. Later syncs send only today. `SyncWorker` (WorkManager, hourly) + `BootReceiver` reschedule on boot/update; `SyncService` foregrounds the manual sync.
- **Auth**: server URL + auth token stored in `SharedPreferences` (matches `HEALTH_SYNC_TOKEN`).
- **Build**: `cd android/health-gateway && ./gradlew assembleRelease` → `app/build/outputs/apk/release/app-release.apk`. Release build is minified (R8) + resource-shrunk; the debug keystore signs it (sideload only).
- **Android 14+ permission requirement**: the manifest declares the `android.permission.health.*` data permissions AND a permissions-rationale component (`ViewPermissionUsageActivity` with both `VIEW_PERMISSION_USAGE` and `ACTION_SHOW_PERMISSIONS_RATIONALE` intent-filters). Without these, Health Connect **silently revokes** access — no dialog, and the app never appears in Health Connect's list. If an old APK (pre-manifest-fix) is installed, **uninstall first** so the new permissions register.
- **OEM caveat**: on OnePlus/OxygenOS the grant dialog can be killed by background-activity-launch restrictions; the app falls back to opening the Health Connect app, and whitelisting the app in Battery optimization keeps the hourly job alive.

### Endpoint contract

`POST /api/health/sync` with:

```json
{
  "device": "Redmi Watch 5 Lite",
  "syncedAtIso": "2026-08-08T12:00:00Z",
  "steps": 8452,
  "activeCaloriesKcal": 312.5,
  "sleep": [{ "startIso": "…", "endIso": "…", "totalMinutes": 420, "stages": { "SLEEPING": 350 } }],
  "workouts": [{ "startIso": "…", "endIso": "…", "title": "Walk", "type": "WALK", "distanceMeters": 2500, "caloriesKcal": 120.0 }]
}
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

Defaults live in `cmd_init` (hermes.sh lines 36–46), not in the YAML. Profile configs are the same `envsubst`-template approach, rendered at container start by `test/entrypoint.sh`.

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
| `DISCORD_BOT_TOKEN` | no | Discord bot (live stack; per-profile .env overrides in test stack) |
| `DISCORD_ALLOW_ALL_USERS` | no | `true` = open bot |
| `DISCORD_AUTO_THREAD` | no | auto-threading in Discord |
| `DISCORD_ALLOWED_USERS` | no | allowlist |
| `DISCORD_HOME_CHANNEL` | no | home channel + skill binding |
| `SEARXNG_URL` | no | default `http://localhost:8888` |
| `SEARXNG_SECRET_KEY` | no | searxng encryption secret |
| `SEARXNG_PORT` / `SEARXNG_HOSTNAME` | no | compose overrides |
| `HEALTH_SYNC_TOKEN` | for health-api | Bearer token(s) for the Android app |

`LITELLM_MASTER_KEY` / `LITELLM_SALT_KEY` / `OPENCODE_LITELLM_KEY` may appear in `.env` — legacy leftovers; no LiteLLM service exists in this stack.

---

## Skills

Copied from `skills/` → `~/.hermes/skills/` on `init` (existing skills are skipped).

- **`i-have-adhd`** — formats output for an ADHD reader: action-first, numbered steps, capped lists, concrete time estimates, matter-of-fact errors.
- **`docker-management`** — compose commands for the stack: status, logs, health checks, rebuild, cleanup, pitfalls.

To auto-load a skill in a channel, set `discord.channel_skill_bindings` in the profile's `config.yaml`:

```yaml
discord:
  channel_skill_bindings:
    - id: "YOUR_CHANNEL_ID"
      skills:
        - i-have-adhd
```

Then restart the gateway (`docker compose -f test/docker-compose.yml restart <bot>` in the test stack).

---

## Discord integration

- The live gateway is a systemd user unit; the test-stack gateways are the bot containers. Both use the `hermes-god` patched toolset (`discord` + `discord_admin` tools plus CLI/debugging/coding includes).
- Voice FX enabled by default (`discord.voice_fx`): ambient idle sound, acknowledgement phrases before tool calls, Edge TTS responses (`en-US-AriaNeural`).
- Full voice walkthrough: [docs/disc-voice-channel.md](docs/disc-voice-channel.md) — `/voice join`, `/voice tts`, `/voice on|off|status`, `/voice leave`.

---

## Security

- `.env` and `profiles/*/.env` hold live API keys + bot tokens. Git-ignored (`.gitignore`). Only `.env.example` is tracked. Never commit either.
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped (CHOWN/SETGID/SETUID only).
- Proxy passes through full response bodies — billing messages from Zen reach the log; no key material is logged.
- Dashboard binds to `127.0.0.1` only.
- **Test-stack isolation**: bot containers run as uid 1000 with only their own profile + workspace mounts, `HOME=/hermes-home`, no Docker socket, no host directories, and no root `.env` (health-api is the only service that reads the root env). Verified: a bot cannot read sibling profiles or host files.
- **health-api**: Bearer-token auth on every write; DB lives inside the food profile mount, readable by the food bot (same uid).

---

## Extending the stack

### Add a model to the proxy

1. Add the mapping to `MODEL_MAP` in `docker/proxy/main.py`.
2. Add it to the `/v1/models` static list.
3. Rebuild + restart the proxy in the relevant stack (live: `make -C docker build && make -C docker up`; test: `docker compose -f test/docker-compose.yml build zen-proxy && up -d zen-proxy`).
4. Point Hermes at it via `HERMES_MODEL` in the profile `.env` / config.

### Add a bot profile

1. Write the design plan under `profile-plans/`.
2. Create `profiles/<name>/` — copy `config.yaml` + `.env` + `SOUL.md` from an existing profile; set the Discord token and home channel.
3. Add a service block to `test/docker-compose.yml` (same pattern as `story`): mounts, uid, `depends_on: zen-proxy`.
4. `docker compose -f test/docker-compose.yml up -d <name>`.

### Add a skill

Drop a directory with `SKILL.md` (with `name` + `description` frontmatter) into `skills/`, re-run `./scripts/hermes.sh init` (live) or bind it per channel in the profile config, then restart the gateway.
