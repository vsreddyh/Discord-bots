# opencode-remote

Run **five native Hermes bots** (1 master coordinator + 4 domain bots) against a
credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on
credit/payment errors. Private SearXNG for search, a Discord gateway per bot, a
Hermes web dashboard behind a password, and a **Health Connect → food bot**
pipeline. Domain data (money, food, helldivers) lives in **remote MongoDB** —
local SQLite is gone.

Docker is used for exactly two things: **searxng** (live) and the **test stack**
(everything else runs natively on the host via `scripts/hermes.sh`).

This repo is a **sandbox**: code and config live here; preview and validate
changes here, then apply them on your live machine yourself.

## Architecture

```
                      remote MongoDB (money, food, helldivers)
                                   ▲
master ─┐                          │
story ──┤   native Hermes gateways │         ┌─────────── searxng (:8888, docker)
helldivers ├─ HERMES_HOME=profiles/<bot>     ▼
money ──┤   each: own Discord token     zen-proxy (:4000, native uvicorn)
food ───┘                                ├─► OpenCode Zen ──► DeepInfra fallback
Health Gateway (Android) ──► health-api (:8001, native uvicorn) ──► MongoDB
Hermes dashboard ──► 0.0.0.0:9119 (password auth, master profile)
```

| Component | Runs as | Port |
|-----------|---------|------|
| searxng | docker container | 8888 |
| zen-proxy | native uvicorn (venv) | 4000 |
| health-api | native uvicorn (venv) | 8001 |
| master / story / helldivers / money / food | native `hermes gateway run` | — |
| Hermes dashboard | native, `HERMES_HOME=profiles/master` | 9119 |

## Bots

| Bot | Name (Discord) | Domain data | Retention |
|-----|----------------|-------------|-----------|
| `master` | — | none | — |
| `story` | Portas-Mantainer | none (lore vault) | — |
| `helldivers` | Rouge Automaton | static wiki DB in MongoDB | never wiped |
| `money` | Miser | `money_transactions` | autowipe when oldest entry > 90 days |
| `food` | Caped Baldy | `food_daily_stats` / `food_sleep_log` / `food_workouts` / `food_weight` | date rows pruned after 30 days; **weight never touched** |

## Prerequisites

- Bash, Python 3, `envsubst` (gettext), Docker + Compose (searxng + test stack)
- `OPENCODE_API_KEY` (from [opencode.ai](https://opencode.ai))
- Remote MongoDB URI (money/food/helldivers)
- Optional: `DEEPINFRA_API_KEY`, `DISCORD_BOT_TOKEN` per bot

## Quick Start

```bash
# 1. Set up API keys
cp .env.example .env && nano .env

# 2. Install Hermes, patch toolsets, venvs, skills, retention cron
./scripts/hermes.sh init

# 3. Per-bot secrets (5 files — each is git-ignored)
#    Edit every profiles/*/.env created from .env.example:
#    Discord token + home channel, MONGODB_URI, dashboard password.
nano profiles/master/.env
nano profiles/story/.env
nano profiles/helldivers/.env
nano profiles/money/.env
nano profiles/food/.env

# 4. Start everything (searxng → proxy → health-api → 5 bots → dashboard)
./scripts/hermes.sh start

# 5. Check status
./scripts/hermes.sh status

# 6. Stop everything
./scripts/hermes.sh stop
```

Dashboard: `http://<host>:9119` — log in with the username/password set in
`profiles/master/.env`.

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/hermes.sh init` | Install Hermes + patch `hermes-god`, venvs for proxy/health-api, ensure `profiles/*/.env`, install skills + deps, install retention cron, `hermes doctor --fix` |
| `./scripts/hermes.sh start` | searxng (docker) → zen-proxy → health-api → 5 bots → dashboard, then run retention |
| `./scripts/hermes.sh stop` | Reverse order; also stops a legacy `hermes-gateway` systemd unit if present |
| `./scripts/hermes.sh restart` | Stop then start |
| `./scripts/hermes.sh status` | Per-bot ●/○ + proxy + health-api + searxng + dashboard |
| `./scripts/hermes.sh clean` | **Destructive.** Stop all, wipe `run/`, profile runtime + rendered config + `.env`, searxng volume, Hermes install, retention cron. Remote MongoDB untouched. |

Per-bot lifecycle: `./scripts/bots.sh start|stop|restart|status`
(PIDs/logs in `run/bots/`).

## Data retention

`scripts/retention.sh` runs daily at 03:00 (cron, installed by `init`) and once
on every `start`. It only touches remote MongoDB; `--dry-run` prints what would
be deleted.

- **money** — transactions older than 90 days are wiped (autowipe every ~3 months of accumulated data).
- **food** — `daily_stats`, `sleep_log`, `workouts` rows older than 30 days are pruned. `food_weight` is **never** touched.
- **helldivers** — static wiki reference data, never wiped.
- **story** — no domain DB.

## Test stack (Docker)

Mirrors the native setup so you can test the five bots + proxy + health-api in
isolation. Includes an **in-stack MongoDB** — it never touches your remote
cluster.

```bash
docker compose -f test/docker-compose.yml build
docker compose -f test/docker-compose.yml run --rm story chown-data   # once, as the mount owner
docker compose -f test/docker-compose.yml up -d
docker compose -f test/docker-compose.yml ps
docker compose -f test/docker-compose.yml logs -f food
```

Bots read `profiles/<bot>/config.yaml.template` (rendered by `test/entrypoint.sh`
to `config.yaml` with docker defaults: `zen-proxy:4000`, `/workspace`,
`mongodb://mongodb:27017`). The shared Mongo helper is mounted at `/tools`.

## Health Connect pipeline

- **Android app** (`android/health-gateway/`): reads steps, calories, distance,
  sleep, workouts from Health Connect; POSTs to `/api/health/sync` with a Bearer
  token. First sync backfills 30 days, then hourly.
- **health-api** (native, `:8001`): persists to `food_daily_stats` /
  `food_sleep_log` / `food_workouts` in MongoDB and posts a summary to the food
  home channel on Discord.
- **Auth**: `HEALTH_SYNC_TOKEN` in the root `.env` (comma-separated for
  multiple installs).

## Remote MongoDB

Money, food, and helldivers store domain data in MongoDB (see table above).
Connection config lives in the root `.env` (`MONGODB_URI`, `MONGODB_DB`, default
`hermes`). Bots use the shared helper `tools/mongo.py` (pymongo):

```bash
python3 tools/mongo.py insert money_transactions '{"date":"2026-08-08","amount":300,"type":"expense","category":"groceries"}'
python3 tools/mongo.py aggregate money_transactions '[{"$group":{"_id":"$category","total":{"$sum":"$amount"}}}]'
```

Collections: `money_transactions` · `food_daily_stats` / `food_sleep_log` /
`food_workouts` / `food_weight` · `helldivers_*` (planets, weapons, stratagems,
…). Store dates as `YYYY-MM-DD` or full ISO strings — retention relies on
lexicographic comparison.

## How the fallback works

`docker/proxy/main.py` forwards `/v1/chat/completions` to OpenCode Zen. On a
payment/credit error (HTTP 402, or billing-keyword bodies), it rewrites the model
ID and retries on DeepInfra.

| Zen model | DeepInfra fallback |
|-----------|--------------------|
| `deepseek-v4-flash-free` | `deepseek-ai/DeepSeek-V4-Flash` |
| `mimo-v2.5-free` | `MiniMaxAI/MiniMax-M3` |

Keep `MODEL_MAP` and the static `/v1/models` list in sync when adding models.

## Skills

Hermes skill content (including autogenerated and `nousresearch/` packs) is
**committed**. Per-bot bookkeeping files (`.usage.json`, `.curator_state`) stay
git-ignored. Channel bindings live in each `config.yaml.template` →
`discord.channel_skill_bindings`.

## Layout

```
├── AGENTS.md                # sandbox rules + repo facts
├── default-config.yaml      # reference Hermes config (master-style)
├── docker/
│   ├── docker-compose.yml   # searxng only (live)
│   ├── proxy/               # credit-aware FastAPI proxy (native + test)
│   └── health-api/          # Health Connect sync endpoint (native + test)
├── test/                    # Docker test stack: 5 bots + proxy + health-api + mongodb
├── profiles/                # 5 bot homes; config.yaml.template + .env + SOUL.md + skills
├── workspace/               # per-bot terminal cwd (git-ignored)
├── run/                     # venvs, PIDs, logs (git-ignored)
├── tools/mongo.py           # shared remote-MongoDB helper
├── scripts/hermes.sh        # init/start/stop/restart/status/clean
├── scripts/bots.sh          # per-bot gateway lifecycle
├── scripts/retention.sh     # data lifecycle (cron)
└── skills/                  # project skills copied to each profile on init
```

## Troubleshooting

- **Proxy unreachable** — `curl localhost:4000/health`; check `run/zen-proxy.log`; confirm `OPENCODE_API_KEY` in `.env`.
- **Bot won't start** — `run/bots/<bot>.log`; re-run `./scripts/hermes.sh init` (re-patches hermes-god idempotently).
- **Dashboard auth loop** — set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (and a stable `_SECRET`) in `profiles/master/.env`.
- **Mongo connection refused** — `python3 tools/mongo.py count money_transactions`; verify `MONGODB_URI` in root `.env`.
- **Retention not running** — `crontab -l | grep retention`; re-run `init`.
- **Health API unreachable** — `curl localhost:8001/health`; Tailscale must be on for remote sync.
- **Legacy systemd gateway lingers** — `stop` tries `systemctl --user stop hermes-gateway` automatically.

## Security

- `.env` and `profiles/*/.env` hold live keys/tokens/Mongo creds — git-ignored, never commit. Only `.env.example` files are tracked.
- Dashboard binds `0.0.0.0:9119` and requires username/password (basic auth provider).
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped.
- Remote MongoDB creds are in `.env` only; `clean` never touches the cluster.
