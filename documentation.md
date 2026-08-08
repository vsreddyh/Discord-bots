# Documentation

Deep dive into every part of `opencode-remote`. For the 2-minute overview, see [README.md](README.md).

## Table of Contents

1. [System overview](#system-overview)
2. [The Zen proxy](#the-zen-proxy)
3. [Native stack lifecycle](#native-stack-lifecycle)
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

The repo runs **five Hermes bots natively on the host**, plus a native LLM proxy
and a native health sync endpoint. Docker is limited to **searxng** (live) and
the **test stack**.

```
                    remote MongoDB
                        ▲  money_transactions, food_*, helldivers_*
                        │
master ─┐               │  zen-proxy (:4000, native uvicorn)
story ──┤   native      │   └─► OpenCode Zen ──► DeepInfra (credit fallback)
helldivers ├─ gateways  │
money ──┤  (HERMES_HOME=profiles/<bot>)   searxng (:8888, docker) ◄─ web search
food ───┘               │
Health Gateway (Android)──► health-api (:8001, native uvicorn) ──► MongoDB
Hermes dashboard (0.0.0.0:9119, password) ◄─ master profile
```

- **zen-proxy** — OpenAI-compatible LLM proxy (`docker/proxy/main.py`), run natively as `uvicorn` from `run/venv-zen`.
- **health-api** — Health Connect sync endpoint (`docker/health-api/main.py`), run natively as `uvicorn` from `run/venv-health`, writing to MongoDB.
- **bots** — five native `hermes gateway run` processes, one `HERMES_HOME` each under `profiles/`.
- **searxng** — the only live docker service; private web search for `web.search_backend: searxng`.
- **test stack** — the whole five-bot setup plus proxy, health-api, and an in-stack MongoDB, all in Docker.

---

## The Zen proxy

Source: `docker/proxy/main.py` — a ~180-line FastAPI app. Runs natively via
`scripts/hermes.sh start` (`run/venv-zen/bin/uvicorn main:app --port 4000`) and
in the test stack as a container. Same code either way.

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

## Native stack lifecycle

Source: `scripts/hermes.sh` (orchestration) + `scripts/bots.sh` (gateways) +
`scripts/retention.sh` (data lifecycle). Runtime artifacts live in `run/`
(git-ignored): venvs, PID files, and logs.

### `init`

1. Install Hermes via `https://hermes-agent.nousresearch.com/install.sh` if missing.
2. Patch the **`hermes-god`** toolset into the installed `toolsets.py` +
   `hermes_cli/platforms.py` (idempotent, grep-guarded).
3. Create `run/` + per-bot `workspace/<bot>`, and ensure `profiles/*/.env`
   (copied from `.env.example` when missing — edit them!).
4. Copy `skills/*` into each profile (existing skills are skipped).
5. Install deps: `edge-tts`, `PyNaCl` + `davey`, `pymongo` (pip), `libopus0` +
   `ffmpeg` (apt), `agent-browser` (npm global + Chromium).
6. Create venvs: `run/venv-zen` (fastapi/uvicorn/httpx) and `run/venv-health`
   (`docker/health-api/requirements.txt`).
7. Install the **retention cron** (daily 03:00).
8. Run `hermes doctor --fix` + `hermes tools --summary`; pre-build the dashboard
   UI if `web/dist` is missing.

Re-run `init` after changing config templates or skills — it skips existing
config/skills, re-patches toolsets, and re-installs the cron.

### `start` (order)

1. searxng: `docker compose -f docker/docker-compose.yml up -d`
2. zen-proxy: native uvicorn on :4000; waits for `/health`
3. health-api: native uvicorn on :8001 (env from root + food `.env`)
4. bots: `scripts/bots.sh start` — for each bot, render
   `config.yaml.template` → `config.yaml` (`HERMES_BASE_URL=http://localhost:4000/v1`,
   `HERMES_CWD=$REPO/workspace/<bot>`), then `HERMES_HOME=profiles/<bot> nohup hermes
   gateway run --force --accept-hooks`, PID in `run/bots/<bot>.pid`
5. retention: `scripts/retention.sh` runs once
6. dashboard: `HERMES_HOME=profiles/master hermes dashboard --host 0.0.0.0 --port 9119`
   (password from master `.env`)

### `stop` (reverse)

Dashboard → bots → health-api → zen-proxy → searxng. Also best-effort stops a
legacy `hermes-gateway` systemd user unit if it lingers from a previous setup.

### `status`

Shows searxng, zen-proxy, health-api, all five bots (●/○ with PIDs), and the
dashboard; then the log paths.

### `clean` (destructive)

Stops everything, removes the retention cron, deletes `run/`, wipes each
profile's runtime state + rendered `config.yaml` + `.env`, does
`docker compose down -v` for searxng, and uninstalls Hermes
(`hermes uninstall --full --yes` + `rm -rf ~/.hermes`). Asks for confirmation.
**Never touches remote MongoDB or committed files.**

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

Each `config.yaml.template` is an `envsubst` template with `${HERMES_BASE_URL}`,
`${HERMES_CWD}` (and `${DISCORD_HOME_CHANNEL}` on master). The launcher renders
it to the git-ignored `config.yaml` Hermes actually reads:

- native (`scripts/bots.sh`): `http://localhost:4000/v1`, `$REPO/workspace/<bot>`
- test stack (`test/entrypoint.sh`): `http://zen-proxy:4000/v1`, `/workspace`

All templates set `onboarding.profile_build: off` so the gateway never rewrites
the tracked source of truth.

### Per-profile `.env`

Secrets per bot (Discord token, home channel, optional overrides). Git-ignored;
`.env.example` files are committed templates. The root `.env` is also sourced by
the launcher, so shared secrets (Mongo URI) live in one place.

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

`scripts/retention.sh run` (or `--dry-run`):

| Bot | Policy | Implementation |
|-----|--------|----------------|
| `story` | none | no-op |
| `helldivers` | static reference | no-op |
| `money` | autowipe every ~3 months | `delete_many` on `money_transactions` where `date < today-90d` |
| `food` | prune date data monthly | `delete_many` on `food_daily_stats` / `food_sleep_log` / `food_workouts` where `date < today-30d`; `food_weight` untouched |

Scheduling: daily 03:00 crontab entry installed by `init`
(`scripts/hermes.sh` `install_retention_cron`), plus a run on every `start`.
`clean` removes the cron entry. The script reads `MONGODB_URI`/`MONGODB_DB` from
the root `.env` and prints counts of what it removed.

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

One dashboard, bound to `0.0.0.0:9119`, launched with
`HERMES_HOME=profiles/master` — so it manages the master profile's config, API
keys, and sessions.

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
| `zen-proxy` | LLM proxy (same code as native) |
| `mongodb` | in-stack Mongo; bots/health-api point here, never the remote cluster |
| `master` / `story` / `helldivers` / `money` / `food` | one Hermes Discord bot each |
| `health-api` | Health Connect sync endpoint (writes in-stack Mongo) |

### Bots

- Built from `test/Dockerfile`: `python:3.11-slim` + `hermes-agent` +
  `discord.py[voice]==2.7.1` + `pymongo`; the Dockerfile runs the same
  `hermes-god` toolset patch as `init`.
- `user: "1000:1000"`, `HOME=/hermes-home`; mounts `profiles/<bot>:/hermes-home`,
  `workspace/<bot>:/workspace`, `../tools:/tools`. Nothing else.
- `depends_on: zen-proxy (service_healthy)`.

### `entrypoint.sh`

1. Sources `$HERMES_HOME/.env`.
2. `chown-data` mode (run once via `docker compose run --rm <bot> chown-data`).
3. Renders `config.yaml.template` → `config.yaml` with docker defaults
   (`HERMES_BASE_URL=http://zen-proxy:4000/v1`, `HERMES_CWD=/workspace`,
   `MONGODB_URI=mongodb://mongodb:27017`).
4. `exec hermes gateway run --force --accept-hooks`.

### Starting it

```bash
docker compose -f test/docker-compose.yml build
docker compose -f test/docker-compose.yml run --rm story chown-data   # once
docker compose -f test/docker-compose.yml up -d
```

---

## Configuration reference

### Template placeholders

| Placeholder | Native | Test stack |
|-------------|--------|------------|
| `${HERMES_BASE_URL}` | `http://localhost:4000/v1` | `http://zen-proxy:4000/v1` |
| `${HERMES_CWD}` | `$REPO/workspace/<bot>` | `/workspace` |
| `${DISCORD_HOME_CHANNEL}` | from `profiles/<bot>/.env` | from `profiles/<bot>/.env` |
| `MONGODB_URI` (env) | remote cluster | `mongodb://mongodb:27017` |

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
| `terminal.backend` | `local` | terminal on the host |
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
- Test stack: bots only see their own profile + workspace + tools mounts, no
  root `.env`, no Docker socket; the in-stack Mongo keeps test data off the
  remote cluster.

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
3. Add the bot to the `BOTS` array in `scripts/hermes.sh` and `scripts/bots.sh`.
4. Add a matching service to `test/docker-compose.yml`.

### Add a skill

Drop a directory with `SKILL.md` (with `name` + `description` frontmatter) into
`skills/`, then re-run `./scripts/hermes.sh init` to copy it into every profile.
Skill content is committed; per-bot usage/curator bookkeeping stays ignored.
