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
9. [Development mode](#development-mode)
10. [Configuration reference](#configuration-reference)
11. [Security](#security)
12. [Extending the stack](#extending-the-stack)

---

## System overview

The repo runs **six Hermes bots**, an LLM proxy, a health sync endpoint, a
dashboard, and a retention job — **all in Docker**. The whole stack is one
compose file (`docker/docker-compose.yml`); dev and prod run the same file.
Dev isolation is `HERMES_ENV=dev` in the root `.env`, which prefixes the DB
name (`test_hermes`) so dev writes never touch the prod DB. There is no host
Hermes install.

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
- **bots** — one multiplexed `hermes gateway run` container serving all five profiles (`gateway.multiplex_profiles: true`). `master` is the default profile home; story/helldivers/money/food are named profiles nested under `profiles/master/profiles/`, each with its own Discord token, workspace, and per-profile secret scope.
- **dashboard** — a container running `hermes dashboard` against the default profile (`HERMES_MODE=dashboard`); unified mode lists every named profile under `HERMES_HOME/profiles/`.
- **searxng** — private web search for `web.search_backend: searxng`.
- **retention** — one-shot service (`tools/retention.py`) run by cron.
- **dev mode** — `HERMES_ENV=dev` in the root `.env` runs the same single
  compose file with `MONGODB_DB` prefixed (`test_hermes`) for bots, health-api,
  and retention. prod/unset = the DB as-is.

---

## The Zen proxy

Source: `docker/proxy/main.py` — a ~180-line FastAPI app. Runs as a container on
`:4000` in both dev and prod — same code either way.

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
3. Create `run/` + per-bot `workspace/<bot>`, and ensure the single root
   `.env` exists (copied from `.env.example` when missing — edit it! All env
   vars live there now; there are no per-profile `.env` files).
4. Copy `skills/*` into each profile (existing skills are skipped).
5. Install the **retention cron** (daily 03:00).

Re-run `init` after changing config templates or skills — it skips existing
config/skills and re-installs the cron.

### `start` (order)

1. `docker compose -f docker/docker-compose.yml up -d --build` — starts
   searxng, zen-proxy, health-api, the **one multiplexed bot gateway**, and the
   dashboard. The gateway waits on `zen-proxy` via `depends_on: service_healthy`.
2. First, `start` best-effort kills any **stale native bot PIDs** left in
   `run/bots/*.pid` by the pre-Docker launcher (they would fight over the same
   Discord tokens). Stale pre-multiplex bot containers (one per profile) must
   also be gone before the new single gateway starts, or two gateways will fight
   over the same tokens.
3. retention: `scripts/retention.sh run` runs the one-shot `retention` service.

The gateway container starts via `test/entrypoint.sh`, which renders
`config.yaml.template` → `config.yaml` **for the default (master) profile and
each named profile** (`HERMES_BASE_URL=http://zen-proxy:4000/v1`,
`HERMES_CWD=/workspace/<profile>`), writes each profile's `.env`
(`DISCORD_BOT_TOKEN` / `DISCORD_HOME_CHANNEL` from the `<BOT>`-suffixed env
compose maps in), and runs `hermes gateway run --force --accept-hooks`.

### `stop` (reverse)

`docker compose down` (keeps volumes). Also best-effort stops a legacy
`hermes-gateway` systemd user unit if it lingers from a previous setup.

### `status`

`docker compose ps` — every service with its state and published ports.

### `clean` (destructive)

`docker compose down -v` (removes containers + the searxng volume), removes the
retention cron, deletes `run/`, and wipes each profile's runtime state +
rendered `config.yaml` + per-profile `.env` files. Asks for
confirmation. **Never touches remote MongoDB, committed files, or a host
`~/.hermes` (there is none to manage).**

---

## Bot profiles

`profiles/master/` is the **default profile home**: the committed
`config.yaml.template`, `SOUL.md`, skills, and the git-ignored rendered
`config.yaml` + runtime state (sessions, memories, kanban, cron, …). The other
five bots are **named profiles** nested under it at
`profiles/master/profiles/<bot>/` — the multiplexed gateway serves them all from
the ONE container. Every profile writes its own `.env`
(`DISCORD_BOT_TOKEN` / `DISCORD_HOME_CHANNEL`) via the entrypoint at container
start; the secrets themselves live in the root `.env` as
`DISCORD_BOT_TOKEN_<BOT>` / `DISCORD_HOME_CHANNEL_<BOT>`.

| Profile | Discord bot | Home channel | Purpose | Domain data |
|---------|-------------|--------------|---------|-------------|
| `master` | *(your coordinator)* | `DISCORD_HOME_CHANNEL_MASTER` | General coordinator, routes to domain bots | none |
| `story` | Portas-Mantainer | `1523762320986214541` | Story/worldbuilding from a lore vault | none |
| `helldivers` | Rouge Automaton | `1535601629884317696` | Helldivers 2 companion (static wiki DB) | `helldivers_*` |
| `money` | Miser | `1535611174039719976` | Money management | `money_transactions` |
| `food` | Caped Baldy (Saitama) | `1535613331610669117` | Food + workouts, Health Connect sync | `food_*` |
| `resumes` | Job Bot | `1536259587152543825` | Tailored resumes + cover letters from the Resumes repo clone | none |

Design plans: `profile-plans/*.md`.

### Config templates

Each `config.yaml.template` is a template with `${HERMES_BASE_URL}`,
`${HERMES_CWD}` (and `${DISCORD_HOME_CHANNEL}` on master). The container
entrypoint (`test/entrypoint.sh`) renders each profile's template to the
git-ignored `config.yaml` Hermes actually reads, with docker defaults:

- both dev + prod: `http://zen-proxy:4000/v1`, `/workspace/<profile>`

All templates set `onboarding.profile_build: off` so the gateway never rewrites
the tracked source of truth.

### Env (single root `.env`)

All secrets live in the ONE git-ignored root `.env` (tracked `.env.example` is
the template). compose maps each value into the services that need it via
`environment:` interpolation — e.g. `DISCORD_BOT_TOKEN_MASTER` /
`DISCORD_HOME_CHANNEL_MASTER` reach the gateway container, and the entrypoint
splits them into each profile's `.env` as bare `DISCORD_BOT_TOKEN` /
`DISCORD_HOME_CHANNEL` (read via Hermes' per-profile secret scope — never merged
into one global env).

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
  `DISCORD_BOT_TOKEN`/`DISCORD_HOME_CHANNEL` injected by compose from the root
  `.env` (`DISCORD_BOT_TOKEN_FOOD`/`DISCORD_HOME_CHANNEL_FOOD`).

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
default profile AND every named profile: the unified dashboard lists all six
bots (master + story/helldivers/money/food/resumes) with their own config, API keys,
sessions, and gateway state. It uses the prebuilt `hermes_cli/web_dist` shipped
in the package (`--skip-build`), so no Node/npm is needed.

A public bind **requires an auth provider**. This repo uses the built-in basic
(username/password) provider, configured via env in the root `.env`:

| Env var | Purpose |
|---------|---------|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | login username (default `admin`) |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | login password |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | token-signing key (32+ bytes) — set it or every restart logs you out |

Env wins over config.yaml. Override the bind with `HERMES_DASHBOARD_HOST`
(default `0.0.0.0`) and the port with `HERMES_DASHBOARD_PORT` (default `9119`).

---

## Development mode

One compose file for dev and prod (`docker/docker-compose.yml`). Set
`HERMES_ENV=dev` in the root `.env` and every data consumer writes to
`test_hermes` on the remote cluster instead of `hermes`. Dev and prod never
share a DB.

| Consumer | prod DB | dev DB |
|----------|---------|--------|
| `gateway` (money/food/helldivers) | `hermes` | `test_hermes` |
| `health-api` | `hermes` | `test_hermes` |
| `retention` | `hermes` | `test_hermes` |

### Bot image (`test/Dockerfile`)

- `python:3.11-alpine` + `hermes-agent` +
  `discord.py[voice]==2.7.1` + `pymongo` (Alpine keeps images ~40% smaller
  than the old `slim` base); the Dockerfile bakes in the same
  `hermes-god` toolset patch. This is the bot image for the whole stack.
- `user: "1000:1000"`, `HOME=/hermes-home`; mounts
  `profiles/master:/hermes-home`, `workspace:/workspace`, `../tools:/tools`
  (**read-only**). The default profile is `master`; the other five bots are
  named profiles under `$HERMES_HOME/profiles/`.
- `depends_on: zen-proxy (service_healthy)`.

### `entrypoint.sh`

1. `chown-data` mode (run once via `docker compose run --rm gateway chown-data`).
2. Renders `config.yaml.template` → `config.yaml` for the default profile AND
   each named profile, with docker defaults
   (`HERMES_BASE_URL=http://zen-proxy:4000/v1`, `HERMES_CWD=/workspace/<name>`,
   `MONGODB_DB=hermes` unless overridden by compose), and writes each
   profile's `.env` (`DISCORD_BOT_TOKEN` / `DISCORD_HOME_CHANNEL`).
3. `HERMES_MODE=dashboard` → `hermes dashboard --no-open --skip-build`;
   otherwise `exec hermes gateway run --force --accept-hooks`.

Env is injected entirely by compose from the root `.env` — no profile `.env`
to source.

The stack adds the same image as a `dashboard` service
(`HERMES_MODE=dashboard`, port 9119) and a `retention` service
(`entrypoint: ["python3", "/tools/retention.py"]`).

### Starting it

```bash
docker compose -f docker/docker-compose.yml up -d --build
docker compose -f docker/docker-compose.yml run --rm gateway chown-data   # once, as the mount owner
```

---

## Configuration reference

### Template placeholders

| Placeholder | Value |
|-------------|-------|
| `${HERMES_BASE_URL}` | `http://zen-proxy:4000/v1` |
| `${HERMES_CWD}` | `/workspace` |
| `${DISCORD_HOME_CHANNEL}` | from the root `.env` (`DISCORD_HOME_CHANNEL_<BOT>`, mapped by compose) |
| `MONGODB_DB` (env) | `hermes` (prod) or `test_hermes` (with `HERMES_ENV=dev`) |

### Root `.env` variables

The root `.env` is the **single source of truth** — every env var for the whole
stack. compose maps them into each service; there are no per-profile `.env`
files.

| Var | Required | Purpose |
|-----|----------|---------|
| `OPENCODE_API_KEY` | **yes** | Zen backend auth |
| `DEEPINFRA_API_KEY` | no | DeepInfra fallback auth |
| `HERMES_API_KEY` | no (default `zen-proxy`) | bots' Authorization to zen-proxy |
| `DISCORD_BOT_TOKEN_<BOT>` (`MASTER`/`STORY`/`HELLDIVERS`/`MONEY`/`FOOD`/`RESUMES`) | **yes** | one Discord token per bot |
| `DISCORD_HOME_CHANNEL_<BOT>` | **yes** | one home channel per bot |
| `HERMES_ENV` | no | `dev` → `test_` prefix on `MONGODB_DB`; prod/unset = as-is |
| `DISCORD_ALLOW_ALL_USERS` / `DISCORD_ALLOWED_USERS` | no | channel access policy |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` / `_SECRET` | for dashboard | dashboard login + stable signing secret |
| `HERMES_DASHBOARD_PORT` | no | dashboard bind port (default `9119`) |
| `USDA_API_KEY` | for food | nutrition lookups |
| `MONGODB_URI` | for money/food/helldivers | remote Mongo connection |
| `MONGODB_DB` | no | DB name for domain data (default `hermes`; `test_hermes` under `HERMES_ENV=dev`) |
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

- The root `.env` holds all live API keys, bot tokens, and Mongo creds.
  Git-ignored; only `.env.example` is tracked. Never commit it.
- `security.redact_secrets: true` in Hermes config.
- searxng container drops all capabilities.
- Dashboard binds `0.0.0.0:9119` behind username/password (basic auth).
- `clean` never touches remote MongoDB.
- Every container only sees the profiles + workspace it needs:
  `profiles/master:/hermes-home` (default + named profiles), `workspace:/workspace`,
  the **read-only** `/tools` mount — no Docker socket, no host paths. Only the
  specific env vars a service needs are injected via compose (bots never see
  proxy keys). Bots still have normal outbound network (Discord, remote Mongo,
  zen-proxy). `health-api` is the only service with
  `env_file: ../.env` (it needs the Mongo URI) plus the food token/channel.
- Dev isolation: `HERMES_ENV=dev` points every data consumer at a
  `test_`-prefixed DB on the remote cluster (`test_hermes`) — dev runs never
  write the prod DB.

---

## Extending the stack

### Add a model to the proxy

1. Add the mapping to `MODEL_MAP` in `docker/proxy/main.py`.
2. Add it to the static `/v1/models` list.
3. Restart the proxy: `./scripts/hermes.sh restart` (or `docker compose -f docker/docker-compose.yml up -d --build zen-proxy`).
4. Point a bot at it via `HERMES_MODEL` in the profile config template.

### Add a bot profile

1. Write the design plan under `profile-plans/`.
2. Create `profiles/master/profiles/<name>/` — copy `config.yaml.template` and
   `SOUL.md` from an existing named profile, copy its `skills/`, and set the
   Discord home channel in `discord.channel_skill_bindings`. (Named profiles
   have no `.env.example`; the entrypoint writes `.env` at start.)
3. Add the bot to the `BOTS` array in `scripts/hermes.sh`.
4. Add matching env (`DISCORD_BOT_TOKEN_<NAME>` / `DISCORD_HOME_CHANNEL_<NAME>`)
   to the gateway service's `environment:` in `docker/docker-compose.yml`
   (one compose file for the whole stack), and document them in root
   `.env.example`.
5. If the bot needs a tool in the image (e.g. `tectonic` for the resumes bot's
   LaTeX), add it to the `apk add` line in `test/Dockerfile`.
6. If the bot works on a private git repo, `init` clones it into its
   `workspace/` dir (see `HERMES_RESUMES_REPO` clone step) — the host needs an
   SSH key. The container commits locally; push/pull stay on the host.
7. Rebuild the gateway image and restart: `docker compose -f docker/docker-compose.yml up -d --build gateway`.
   The entrypoint picks up the new named profile automatically (no new service needed).

### Add a skill

Drop a directory with `SKILL.md` (with `name` + `description` frontmatter) into
`skills/`, then re-run `./scripts/hermes.sh init` to copy it into every profile.
Skill content, the skill-curator's `.curator_state`/`.usage.json`, `memories/`,
and each `SOUL.md` are committed so the bots' learned state survives moving
between VPSes.
