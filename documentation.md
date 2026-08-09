# Documentation

Deep dive into every part of `opencode-remote`. For the 2-minute overview, see [README.md](README.md).

## Table of Contents

1. [System overview](#system-overview)
2. [The Zen proxy](#the-zen-proxy)
3. [Stack lifecycle (Docker)](#stack-lifecycle-docker)
4. [Bot profiles](#bot-profiles)
5. [Remote MongoDB](#remote-mongodb)
6. [Data retention](#data-retention)
7. [Health Connect pipeline](#health-connect-pipeline)
8. [Hermes dashboard](#hermes-dashboard)
9. [Test stack (Docker)](#test-stack-docker)
10. [Configuration reference](#configuration-reference)
11. [Security](#security)
12. [Extending the stack](#extending-the-stack)

---

## System overview

The repo runs **five Hermes bots**, an LLM proxy, a health sync endpoint, a
dashboard, and a retention job — **all in Docker**. The live stack is one
compose file (`docker/docker-compose.yml`); the `test/` stack is an isolated
mirror with an in-stack MongoDB. There is no host Hermes install.

```
                    remote MongoDB
                        ▲  money_transactions, food_*, helldivers_*
                        │
master ─┐               │  zen-proxy (:4000)
story ──┤   docker      │   └─► OpenCode Zen ──► DeepInfra (credit fallback)
helldivers ├─ containers │
money ──┤  (HERMES_HOME=/hermes-home)   searxng (:8888) ◄─ web search
food ───┘               │
Health Gateway (Android)──► health-api (:8001) ──► MongoDB
Hermes dashboard (0.0.0.0:9119, password) ◄─ master profile
retention ──► one-shot container (cron 03:00)
```

- **zen-proxy** — OpenAI-compatible LLM proxy (`docker/proxy/main.py`), a container on `:4000`.
- **health-api** — Health Connect sync endpoint (`docker/health-api/main.py`), a container on `:8001`, writing to MongoDB.
- **bots** — five `hermes gateway run` containers, one `HERMES_HOME` each, bind-mounted from `profiles/`.
- **dashboard** — a container running `hermes dashboard` against the master profile (`HERMES_MODE=dashboard`).
- **searxng** — private web search for `web.search_backend: searxng`.
- **retention** — one-shot service (`tools/retention.py`) run by cron.
- **test stack** — the whole five-bot setup plus proxy, health-api, and an in-stack MongoDB, all in Docker.

---

## The Zen proxy

Source: `docker/proxy/main.py` — a ~180-line FastAPI app. Runs as a container on
`:4000` in both the live stack and the test stack. Same code either way.

### Backends

| Backend | Base URL | Auth |
|---------|----------|------|
| OpenCode Zen (primary) | `https://opencode.ai/zen/v1` | `Bearer $OPENCODE_API_KEY` |
| DeepInfra (fallback) | `https://api.deepinfra.com/v1/openai` | `Bearer $DEEPINFRA_API_KEY` |

### Endpoints

| Endpoint | Behavior |
|----------|----------|
| `GET /health` | `{"status": "ok"}` |
| `GET /v1/models` | Static list of 2 Zen + 2 DeepInfra models |
| `POST /v1/chat/completions` | The routing logic; streaming and non-streaming |
| `/v1/embeddings`, `/v1/audio/*` | **Not implemented** |

### Fallback logic

1. Parse body; extract `model` and `stream`.
2. Forward unchanged to Zen.
3. Status `< 400` or non-payment error → return Zen's response as-is.
4. Payment error → look up DeepInfra mapping for `model`.
5. No mapping or no `DEEPINFRA_API_KEY` → return the Zen error.
6. Otherwise rewrite `body["model"]` and retry on DeepInfra.

`_is_payment_error()`: HTTP **402** always; 400/403/404/429 only if the body
matches ~20 billing keywords (`credits`, `quota exceeded`, `daily limit`, …).

### Model mapping

| Zen model ID | DeepInfra model ID |
|--------------|--------------------|
| `deepseek-v4-flash-free` | `deepseek-ai/DeepSeek-V4-Flash` |
| `mimo-v2.5-free` | `MiniMaxAI/MiniMax-M3` |

### Streaming

`stream: true` → raw SSE passthrough via `StreamingResponse`
(`text/event-stream`, `cache-control: no-cache`, `x-accel-buffering: no`).
`stream: false` → JSON passthrough. Single shared `httpx.AsyncClient`.

---

## Stack lifecycle (Docker)

Source: `scripts/hermes.sh` (orchestration) + `scripts/retention.sh` (data
lifecycle). `scripts/hermes.sh` is a thin wrapper around
`docker compose -f docker/docker-compose.yml`. Runtime artifacts live in `run/`
(git-ignored): currently only the retention cron log.

### `init`

1. `docker compose build` — builds the shared bot image (`test/Dockerfile`,
   which bakes in the `hermes-god` toolset patch) plus `zen-proxy` and
   `health-api`.
2. **Tailscale**: install if missing, `tailscale up` (prints the login URL,
   waits up to 60s for the browser login), prints the tailnet IP + dashboard/
   health-api URLs. If ufw is already active, adds idempotent allow-rules on
   `tailscale0` (+ SSH). Never auto-enables default-deny (lockout risk).
   Skip with `HERMES_NO_TAILSCALE=1`.
3. Create `run/` + per-bot `workspace/<bot>`, and ensure `profiles/*/.env`
   (copied from `.env.example` when missing — edit them!).
4. Copy `skills/*` into each profile (existing skills are skipped).
5. Install the **retention cron** (daily 03:00).

Re-run `init` after changing config templates or skills — it skips existing
config/skills and re-installs the cron.

### `start` (order)

1. `docker compose -f docker/docker-compose.yml up -d --build` — starts
   searxng, zen-proxy, health-api, all five bots, and the dashboard. Bots wait
   on `zen-proxy` via `depends_on: service_healthy`.
2. First, `start` best-effort kills any **stale native bot PIDs** left in
   `run/bots/*.pid` by the pre-Docker launcher (they would fight over the same
   Discord tokens).
3. retention: `scripts/retention.sh run` runs the one-shot `retention` service.

Each bot container starts via `test/entrypoint.sh`, which renders
`config.yaml.template` → `config.yaml` (`HERMES_BASE_URL=http://zen-proxy:4000/v1`,
`HERMES_CWD=/workspace`) and runs `hermes gateway run --force --accept-hooks`.

### `stop` (reverse)

`docker compose down` (keeps volumes). Also best-effort stops a legacy
`hermes-gateway` systemd user unit if it lingers from a previous setup.

### `status`

`docker compose ps` — every service with its state and published ports.

### `clean` (destructive)

`docker compose down -v` (removes containers + the searxng volume), removes the
retention cron, deletes `run/`, and wipes each profile's runtime state +
rendered `config.yaml` + `.env`. Asks for confirmation. **Never touches remote
MongoDB, committed files, or a host `~/.hermes` (there is none to manage).**

---

## Bot profiles

`profiles/` holds a home directory per bot: the committed `config.yaml.template`,
`SOUL.md`, skills, and the git-ignored rendered `config.yaml` + `.env` + runtime
state (sessions, memories, kanban, cron, …).

| Profile | Discord bot | Home channel | Purpose | Domain data |
|---------|-------------|--------------|---------|-------------|
| `master` | *(your coordinator)* | from `.env` | General coordinator, routes to domain bots | none |
| `story` | Portas-Mantainer | `1523762320986214541` | Story/worldbuilding from a lore vault | none |
| `helldivers` | Rouge Automaton | `1535601629884317696` | Helldivers 2 companion (static wiki DB) | `helldivers_*` |
| `money` | Miser | `1535611174039719976` | Money management | `money_transactions` |
| `food` | Caped Baldy (Saitama) | `1535613331610669117` | Food + workouts, Health Connect sync | `food_*` |

Design plans: `profile-plans/*.md`.

### Config templates

Each `config.yaml.template` is a template with `${HERMES_BASE_URL}`,
`${HERMES_CWD}` (and `${DISCORD_HOME_CHANNEL}` on master). The container
entrypoint (`test/entrypoint.sh`) renders it to the git-ignored `config.yaml`
Hermes actually reads, with docker defaults:

- live + test stacks: `http://zen-proxy:4000/v1`, `/workspace`

All templates set `onboarding.profile_build: off` so the gateway never rewrites
the tracked source of truth.

### Per-profile `.env`

Secrets per bot (Discord token, home channel, optional overrides). Git-ignored;
`.env.example` files are committed templates. The entrypoint sources
`$HERMES_HOME/.env` at container start; the root `.env` is injected via
`env_file` on each compose service, so shared secrets (Mongo URI, proxy keys)
live in one place.

---

## Remote MongoDB

Money, food, and helldivers keep their domain data in remote MongoDB. Local
SQLite was removed; there is no data migration.

- **Connection**: `MONGODB_URI` + `MONGODB_DB` (default `hermes`) in the root `.env`.
- **Driver**: `pymongo`, installed by `init` and included in the test image.
- **Helper**: `tools/mongo.py` — a shared CLI bots can call from their terminal:

| Command | Example |
|---------|---------|
| `get` / `count` | `mongo.py count money_transactions '{"type":"expense"}'` |
| `insert` / `insert-many` | `mongo.py insert food_weight '{"date":"2026-08-08","weight_kg":63.2}'` |
| `upsert` | `mongo.py upsert food_daily_stats '{"date":"2026-08-08"}' '{"steps":8452}'` |
| `delete` | `mongo.py delete food_workouts '{"date":{"$lt":"2026-07-01"}}'` |
| `drop` | `mongo.py drop helldivers_planets` |
| `aggregate` | `mongo.py aggregate money_transactions '[{"$group":{"_id":"$category","total":{"$sum":"$amount"}}}]'` |

### Collections

| Collection | Bot | Notes |
|-----------|-----|-------|
| `money_transactions` | money | `date`, `amount`, `type`, `category`, `note` |
| `food_daily_stats` | food | one doc per `date`: `steps`, `active_calories` |
| `food_sleep_log` | food | deduped on `sleep_start` |
| `food_workouts` | food | deduped on date+type+duration |
| `food_weight` | food | **never pruned by retention** |
| `helldivers_*` | helldivers | static wiki reference data |

Date convention: store `date` as `YYYY-MM-DD` or a full ISO-8601 string. Both
compare lexicographically, which `retention.sh` relies on.

---

## Data retention

`scripts/retention.sh run` (or `--dry-run`) runs
`docker compose run --rm retention`, which executes `tools/retention.py` inside
the bot image (pymongo included, `tools/` mounted read-only):

| Bot | Policy | Implementation |
|-----|--------|----------------|
| `story` | none | no-op |
| `helldivers` | static reference | no-op |
| `money` | autowipe every ~3 months | `delete_many` on `money_transactions` where `date < today-90d` |
| `food` | prune date data monthly | `delete_many` on `food_daily_stats` / `food_sleep_log` / `food_workouts` where `date < today-30d`; `food_weight` untouched |

Scheduling: daily 03:00 crontab entry installed by `init`
(`scripts/hermes.sh` `install_retention_cron`), plus a run on every `start`.
`clean` removes the cron entry. The container reads `MONGODB_URI`/`MONGODB_DB`
from the root `.env` (via `env_file`) and prints counts of what it removed.

---

## Health Connect pipeline

Food bot ingests watch data (Redmi Watch 5 Lite) via Android Health Connect.

```
Android Health Gateway app ──POST /api/health/sync──► health-api (:8001)
                                                        │
                                                        ▼
                                       MongoDB: food_daily_stats / food_sleep_log / food_workouts
                                                        │
                                                        ▼
                                       Discord summary to food home channel (best-effort)
```

### health-api

- **Auth**: `Authorization: Bearer <token>`, token from `HEALTH_API_TOKENS`
  (comma-separated) falling back to `HEALTH_SYNC_TOKEN` in the root `.env`.
- **Storage**: pymongo upserts/dedupes (see collections above).
- **Idempotent**: repeated identical payloads never duplicate rows.
- **Discord**: after each successful sync, best-effort summary post using
  `DISCORD_BOT_TOKEN`/`DISCORD_HOME_CHANNEL` from `profiles/food/.env`.

### Android app

Source: `android/health-gateway/` — Kotlin + Jetpack Compose, Health Connect
SDK 1.1.0, compileSdk 36 / minSdk 28 / targetSdk 35. Reads steps, active/total
calories, distance, sleep (with stages), workouts. First sync backfills 30 days,
then hourly via WorkManager (rescheduled on boot). Auth token matches
`HEALTH_SYNC_TOKEN`.

### Endpoint contract

`POST /api/health/sync`:

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

## Hermes dashboard

One dashboard container, bound to `0.0.0.0:9119`, running
`hermes dashboard` with `HERMES_MODE=dashboard` (`test/entrypoint.sh`) and
`HERMES_HOME=/hermes-home` (bind-mounted `profiles/master`) — so it manages the
master profile's config, API keys, and sessions. It uses the prebuilt
`hermes_cli/web_dist` shipped in the package (`--skip-build`), so no Node/npm is
needed.

A public bind **requires an auth provider**. This repo uses the built-in basic
(username/password) provider, configured via env in `profiles/master/.env`:

| Env var | Purpose |
|---------|---------|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | login username (default `admin`) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | login password |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | token-signing key (32+ bytes) — set it or every restart logs you out |

Env wins over config.yaml. Override the bind with `HERMES_DASHBOARD_HOST`
(default `0.0.0.0`) and the port with `HERMES_DASHBOARD_PORT` (default `9119`).

---

## Test stack (Docker)

`test/docker-compose.yml` + `test/Dockerfile` + `test/entrypoint.sh`. Runs the
same five profiles against the same proxy, fully isolated, with an in-stack
MongoDB (`mongo:7`).

| Service | Role |
|---------|------|
| `zen-proxy` | LLM proxy (same code as live) |
| `mongodb` | in-stack Mongo; bots/health-api point here, never the remote cluster |
| `master` / `story` / `helldivers` / `money` / `food` | one Hermes Discord bot each |
| `health-api` | Health Connect sync endpoint (writes in-stack Mongo) |

### Bots

- Built from `test/Dockerfile`: `python:3.11-alpine` + `hermes-agent` +
  `discord.py[voice]==2.7.1` + `pymongo` (Alpine keeps images ~40% smaller
  than the old `slim` base); the Dockerfile bakes in the same
  `hermes-god` toolset patch. This is also the live stack's bot image.
- `user: "1000:1000"`, `HOME=/hermes-home`; mounts `profiles/<bot>:/hermes-home`,
  `workspace/<bot>:/workspace`, `../tools:/tools` (**read-only**). Nothing else.
- `depends_on: zen-proxy (service_healthy)`.

### `entrypoint.sh`

1. Sources `$HERMES_HOME/.env`.
2. `chown-data` mode (run once via `docker compose run --rm <bot> chown-data`).
3. Renders `config.yaml.template` → `config.yaml` with docker defaults
   (`HERMES_BASE_URL=http://zen-proxy:4000/v1`, `HERMES_CWD=/workspace`,
   `MONGODB_URI=mongodb://mongodb:27017` unless overridden).
4. `HERMES_MODE=dashboard` → `hermes dashboard --no-open --skip-build`;
   otherwise `exec hermes gateway run --force --accept-hooks`.

The live stack adds the same image as a `dashboard` service
(`HERMES_MODE=dashboard`, port 9119) and a `retention` service
(`entrypoint: ["python3", "/tools/retention.py"]`).

### Starting it

```bash
docker compose -f test/docker-compose.yml build
docker compose -f test/docker-compose.yml run --rm story chown-data   # once
docker compose -f test/docker-compose.yml up -d
```

---

## Configuration reference

### Template placeholders

| Placeholder | Live + test stack |
|-------------|-------------------|
| `${HERMES_BASE_URL}` | `http://zen-proxy:4000/v1` |
| `${HERMES_CWD}` | `/workspace` |
| `${DISCORD_HOME_CHANNEL}` | from `profiles/<bot>/.env` |
| `MONGODB_URI` (env) | live: remote cluster (root `.env`); test: `mongodb://mongodb:27017` |

### Root `.env` variables

| Var | Required | Purpose |
|-----|----------|---------|
| `OPENCODE_API_KEY` | **yes** | Zen backend auth |
| `DEEPINFRA_API_KEY` | no | DeepInfra fallback auth |
| `MONGODB_URI` | for money/food/helldivers | remote Mongo connection |
| `MONGODB_DB` | no | default `hermes` |
| `HEALTH_SYNC_TOKEN` | for health-api | Bearer token(s) for the Android app |
| `SEARXNG_URL` / `SEARXNG_SECRET_KEY` / `SEARXNG_PORT` / `SEARXNG_HOSTNAME` | no | searxng settings |

### Notable fixed settings

| Section | Value | Why |
|---------|-------|-----|
| `auxiliary.vision.model` | `mimo-v2.5-free` | vision via the same proxy |
| `web.search_backend` | `searxng` | private search |
| `terminal.backend` | `local` | terminal inside the bot container (`cwd=/workspace`) |
| `approvals.mode` | `smart` | approval prompts |
| `onboarding.profile_build` | `off` | stop gateway rewriting tracked config |
| `platform_toolsets` | cli → `file`, `terminal`; discord → `hermes-god` | per-platform tools |
| `_config_version` | `33` | Hermes config schema version |

---

## Security

- `.env` + `profiles/*/.env` hold live API keys, bot tokens, and Mongo creds.
  Git-ignored; only `.env.example` files are tracked. Never commit either.
- `security.redact_secrets: true` in Hermes config.
- searxng container drops all capabilities.
- Dashboard binds `0.0.0.0:9119` behind username/password (basic auth).
- `clean` never touches remote MongoDB.
- Every container (bots + dashboard) only sees its own profile + workspace +
  the **read-only** `/tools` mount — no sibling profiles, no root `.env`, no
  Docker socket, no host paths. Bots still have normal outbound network
  (Discord, remote Mongo, zen-proxy). `health-api` is the only service with the
  root `.env` + `profiles/food/.env` (it needs the Mongo URI and the food
  channel token).
- Test stack: the in-stack Mongo keeps test data off the remote cluster.

---

## Extending the stack

### Add a model to the proxy

1. Add the mapping to `MODEL_MAP` in `docker/proxy/main.py`.
2. Add it to the static `/v1/models` list.
3. Restart the proxy: `./scripts/hermes.sh restart` (or rebuild `zen-proxy` in the test stack).
4. Point a bot at it via `HERMES_MODEL` in the profile config template.

### Add a bot profile

1. Write the design plan under `profile-plans/`.
2. Create `profiles/<name>/` — copy `config.yaml.template`, `SOUL.md`, and
   `.env.example` from an existing profile; set the Discord token + home channel.
3. Add the bot to the `BOTS` array in `scripts/hermes.sh`.
4. Add a matching service to `docker/docker-compose.yml` (live) and
   `test/docker-compose.yml` (test mirror).

### Add a skill

Drop a directory with `SKILL.md` (with `name` + `description` frontmatter) into
`skills/`, then re-run `./scripts/hermes.sh init` to copy it into every profile.
Skill content, the skill-curator's `.curator_state`/`.usage.json`, `memories/`,
and each `SOUL.md` are committed so the bots' learned state survives moving
between VPSes.
