# Documentation

Deep dive into every component of `opencode-remote`. For a fast start, refer to [README.md](README.md).

## Table of Contents

1. [System Architecture](#system-architecture)
2. [LLM Connection (Direct Zen)](#llm-connection-direct-zen)
3. [Stack Lifecycle (Docker)](#stack-lifecycle-docker)
4. [Bot Profiles & Multiplexing](#bot-profiles--multiplexing)
5. [Remote MongoDB & Storage Model](#remote-mongodb--storage-model)
6. [Data Retention & Lifecycle](#data-retention--lifecycle)
7. [Health Connect Pipeline](#health-connect-pipeline)
8. [Hermes Dashboard & Web UI](#hermes-dashboard--web-ui)
9. [Development Mode Isolation](#development-mode-isolation)
10. [Configuration & Environment Reference](#configuration--environment-reference)
11. [Security & Isolation](#security--isolation)
12. [Extending the Stack](#extending-the-stack)

---

## System Architecture

The stack runs **four Hermes bots** (`story`, `money`, `food`, `resumes`), a health sync API, an embedded web dashboard, and a scheduled retention job — **fully in Docker**. Everything is defined in a single Compose file ([`docker/docker-compose.yml`](file:///home/vsreddyh/Documents/Discord-bots/docker/docker-compose.yml)).

```
                               Remote MongoDB (money, food)
                                            ▲
                             Docker containers
 story ──┐               │        ┌──── SearXNG (:8888)
 money ──┤ ONE Gateway   │ HERMES_HOME=  ▼
 food ───┤ (multiplexed  │ /hermes-home │   OpenCode Zen Direct
 resumes ┘  4 profiles)  │  (gateway +  │  (https://opencode.ai/zen/v1)
         └── HERMES_DASHBOARD=1 via s6 ─┤   (model: muse-spark-1.2-free)
         each profile: own Discord token + workspace + secret scope
Health Gateway (Android) ──► health-api (:8001) ──► MongoDB
Hermes Dashboard ────────► 0.0.0.0:9119 via gateway (s6, basic auth, unified)
Retention ───────────────► one-shot container (cron 03:00 / on start)
```

- **LLM Connection**: Direct HTTPS communication with OpenCode Zen (`https://opencode.ai/zen/v1`, default model `muse-spark-1.2-free`).
- **health-api**: FastAPI sync endpoint ([`docker/health-api/main.py`](file:///home/vsreddyh/Documents/Discord-bots/docker/health-api/main.py)) on port `:8001`, writing Health Connect metrics to MongoDB.
- **gateway & dashboard**: Single multiplexed `hermes gateway run` container (`gateway.multiplex_profiles: true`) serving all four profiles. `s6-overlay` supervises both the gateway and the dashboard process on `:9119` when `HERMES_DASHBOARD=1`.
- **searxng**: Self-hosted metasearch instance (`:8888`) providing local privacy-preserving search tool capabilities.
- **retention**: One-shot retention job executing [`tools/retention.py`](file:///home/vsreddyh/Documents/Discord-bots/tools/retention.py) via cron or on stack start.
- **Development Isolation**: `HERMES_ENV=dev` directs all database operations to an ephemeral local `mongodb` container (`mongodb://mongodb:27017`), preventing dev writes from ever touching remote production data.

---

## LLM Connection (Direct Zen)

All profiles connect directly to OpenCode Zen (`https://opencode.ai/zen/v1`) using `OPENCODE_ZEN_API_KEY` defined in the root `.env`.

- **Config Rendering**: Rendered as `api_key: ${OPENCODE_ZEN_API_KEY}` in each profile's `config.yaml` from `config.yaml.template` by [`test/entrypoint.sh`](file:///home/vsreddyh/Documents/Discord-bots/test/entrypoint.sh).
- **Vision Model**: Auxiliary vision queries utilize `muse-spark-1.2-free` natively over OpenCode Zen.
- **Streaming Support**: Direct SSE passthrough when streaming is enabled in Hermes settings.

---

## Stack Lifecycle (Docker)

All container management is orchestrated through [`scripts/hermes.sh`](file:///home/vsreddyh/Documents/Discord-bots/scripts/hermes.sh), backed by [`docker/docker-compose.yml`](file:///home/vsreddyh/Documents/Discord-bots/docker/docker-compose.yml).

### `init`
1. Verifies host dependencies (docker, compose, python3, curl, cron) and installs missing requirements.
2. Builds the shared bot image ([`test/Dockerfile`](file:///home/vsreddyh/Documents/Discord-bots/test/Dockerfile), baking in `hermes-god` and `s6-overlay`) and the `health-api` image.
3. Initializes root `.env` from `.env.example` if not already present.
4. Copies skill files from `skills/` into each profile directory.
5. Installs the daily data retention cron job (runs daily at 03:00).

### `start`
1. Cleans up any stale native PIDs in `run/bots/*.pid`.
2. Starts the compose stack in detached mode: `docker compose -f docker/docker-compose.yml up -d --build`.
3. Runs an initial retention check using [`scripts/retention.sh`](file:///home/vsreddyh/Documents/Discord-bots/scripts/retention.sh).

### `stop`
Gracefully halts running containers: `docker compose -f docker/docker-compose.yml down`.

### `restart`
Executes a stop followed by a full start sequence.

### `status`
Displays container states and published ports via `docker compose -f docker/docker-compose.yml ps`.

### `clean` (Destructive)
Stops containers, wipes docker volumes (`down -v`), removes `run/`, clears rendered configs and per-profile `.env` files, and removes the retention crontab entry. **Never touches remote MongoDB.**

---

## Bot Profiles & Multiplexing

[`profiles/master/`](file:///home/vsreddyh/Documents/Discord-bots/profiles/master) acts as the gateway root (`HERMES_HOME=/hermes-home`). The individual bot profiles are organized under `profiles/master/profiles/<bot>/`:

| Profile | Discord Identity | Home Channel Env Var | Workspace & Domain Data |
|---|---|---|---|
| `story` | Portas-Maintainer | `DISCORD_HOME_CHANNEL_STORY` | Lore vault in Git repo (`workspace/portals`, `vsreddyh/portals`) |
| `money` | Miser | `DISCORD_HOME_CHANNEL_MONEY` | MongoDB collection `money_transactions` |
| `food` | Saitama | `DISCORD_HOME_CHANNEL_FOOD` | MongoDB collections `food_daily_stats`, `food_sleep_log`, `food_workouts`, `food_weight` |
| `resumes` | Job Bot | `DISCORD_HOME_CHANNEL_RESUMES` | LaTeX CV workspace in Git repo (`workspace/resumes`, `vsreddyh/Resume`) |

### Environment & Token Injection
- All tokens and channel IDs reside in the root `.env`.
- During container startup, [`test/entrypoint.sh`](file:///home/vsreddyh/Documents/Discord-bots/test/entrypoint.sh) generates per-profile `.env` files containing only the scoped `DISCORD_BOT_TOKEN` and `DISCORD_HOME_CHANNEL`.
- This ensures discrete credential scoping without mixing secrets across bot instances.

---

## Remote MongoDB & Storage Model

Domain data for `money` and `food` bots is managed in MongoDB (default database: `hermes`, configurable via `MONGODB_DB`):

| Collection | Associated Bot | Schema / Keys |
|---|---|---|
| `money_transactions` | Money | `date` (YYYY-MM-DD), `amount` (float), `type` (income\|expense), `category` (normalized string), `note` (string) |
| `food_daily_stats` | Food / Health Sync | `date` (YYYY-MM-DD, primary lookup key), `steps` (int), `active_calories` (float), `synced_at` (ISO timestamp) |
| `food_sleep_log` | Food / Health Sync | `date` (YYYY-MM-DD), `sleep_start` (ISO timestamp, deduplication key), `wake_time` (ISO timestamp), `hours` (float), `synced_at` (ISO timestamp) |
| `food_workouts` | Food / Health Sync | `date` (YYYY-MM-DD), `type` (string), `duration` (minutes, deduped on date+type+duration), `notes` (string), `synced_at` (ISO timestamp) |
| `food_weight` | Food | `date` (YYYY-MM-DD), `weight_kg` (float) — **exempt from retention pruning** |

### Database Helper CLI
Bots and scripts interact with MongoDB using [`tools/mongo.py`](file:///home/vsreddyh/Documents/Discord-bots/tools/mongo.py):

```bash
python3 tools/mongo.py count money_transactions '{"type":"expense"}'
python3 tools/mongo.py insert food_weight '{"date":"2026-08-08","weight_kg":63.2}'
python3 tools/mongo.py upsert food_daily_stats '{"date":"2026-08-08"}' '{"steps":8452}'
```

---

## Data Retention & Lifecycle

Automated data pruning is executed by [`tools/retention.py`](file:///home/vsreddyh/Documents/Discord-bots/tools/retention.py):

| Target | Retention Window | Action |
|---|---|---|
| `money_transactions` | > 90 days | Autowiped when `date < today - 90d` |
| `food_daily_stats` | > 30 days | Pruned when `date < today - 30d` |
| `food_sleep_log` | > 30 days | Pruned when `date < today - 30d` |
| `food_workouts` | > 30 days | Pruned when `date < today - 30d` |
| `food_weight` | Permanent | **Never pruned** |
| `story` / `resumes` | Git history | No database retention operations |

Run manual dry-runs via:
```bash
./scripts/retention.sh --dry-run
```

---

## Health Connect Pipeline

```
Android Health Gateway App ──POST /api/health/sync──► health-api (:8001)
                                                        │
                                                        ▼
                                       MongoDB: food_daily_stats / food_sleep_log / food_workouts
                                                        │
                                                        ▼
                                       Discord summary to food home channel
```

1. **Android Gateway** (`android/health-gateway/`): Built with Jetpack Compose & Health Connect SDK 1.1.0. Backfills 30 days on initial setup and runs hourly background syncs.
2. **`health-api` Endpoint** (`:8001`): Authenticates requests via `Authorization: Bearer <HEALTH_SYNC_TOKEN>`, upserts metrics into MongoDB, and posts an activity update to Discord.

---

## Hermes Dashboard & Web UI

- **Supervision**: Supervised via `s6-overlay` in the `gateway` container when `HERMES_DASHBOARD=1`.
- **Binding**: Exposed on `0.0.0.0:9119`.
- **Authentication**: Uses basic HTTP authentication configured via `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`, and `HERMES_DASHBOARD_BASIC_AUTH_SECRET` in `.env`.
- **Unified Overview**: Displays runtime state, active sessions, and configuration for all four multiplexed bot profiles.

---

## Development Mode Isolation

Setting `HERMES_ENV=dev` enables isolated development without impacting production databases:
- Activates the `dev` Compose profile, launching an ephemeral `mongo:7` container (`mongodb://mongodb:27017`, no volume).
- Gateway, `health-api`, and retention automatically target the local MongoDB instance.
- Tearing down the container clears dev data completely.

---

## Configuration & Environment Reference

All settings are configured in the single root `.env` file:

| Variable | Required | Description |
|---|---|---|
| `OPENCODE_ZEN_API_KEY` | **Yes** | API key for OpenCode Zen direct connection |
| `DISCORD_BOT_TOKEN_<BOT>` | **Yes** | Individual Discord bot token (`STORY`, `MONEY`, `FOOD`, `RESUMES`) |
| `DISCORD_HOME_CHANNEL_<BOT>` | **Yes** | Home channel ID for each bot |
| `MONGODB_URI` | **Yes** | Remote MongoDB connection string (used in prod) |
| `MONGODB_DB` | No | Target MongoDB database name (default: `hermes`) |
| `HERMES_ENV` | No | Set to `dev` for local ephemeral MongoDB container |
| `HEALTH_SYNC_TOKEN` | For Health | Bearer token for Android Health Gateway authentication |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | For Dashboard | Dashboard login username (default: `admin`) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | For Dashboard | Dashboard login password |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | For Dashboard | Stable token signing key (32+ bytes recommended) |
| `USDA_API_KEY` | For Food | USDA FoodData Central API key |
| `SEARXNG_SECRET_KEY` | No | Secret key for SearXNG instance |

---

## Security & Isolation

- **Secrets Management**: Live API keys and database credentials reside exclusively in the git-ignored `.env` file.
- **Container Isolation**: `gateway` container mounts only required directories (`profiles/master`, `workspace`, `/tools` read-only) with no host Docker socket access.
- **Search Hardening**: The SearXNG container runs with all Linux capabilities dropped (`cap_drop: ALL`).
- **Dashboard Protection**: Basic auth protection on port `9119` with secret session token hashing.

---

## Extending the Stack

### Adding a New Bot Profile
1. Create a plan in `profile-plans/<bot>-plan.md`.
2. Create profile directory `profiles/master/profiles/<bot>/` with `config.yaml.template`, `SOUL.md`, and skills.
3. Add the bot identifier to the `BOTS` array in `scripts/hermes.sh`.
4. Define `DISCORD_BOT_TOKEN_<BOT>` and `DISCORD_HOME_CHANNEL_<BOT>` in `.env` and `docker/docker-compose.yml`.
5. Rebuild and restart the gateway container:
   ```bash
   ./scripts/hermes.sh restart
   ```

### Adding a Skill
Place the skill directory containing `SKILL.md` inside `skills/` and execute `./scripts/hermes.sh init` to distribute the skill to all bot profiles.
