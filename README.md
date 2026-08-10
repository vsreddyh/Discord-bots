# opencode-remote

Run **six Hermes bots** (1 master coordinator + 5 domain bots) against a
credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on
credit/payment errors. Private SearXNG for search, a **Discord gateway per bot
multiplexed into ONE Hermes process** (5 profiles, one unified dashboard), and a
**Health Connect → food bot** pipeline. Domain data (money, food, helldivers)
lives in **remote MongoDB** — local SQLite is gone.

**Everything runs in Docker.** The whole stack is one compose file
(`docker/docker-compose.yml`): searxng, zen-proxy, health-api, the **single
multiplexed bot gateway**, the dashboard, and a one-shot retention job.
Development runs the SAME compose file; `HERMES_ENV=dev` in the root `.env`
points every data consumer at a `test_`-prefixed DB on the remote cluster
(`hermes` → `test_hermes`) — dev writes never touch the prod DB. One Hermes
gateway container serves all six bots: `master` is the default profile home,
the other five are named profiles nested under it
(`profiles/master/profiles/<bot>/`), each with its own profile home, workspace,
Discord token, and per-profile credential scope — no host Hermes install, no
native processes.

This repo is a **sandbox**: code and config live here; preview and validate
changes here, then apply them on your live machine yourself.

## Architecture

```
                              remote MongoDB (money, food, helldivers)
                                           ▲
                            docker containers
 master (default profile) ─┐               │        ┌──── searxng (:8888)
 story ──┤                 │               │        │
 helldivers ├─ ONE gateway │ HERMES_HOME=  ▼        │
 money ──┤   (multiplex:    │ /hermes-home │   zen-proxy (:4000)
 food ───┘   6 profiles)    │              ├─► OpenCode Zen ──► DeepInfra fallback
 resumes ──┘                │              │
                             │              │
         each profile: own Discord token + workspace + secret scope
Health Gateway (Android) ──► health-api (:8001) ──► MongoDB
Hermes dashboard ──► 0.0.0.0:9119 (password auth, unified — lists all 6 bots)
retention ──► one-shot `docker compose run --rm retention` (cron 03:00)
```

| Component | Runs as | Port |
|-----------|---------|------|
| searxng | container | 8888 |
| zen-proxy | container | 4000 |
| health-api | container | 8001 |
| all 6 bots | ONE multiplexed `gateway` container (`HERMES_HOME=/hermes-home`, `gateway.multiplex_profiles: true`) | — |
| Hermes dashboard | container, `HERMES_HOME=/hermes-home` (unified profile list) | 9119 |
| retention | one-shot container | — |

## Bots

| Bot | Name (Discord) | Domain data | Retention |
|-----|----------------|-------------|-----------|
| `master` | — | none | — |
| `story` | Portas-Mantainer | none (lore vault) | — |
| `helldivers` | Rouge Automaton | static wiki DB in MongoDB | never wiped |
| `money` | Miser | `money_transactions` | autowipe when oldest entry > 90 days |
| `food` | Caped Baldy | `food_daily_stats` / `food_sleep_log` / `food_workouts` / `food_weight` | date rows pruned after 30 days; **weight never touched** |

## Prerequisites

- Docker + Compose v2
- `OPENCODE_API_KEY` (from [opencode.ai](https://opencode.ai))
- Remote MongoDB URI (money/food/helldivers)
- Optional: `DEEPINFRA_API_KEY`, `DISCORD_BOT_TOKEN` per bot

## Quick Start

```bash
# 1. Set up API keys
cp .env.example .env && nano .env

# 2. Build images, set up Tailscale, install retention cron
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
| `./scripts/hermes.sh init` | Self-install host deps (curl, docker + compose, python3, cron, Tailscale, opencode CLI), build images, seed the single root `.env` (+ copies skills), install retention cron. Skip opencode with `HERMES_NO_OPENCODE=1`, skip Tailscale with `HERMES_NO_TAILSCALE=1`. Only git + sudo must already exist. |
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
- **helldivers** — static wiki reference data, never wiped.
- **story** — no domain DB.

## Development mode

Same single compose file as production. Set `HERMES_ENV=dev` in the root `.env`
and every data consumer (bots, health-api, retention) writes to `test_hermes`
on the remote cluster instead of `hermes`. `prod` or unset = the DB as-is.

```bash
# prod or dev — same file, same commands
./scripts/hermes.sh start
# or directly:
docker compose -f docker/docker-compose.yml up -d --build
```

Each profile reads its own `profiles/master/(profiles/<bot>/)?config.yaml.template`
(rendered by `test/entrypoint.sh` to `config.yaml` with docker defaults:
`zen-proxy:4000`, `/workspace/<bot>`, `hermes`). The entrypoint
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

## Isolation

Each bot container sees **only**:
- its own profile (`profiles/<bot>` as `/hermes-home`),
- its own workspace (`workspace/<bot>` as `/workspace`),
- the shared `/tools` helper **read-only**.

No sibling profiles, no root `.env`, no Docker socket, no host paths. Bots have
normal outbound network (Discord, remote Mongo, zen-proxy) but never hold
another bot's token or the host filesystem. `health-api` reads the root `.env`
(it needs `MONGODB_URI`) plus the food bot's token/channel, injected via
compose from `DISCORD_BOT_TOKEN_FOOD`/`DISCORD_HOME_CHANNEL_FOOD`, to post
summaries.

## Skills

Hermes skill content (including autogenerated and `nousresearch/` packs), the
skill-curator learning state (`.curator_state` / `.usage.json`), long-term
`memories/`, and each `SOUL.md` are **committed** — so the whole personality and
learned state moves with the repo between VPSes. Only transient per-run
session/log/state files are git-ignored. Channel bindings live in each
`config.yaml.template` → `discord.channel_skill_bindings`.

## Layout

```
├── AGENTS.md                # sandbox rules + repo facts
├── default-config.yaml      # reference Hermes config (master-style)
├── docker/
│   ├── docker-compose.yml   # FULL live stack: searxng + proxy + health-api + 1 multiplexed gateway (6 bots) + dashboard + retention
│   ├── proxy/               # credit-aware FastAPI proxy
│   └── health-api/          # Health Connect sync endpoint
├── test/                    # shared bot image source (Dockerfile + entrypoint) — NOT a stack
│   ├── Dockerfile           # shared bot image (bakes in hermes-god)
│   └── entrypoint.sh        # renders all profiles' config.yaml + writes per-profile .env, runs gateway (or dashboard via HERMES_MODE)
├── profiles/
│   └── master/              # default profile home (config.yaml.template + SOUL.md + skills)
│       └── profiles/        # named profiles: story, helldivers, money, food (each its own config + SOUL + skills)
├── workspace/               # per-bot terminal cwd, <bot>/ per profile (git-ignored)
├── run/                     # retention + sysmon logs (git-ignored)
├── tools/                   # mongo.py (shared helper) + retention.py (data lifecycle)
├── scripts/hermes.sh        # init/start/stop/restart/status/clean (docker orchestrator)
├── scripts/retention.sh     # wrapper → docker compose run --rm retention
├── scripts/sysmon.sh        # host-wide resource sampler (record/report/install/remove)
└── skills/                  # project skills copied to each profile on init
```

## Troubleshooting

- **Proxy unreachable** — `curl localhost:4000/health`; `docker compose -f docker/docker-compose.yml logs zen-proxy`; confirm `OPENCODE_API_KEY` in `.env`.
- **A bot not responding on Discord** — `docker compose -f docker/docker-compose.yml logs gateway` (all 5 bots share this one process); confirm its `DISCORD_BOT_TOKEN_<BOT>`/`DISCORD_HOME_CHANNEL_<BOT>` in `.env`; `docker compose -f docker/docker-compose.yml restart gateway`.
- **Dashboard auth loop** — set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (and a stable `_SECRET`) in the root `.env`.
- **Mongo connection refused** — `docker compose -f docker/docker-compose.yml exec money python3 /tools/mongo.py count money_transactions`; verify `MONGODB_URI` in root `.env`.
- **Retention not running** — `crontab -l | grep retention`; re-run `init`.
- **Health API unreachable** — `curl localhost:8001/health` from the VPS, then `curl http://<tailnet-ip>:8001/health` from the phone (see "Access (Tailscale)" below); check `tailscale status` on both devices.

## Access (Tailscale)

Dashboard and health-api are reached **only over Tailscale** — no public ports.
Every service binds `0.0.0.0` (so it's already reachable on the tailnet), and a
firewall blocks the ports from the public internet. This VPS is on a tailnet
with the phone, so:

| Service | Reachable at |
|---------|--------------|
| dashboard | `http://100.64.64.42:9119` (replace with the VPS's `tailscale ip -4`) |
| health-api | `http://100.64.64.42:8001` (the Android app URL) |

`8888` (searxng), `4000` (zen-proxy), and the bot ports need no external access
at all — the bots call searxng/zen-proxy by their internal compose names.

### One-time Tailscale setup

`./scripts/hermes.sh init` does most of this automatically (install if missing,
`tailscale up` with the login URL printed, and idempotent firewall allow-rules
on `tailscale0` when ufw is already active):

1. **Install + bring up the tailnet** — `init` does it; otherwise:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up            # log in, then note the IP: tailscale ip -4
   ```
2. **Firewall** — `init` adds the rules if ufw is active. On a fresh host it
   deliberately won't enable default-deny (lockout risk); do that manually:
   ```bash
   sudo ufw default deny incoming
   sudo ufw allow 22/tcp
   sudo ufw allow in on tailscale0
   sudo ufw enable
   ```
   The dashboard (:9119) and health-api (:8001) stay published on `0.0.0.0`
    inside Docker, but only the tailnet can reach them. Strong
    `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`/`_SECRET` in the root `.env` is
    still required.
3. **On the phone**: install Tailscale, log into the same tailnet, and set the
   health-gateway URL to `http://<vps-tailnet-ip>:8001`.

Skip Tailscale entirely during `init` with `HERMES_NO_TAILSCALE=1`.

SSH over Tailscale is a nice-to-have too: `sudo ufw allow in on tailscale0`
already covers it if you connect via the tailnet IP.

## Security

- The root `.env` holds all live keys/tokens/Mongo creds — git-ignored, never commit. Only `.env.example` is tracked.
- Dashboard binds `0.0.0.0:9119` and requires username/password (basic auth provider) — the only thing protecting it on the public IP; use a strong password.
- `:9119` (dashboard) and `:8001` (health-api) are exposed publicly; everything else is internal to the compose network.
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped.
- Per-bot containers are filesystem-isolated; `/tools` is read-only.
- Remote MongoDB creds are in `.env` only; `clean` never touches the cluster.
