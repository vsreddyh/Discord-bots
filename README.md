# opencode-remote

Run [Hermes Agent](https://hermes-agent.nousresearch.com/) against a credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on credit/payment errors. Includes a private SearXNG instance for web search, a Discord-integrated gateway with voice, **four isolated bot profiles**, and a **Health Connect → Discord** pipeline for the food bot.

This repo is a **sandbox**: code and config live here, but never touch the live `~/.hermes` state or Docker daemons from inside it. Build, test, and validate here; apply changes to the live machine yourself.

## Architecture

```
                 ┌─────────────── test stack (docker compose) ───────────────┐
4 bot profiles ──► story ──┐                                                 │
(profiles/*)     helldivers │  each: hermes gateway run, own Discord token    │
                 money      ├──► zen-proxy (:4000) ─► OpenCode Zen ──┐        │
                 food ──────┤                                          └─► fallback
                            │                                          on credit error
Health Gateway (Android) ──► health-api (:8001) ─► profiles/food/data/health.db
                            │                              │
                            └──────── food bot posts daily summary to Discord
```

Two ways to run the same proxy code (`docker/proxy`):

| Stack | Location | What runs |
|-------|----------|-----------|
| **Live stack** | `docker/docker-compose.yml` | zen-proxy (:4000) + searxng (:8888) on the host, Hermes via `scripts/hermes.sh` |
| **Test stack** | `test/docker-compose.yml` | 4 Hermes bots (story, helldivers, money, food) + zen-proxy + health-api, all in Docker |

## Prerequisites

- Docker + Docker Compose
- `OPENCODE_API_KEY` (from [opencode.ai](https://opencode.ai))
- Optional: `DEEPINFRA_API_KEY` for fallback, `DISCORD_BOT_TOKEN` for Discord

## Quick Start

### Live stack (single Hermes instance on the host)

```bash
# 1. Set up API keys
cp .env.example .env && nano .env

# 2. Install Hermes, write config.yaml, patch toolsets, install skills
./scripts/hermes.sh init

# 3. Start everything (proxy → gateway → dashboard)
./scripts/hermes.sh start

# 4. Check status
./scripts/hermes.sh status

# 5. Stop everything
./scripts/hermes.sh stop
```

### Test stack (four Dockerized Discord bots)

```bash
# 1. Secrets: root .env (OPENCODE_API_KEY, HEALTH_SYNC_TOKEN) +
#    a .env per profile (its DISCORD_BOT_TOKEN, DISCORD_HOME_CHANNEL).
#    Templates: .env.example for root; copy an existing profile .env for the rest.
cp .env.example .env && nano .env
nano profiles/food/.env  # create per-bot .env files yourself (git-ignored)

# 2. Build the bot image (installs hermes-agent + patches hermes-god toolset)
docker compose -f test/docker-compose.yml build

# 3. Fix ownership of the bind mounts (once, as the mount host user)
docker compose -f test/docker-compose.yml run --rm story chown-data

# 4. Start everything
docker compose -f test/docker-compose.yml up -d

# 5. Status / logs
docker compose -f test/docker-compose.yml ps
docker compose -f test/docker-compose.yml logs -f food
```

### Health Gateway (Android → food bot)

1. Build the APK: `cd android/health-gateway && ./gradlew assembleRelease`
2. Install `app/build/outputs/apk/release/app-release.apk` on the phone.
3. In the app: server URL `http://<host-ip>:8001`, auth token = `HEALTH_SYNC_TOKEN`.
4. Grant Health Connect permissions (required manifest bits already configured for Android 14+).
5. Tap **Sync now** — first sync backfills 30 days, then hourly autosync sends only today.

Full walkthrough: [documentation.md](documentation.md)

## Commands

### `scripts/hermes.sh` — live stack

| Command | Description |
|---------|-------------|
| `init` | Install Hermes, render `config.yaml`, patch `hermes-god` toolset, install skills + deps, run `hermes doctor --fix` |
| `start` | Start Docker services → Hermes gateway → dashboard |
| `stop` | Stop dashboard → gateway → Docker services |
| `restart` | Stop then start |
| `status` | Show service states + health checks + tool summary |

### `docker/Makefile` — Docker only

| Target | Description |
|--------|-------------|
| `up` / `down` | Start / stop containers |
| `restart` | Down then up |
| `logs` | Tail container logs |
| `status` | `docker compose ps` |
| `build` | Rebuild with `--no-cache` |
| `setup` | Copy env template + start |

### Test stack — `docker compose -f test/docker-compose.yml`

`up -d` / `down` / `logs -f <service>` / `ps` / `build` / `exec <service> sh`. Services: `zen-proxy`, `story`, `helldivers`, `money`, `food`, `health-api`.

## How the fallback works

`docker/proxy/main.py` forwards every `/v1/chat/completions` request to OpenCode Zen. If Zen returns a payment/credit error (HTTP 402, or 400/403/404/429 bodies matching billing keywords), the proxy rewrites the model ID and retries on DeepInfra. All other errors pass through as-is.

| Zen model | DeepInfra fallback |
|-----------|--------------------|
| `deepseek-v4-flash-free` | `deepseek-ai/DeepSeek-V4-Flash` |
| `mimo-v2.5-free` | `MiniMaxAI/MiniMax-M3` |

Keep `MODEL_MAP` and the static `/v1/models` list in sync when adding models.

## Health Connect pipeline

- **Android app** (`android/health-gateway/`): reads steps, active/total calories, distance, sleep, and workouts from Health Connect; POSTs to `/api/health/sync` with a Bearer token. First sync backfills 30 days; afterwards hourly (WorkManager), rescheduled on boot.
- **`health-api`** (`docker/health-api/`, host `:8001`): FastAPI endpoint that persists to `profiles/food/data/health.db` (shared SQLite with the food bot) and posts a summary to the food home channel on Discord.
- **Auth**: `HEALTH_SYNC_TOKEN` in the root `.env` (comma-separated list of tokens for multiple installs).
- Server reachability: home LAN IP works at home; the Tailscale IP works anywhere while the phone's Tailscale is connected.

## Layout

```
├── AGENTS.md                # sandbox rules + repo facts (read first)
├── default-config.yaml      # Hermes config template (envsubst placeholders)
├── docker/
│   ├── docker-compose.yml   # live stack: zen-proxy (:4000) + searxng (:8888)
│   ├── Makefile
│   ├── proxy/               # credit-aware FastAPI proxy (shared with test stack)
│   └── health-api/          # Health Connect sync endpoint (FastAPI)
├── test/
│   ├── docker-compose.yml   # 4-bot test stack + zen-proxy + health-api
│   ├── Dockerfile           # hermes-agent + discord.py + hermes-god patch
│   └── entrypoint.sh        # config render + chown-data mode + gateway run
├── profiles/                # per-bot profile homes (story, helldivers, money, food)
├── workspace/               # per-bot host mounts (git-ignored)
├── android/health-gateway/  # Health Gateway Android app (Kotlin/Compose)
├── profile-plans/           # per-profile design plans
├── docs/                    # guides (Discord voice, ...)
├── scripts/hermes.sh        # live-stack entry point
└── skills/                  # copied to ~/.hermes/skills/ on init
```

## Init Presets

Defaults set by `hermes.sh init` (override via env vars or `.env`):

| Env var | Default | Purpose |
|---------|---------|---------|
| `HERMES_PROVIDER` | `custom` | Provider (proxy on localhost:4000) |
| `HERMES_MODEL` | `deepseek-v4-flash-free` | Model name |
| `HERMES_API_KEY` | *(empty)* | API key |
| `HERMES_BASE_URL` | `http://localhost:4000/v1` | Proxy endpoint |
| `HERMES_TERMINAL_BACKEND` | `local` | Terminal backend |
| `HERMES_TERMINAL_TIMEOUT` | `180` | Terminal timeout (s) |
| `HERMES_MAX_TURNS` | `90` | Max conversation turns |
| `HERMES_REASONING` | `medium` | Reasoning effort |
| `HERMES_MEMORY_ENABLED` | `true` | Cross-session memory |
| `HERMES_DISABLED_TOOLSETS` | *(broad list)* | Comma-separated toolsets to disable |
| `HERMES_EXTRA_KEYS` | *(empty)* | Semicolon-separated `KEY=val` |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard port |

## Skills

Installed to `~/.hermes/skills/` during `init`:

| Skill | Description |
|-------|-------------|
| `i-have-adhd` | ADHD-friendly output formatting (action-first, numbered steps) |
| `docker-management` | Manage the Docker stack: logs, health checks, cleanup |

Channel bindings live in `default-config.yaml` → `discord.channel_skill_bindings`.

## Troubleshooting

- **Proxy won't start** — `docker compose -f test/docker-compose.yml logs zen-proxy`; verify `OPENCODE_API_KEY` is in `.env`
- **Hermes can't reach the proxy** — `curl localhost:4000/health` should return `{"status":"ok"}`
- **Bots can't write their profile mount** — the mount is owned by your host user; run `docker compose -f test/docker-compose.yml run --rm <bot> chown-data` once
- **Health API unreachable** — `curl localhost:8001/health`; if the phone is away from home, Tailscale must be connected and the app URL must include `:8001`
- **App error "Failed to connect to …:80"** — the saved URL is missing `:8001`
- **Health Connect permission dialog never shows on OnePlus/OxygenOS** — uninstall and reinstall the APK (manifest health permissions changed); the app now falls back to opening Health Connect directly
- **Port in use** — change the mapping in the relevant `docker-compose.yml` and `HERMES_BASE_URL`
- **Gateway fails** — `~/.hermes/logs/gateway.log`; run `sudo loginctl enable-linger $USER`

## Security

- `.env` and `profiles/*/.env` contain live API keys and bot tokens. Both are git-ignored — never commit them. Only `.env.example` is tracked.
- Containers run as `uid 1000` with `HOME=/hermes-home`, only their own profile + workspace mounts (no host dirs, no Docker socket, no root `.env`).
- `health-api` requires a Bearer token for every write.
