# opencode-remote

Run **four Hermes bots** (story, money, food, resumes) against an
OpenCode Zen LLM proxy. Private SearXNG for search, **one multiplexed Discord
gateway** (all four bots in a single Hermes process, one unified dashboard), and a
**Health Connect → food bot** pipeline. Domain data (money, food) lives in
**remote MongoDB** — local SQLite is gone.

**Everything runs in Docker.** The whole stack is one compose file
(`docker/docker-compose.yml`): searxng, health-api, the **single
multiplexed bot gateway** (with dashboard supervised alongside it via `s6` when
`HERMES_DASHBOARD=1` — mirrors official `nousresearch/hermes-agent`), and a one-shot retention job.
Development runs the SAME compose file; `HERMES_ENV=dev` in the root `.env`
switches every data consumer to a temporary local `mongodb` container
(`mongodb://mongodb:27017`, no volume, ephemeral) — dev writes never touch
the prod DB. One Hermes gateway container serves all four bots + dashboard: `profiles/master` is the gateway home,
the four are named profiles nested under it
(`profiles/master/profiles/<bot>/`), each with its own profile home, workspace,
Discord token, and per-profile credential scope — no host Hermes install, no
native processes.

This repo is a **sandbox**: code and config live here; preview and validate
changes here, then apply them on your live machine yourself.

## Architecture

```
                              remote MongoDB (money, food)
                                           ▲
                            docker containers
 story ──┐               │        ┌──── searxng (:8888)
 money ──┤ ONE gateway   │ HERMES_HOME=  ▼        │
 food ───┤ (multiplex:    │ /hermes-home │   OpenCode Zen direct
 resumes ─┘  4 profiles)  │  (gateway +  │  (https://opencode.ai/zen/v1)
         └── HERMES_DASHBOARD=1 via s6 ─┤ dashboard) │
         each profile: own Discord token + workspace + secret scope
Health Gateway (Android) ──► health-api (:8001) ──► MongoDB
Hermes dashboard ──► 0.0.0.0:9119 via gateway (s6, password auth, unified — lists all 4 bots)
retention ──► one-shot `docker compose run --rm retention` (cron 03:00)
```

| Component | Runs as | Port |
|-----------|---------|------|
| searxng | container | 8888 |
| health-api | container | 8001 |
| all 4 bots + dashboard | ONE `gateway` container, `s6` supervised (`HERMES_HOME=/hermes-home`, `gateway.multiplex_profiles: true`, `HERMES_DASHBOARD=1`) | 9119 (dashboard via gateway) |
| retention | one-shot container | — |

## Bots

| Bot | Name (Discord) | Domain data | Retention |
|-----|----------------|-------------|-----------|
| `story` | Portas-Mantainer | lore vault (`workspace/portals`, repo `vsreddyh/portals`) | — |
| `money` | Miser | `money_transactions` | autowipe when oldest entry > 90 days |
| `food` | Caped Baldy | `food_daily_stats` / `food_sleep_log` / `food_workouts` / `food_weight` | date rows pruned after 30 days; **weight never touched** |
| `resumes` | Job Bot | resumes (`workspace/resumes`, repo `vsreddyh/Resume`) | — |

## Prerequisites

- Docker + Compose v2
- `OPENCODE_ZEN_API_KEY` (from [opencode.ai](https://opencode.ai))
- Remote MongoDB URI (money/food)
- Per-bot `DISCORD_BOT_TOKEN_<BOT>`/`DISCORD_HOME_CHANNEL_<BOT>`

## Quick Start

```bash
# 1. Set up API keys
cp .env.example .env && nano .env

# 2. Build images, install retention cron
./scripts/hermes.sh init

# 3. All secrets live in the ONE root .env (git-ignored) — edit it:
#    per-bot Discord tokens/channels (DISCORD_BOT_TOKEN_<BOT>, ...), Mongo
#    URI, dashboard password. No per-profile .env files exist anymore.
nano .env

# 4. Start everything
./scripts/hermes.sh start

# 5. Check status
./scripts/hermes.sh status

# 6. Stop everything
./scripts/hermes.sh stop
```

Dashboard: `http://<host>:9119` — log in with the username/password set in
the root `.env` (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`).

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/hermes.sh init` | Self-install host deps (curl, docker + compose, python3, cron, opencode CLI), build images, seed the single root `.env` (+ copies skills), install retention cron. Skip opencode with `HERMES_NO_OPENCODE=1`. Only git + sudo must already exist. |
| `./scripts/hermes.sh start` | `docker compose up -d --build`, then run retention once |
| `./scripts/hermes.sh stop` | `docker compose down` (keeps volumes) |
| `./scripts/hermes.sh restart` | Stop then start |
| `./scripts/hermes.sh status` | `docker compose ps` |
| `./scripts/hermes.sh clean` | **Destructive.** Down `-v`, wipe `run/`, profile runtime + rendered config + per-profile `.env`, retention cron. Remote MongoDB untouched. |

Direct docker access for a single service:

```bash
docker compose -f docker/docker-compose.yml logs -f gateway
docker compose -f docker/docker-compose.yml restart gateway
```

## Data retention

`scripts/retention.sh run` runs the `retention` one-shot service
(`docker compose run --rm retention`, which executes `tools/retention.py`) daily
at 03:00 (cron, installed by `init`) and once on every `start`. It only touches
remote MongoDB; `--dry-run` prints what would be deleted.

- **money** — transactions older than 90 days are wiped (autowipe every ~3 months of accumulated data).
- **food** — `daily_stats`, `sleep_log`, `workouts` rows older than 30 days are pruned. `food_weight` is **never** touched.
- **story / resumes** — git-backed repos (`workspace/portals`, `workspace/resumes`), no DB retention.

## Development mode

Same single compose file as production. Set `HERMES_ENV=dev` in the root `.env`
and every data consumer (bots, health-api, retention) uses a **temporary local
`mongodb` container** (`mongodb://mongodb:27017`, no volume — data lost on
`down`/`restart`) instead of the remote Atlas cluster. `prod` or unset = remote
`MONGODB_URI` as-is.

```bash
# prod or dev — same file, same commands
./scripts/hermes.sh start
# or directly (dev needs the profile):
HERMES_ENV=dev docker compose --profile dev -f docker/docker-compose.yml up -d --build
# or via COMPOSE_PROFILES (set automatically by scripts/lib/common.sh):
HERMES_ENV=dev ./scripts/hermes.sh start
```

The gateway home `profiles/master/config.yaml.template` and each
`profiles/master/profiles/<bot>/config.yaml.template` (rendered by
`test/entrypoint.sh` to `config.yaml` with docker defaults: `https://opencode.ai/zen/v1`,
`/workspace/<bot>`, `hermes`) use `${DISCORD_HOME_CHANNEL}` templating — the
entrypoint exports the per-profile channel before rendering. The entrypoint
also writes each profile's `.env` — its own `DISCORD_BOT_TOKEN` /
`DISCORD_HOME_CHANNEL` — from the `DISCORD_BOT_TOKEN_<BOT>` /
`DISCORD_HOME_CHANNEL_<BOT>` env vars compose maps from the root `.env`. The
shared Mongo helper is mounted at `/tools` (read-only).

## Health Connect pipeline

- **Android app** (`android/health-gateway/`): reads steps, calories, distance,
  sleep, workouts from Health Connect; POSTs to `/api/health/sync` with a Bearer
  token. First sync backfills 30 days, then hourly.
- **health-api** (`:8001`): persists to `food_daily_stats` /
  `food_sleep_log` / `food_workouts` in MongoDB and posts a summary to the food
  home channel on Discord.
- **Auth**: `HEALTH_SYNC_TOKEN` in the root `.env` (comma-separated for
  multiple installs).

## Remote MongoDB

Money and food store domain data in MongoDB (see table above).
Connection config lives in the root `.env` (`MONGODB_URI`, `MONGODB_DB`, default
`hermes`). Bots use the shared helper `tools/mongo.py` (pymongo):

```bash
python3 tools/mongo.py insert money_transactions '{"date":"2026-08-08","amount":300,"type":"expense","category":"groceries"}'
python3 tools/mongo.py aggregate money_transactions '[{"$group":{"_id":"$category","total":{"$sum":"$amount"}}}]'
```

Collections: `money_transactions` · `food_daily_stats` / `food_sleep_log` /
`food_workouts` / `food_weight`. Store dates as `YYYY-MM-DD` or full ISO strings — retention relies on
lexicographic comparison.

## Proxy (Zen-only)

`docker/proxy/main.py` forwards `/v1/chat/completions` to OpenCode Zen
(`https://opencode.ai/zen/v1`). No fallback — Zen is the sole provider.
`/v1/models` is derived from `SUPPORTED_MODELS`, so adding a model there is enough.

## Isolation

The **one `gateway` container** (now also running dashboard via `s6` when `HERMES_DASHBOARD=1`) sees only:
- the gateway home tree (`profiles/master` as `/hermes-home`, which includes
  the four named profiles under `profiles/master/profiles/`),
- the shared workspace (`workspace/` as `/workspace`),
- the shared `/tools` helper **read-only**.

No root `.env`, no Docker socket, no host paths. Per-profile Discord tokens are
not merged into one global env — the entrypoint writes each profile's own `.env`
(`DISCORD_BOT_TOKEN` / `DISCORD_HOME_CHANNEL`) inside its profile home, and
Hermes reads them as per-profile secrets with a narrow scope. Bots have normal
outbound network (Discord, remote Mongo, OpenCode Zen). `health-api` gets
`MONGODB_URI` plus the food bot's token/channel, injected via compose from
`DISCORD_BOT_TOKEN_FOOD`/`DISCORD_HOME_CHANNEL_FOOD`, to post summaries.

## Skills

Hermes skill content (including autogenerated and `nousresearch/` packs), the
skill-curator learning state (`.curator_state` / `.usage.json`), and each
`SOUL.md` are **committed** — so the whole personality and learned state moves
with the repo between VPSes. Only transient per-run session/log/state files are
git-ignored (runtime `memories/` are not tracked). Channel bindings live in each
`config.yaml.template` → `discord.channel_skill_bindings`.

## Layout

```
├── AGENTS.md                # sandbox rules + repo facts
├── default-config.yaml      # reference Hermes config (master-style)
├── docker/
│   ├── docker-compose.yml   # FULL live stack: searxng + health-api + 1 multiplexed gateway (+ dashboard via s6, HERMES_DASHBOARD=1) + retention
│   └── health-api/          # Health Connect sync endpoint
├── test/                    # shared bot image source (Dockerfile + entrypoint) — NOT a stack
│   ├── Dockerfile           # shared bot image (bakes in hermes-god + s6-overlay)
│   └── entrypoint.sh        # renders all profiles' config.yaml + writes per-profile .env, runs gateway (or gateway+dashboard via s6 when HERMES_DASHBOARD=1)
├── profiles/
│   └── master/              # gateway home (config.yaml.template + SOUL.md)
│       └── profiles/        # named profiles: story, money, food, resumes (each its own config + SOUL + skills)
├── workspace/               # per-bot terminal cwd, <bot>/ per profile (git-ignored)
├── run/                     # retention + sysmon logs (git-ignored)
├── tools/                   # mongo.py (shared helper) + retention.py (data lifecycle)
├── scripts/hermes.sh        # init/start/stop/restart/status/clean (docker orchestrator)
├── scripts/retention.sh     # wrapper → docker compose run --rm retention
├── scripts/sysmon.sh        # host-wide resource sampler (record/report/install/remove)
└── skills/                  # project skills copied to each profile on init
```

## Troubleshooting

- **LLM unreachable** — check `OPENCODE_ZEN_API_KEY` in `.env` and `docker compose -f docker/docker-compose.yml logs gateway` for 401/403 from `https://opencode.ai/zen/v1`.
- **A bot not responding on Discord** — `docker compose -f docker/docker-compose.yml logs gateway` (all 4 bots share this one process); confirm its `DISCORD_BOT_TOKEN_<BOT>`/`DISCORD_HOME_CHANNEL_<BOT>` in `.env`; `docker compose -f docker/docker-compose.yml restart gateway`.
- **Dashboard auth loop** — set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (and a stable `_SECRET`) in the root `.env`.
- **Mongo connection refused** — `docker compose -f docker/docker-compose.yml exec gateway python3 /tools/mongo.py count money_transactions`; verify `MONGODB_URI` in root `.env`.
- **Retention not running** — `crontab -l | grep retention`; re-run `init`.
- **Health API unreachable** — `curl localhost:8001/health` from the VPS, then `curl http://<host>:8001/health` from the phone; check firewall / `docker compose logs health-api`.

## Access

Dashboard and health-api bind `0.0.0.0` inside Docker:

| Service | Reachable at |
|---------|--------------|
| dashboard | `http://<host>:9119` |
| health-api | `http://<host>:8001` (the Android app URL — set this in the health-gateway app) |

`8888` (searxng) and the bot ports need no external access
at all — the bots call searxng by its internal compose name and OpenCode Zen via HTTPS.
Secure `9119`/`8001` with a firewall/reverse proxy and strong
`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`/`_SECRET` in the root `.env` if exposed publicly.

## Security

- The root `.env` holds all live keys/tokens/Mongo creds — git-ignored, never commit. Only `.env.example` is tracked.
- Dashboard binds `0.0.0.0:9119` and requires username/password (basic auth provider); use a strong password. Restrict `9119`/`8001` with a firewall/reverse proxy if exposed publicly.
- `:9119` (dashboard) and `:8001` (health-api) are published on `0.0.0.0` inside Docker. Everything else is internal to the compose network.
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped.
- The gateway container is filesystem-scoped to the profile tree + workspace; `/tools` is read-only; per-profile tokens stay in per-profile `.env` files.
- Remote MongoDB creds are in `.env` only; `clean` never touches the cluster.
