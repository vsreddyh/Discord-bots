# opencode-remote

Run **five Hermes bots** (1 master coordinator + 4 domain bots) against a
credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on
credit/payment errors. Private SearXNG for search, a Discord gateway per bot, a
Hermes web dashboard behind a password, and a **Health Connect → food bot**
pipeline. Domain data (money, food, helldivers) lives in **remote MongoDB** —
local SQLite is gone.

**Everything runs in Docker.** The live stack is one compose file
(`docker/docker-compose.yml`): searxng, zen-proxy, health-api, the 5 bot
gateways, the dashboard, and a one-shot retention job. The `test/` stack is an
isolated mirror with an in-stack MongoDB (never touches the remote cluster).
Each bot runs in its own container with only its own profile, workspace, and a
read-only `/tools` helper — no host Hermes install, no native processes.

This repo is a **sandbox**: code and config live here; preview and validate
changes here, then apply them on your live machine yourself.

## Architecture

```
                              remote MongoDB (money, food, helldivers)
                                           ▲
master ─┐                                  │
story ──┤   docker containers              │        ┌──── searxng (:8888)
helldivers ├─ HERMES_HOME=/hermes-home     ▼        │
money ──┤   each: own Discord token    zen-proxy (:4000)
food ───┘                                ├─► OpenCode Zen ──► DeepInfra fallback
Health Gateway (Android) ──► health-api (:8001) ──► MongoDB
Hermes dashboard ──► 0.0.0.0:9119 (password auth, master profile)
retention ──► one-shot `docker compose run --rm retention` (cron 03:00)
```

| Component | Runs as | Port |
|-----------|---------|------|
| searxng | container | 8888 |
| zen-proxy | container | 4000 |
| health-api | container | 8001 |
| master / story / helldivers / money / food | container, one per bot | — |
| Hermes dashboard | container, `HERMES_HOME=/hermes-home` (master profile) | 9119 |
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

# 2. Build images, seed per-bot .env, set up Tailscale, install retention cron
./scripts/hermes.sh init

# 3. Per-bot secrets (5 files — each is git-ignored)
#    Edit every profiles/*/.env created from .env.example:
#    Discord token + home channel, dashboard password.
nano profiles/master/.env
nano profiles/story/.env
nano profiles/helldivers/.env
nano profiles/money/.env
nano profiles/food/.env

# 4. Start everything
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
| `./scripts/hermes.sh init` | Build images, set up Tailscale, install host tools (opencode CLI + python3, skip opencode with `HERMES_NO_OPENCODE=1`), ensure `profiles/*/.env` (+ copies skills), install retention cron |
| `./scripts/hermes.sh start` | `docker compose up -d --build`, then run retention once |
| `./scripts/hermes.sh stop` | `docker compose down` (keeps volumes) |
| `./scripts/hermes.sh restart` | Stop then start |
| `./scripts/hermes.sh status` | `docker compose ps` |
| `./scripts/hermes.sh clean` | **Destructive.** Down `-v`, wipe `run/`, profile runtime + rendered config + `.env`, retention cron. Remote MongoDB untouched. |

Direct docker access for a single service:

```bash
docker compose -f docker/docker-compose.yml logs -f food
docker compose -f docker/docker-compose.yml restart master
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

## Test stack (Docker)

Isolated mirror of the live stack so you can test the five bots + proxy +
health-api without touching anything live. Includes an **in-stack MongoDB** —
it never reaches your remote cluster. It shares the same bot image
(`test/Dockerfile` + `test/entrypoint.sh`) as the live stack.

```bash
docker compose -f test/docker-compose.yml build
docker compose -f test/docker-compose.yml run --rm story chown-data   # once, as the mount owner
docker compose -f test/docker-compose.yml up -d
docker compose -f test/docker-compose.yml ps
docker compose -f test/docker-compose.yml logs -f food
```

Bots read `profiles/<bot>/config.yaml.template` (rendered by `test/entrypoint.sh`
to `config.yaml` with docker defaults: `zen-proxy:4000`, `/workspace`,
`mongodb://mongodb:27017`). The shared Mongo helper is mounted at `/tools`
(read-only).

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
another bot's token or the host filesystem. `health-api` is the only service
that reads the root `.env` + `profiles/food/.env` (it needs `MONGODB_URI` and
the food channel token to post summaries).

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
│   ├── docker-compose.yml   # FULL live stack: searxng + proxy + health-api + 5 bots + dashboard + retention
│   ├── proxy/               # credit-aware FastAPI proxy
│   └── health-api/          # Health Connect sync endpoint
├── test/                    # isolated mirror: 5 bots + proxy + health-api + in-stack mongodb
│   ├── Dockerfile           # shared bot image (bakes in hermes-god)
│   └── entrypoint.sh        # renders config.yaml, runs gateway (or dashboard via HERMES_MODE)
├── profiles/                # 5 bot homes; config.yaml.template + .env + SOUL.md + skills
├── workspace/               # per-bot terminal cwd (git-ignored)
├── run/                     # retention log (git-ignored)
├── tools/                   # mongo.py (shared helper) + retention.py (data lifecycle)
├── scripts/hermes.sh        # init/start/stop/restart/status/clean (docker orchestrator)
├── scripts/retention.sh     # wrapper → docker compose run --rm retention
└── skills/                  # project skills copied to each profile on init
```

## Troubleshooting

- **Proxy unreachable** — `curl localhost:4000/health`; `docker compose -f docker/docker-compose.yml logs zen-proxy`; confirm `OPENCODE_API_KEY` in `.env`.
- **Bot won't start** — `docker compose -f docker/docker-compose.yml logs <bot>`; re-run `./scripts/hermes.sh init` to rebuild the image.
- **Dashboard auth loop** — set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD` (and a stable `_SECRET`) in `profiles/master/.env`.
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
   `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`/`_SECRET` in `profiles/master/.env`
   is still required.
3. **On the phone**: install Tailscale, log into the same tailnet, and set the
   health-gateway URL to `http://<vps-tailnet-ip>:8001`.

Skip Tailscale entirely during `init` with `HERMES_NO_TAILSCALE=1`.

SSH over Tailscale is a nice-to-have too: `sudo ufw allow in on tailscale0`
already covers it if you connect via the tailnet IP.

## Security

- `.env` and `profiles/*/.env` hold live keys/tokens/Mongo creds — git-ignored, never commit. Only `.env.example` files are tracked.
- Dashboard binds `0.0.0.0:9119` and requires username/password (basic auth provider) — the only thing protecting it on the public IP; use a strong password.
- `:9119` (dashboard) and `:8001` (health-api) are exposed publicly; everything else is internal to the compose network.
- `security.redact_secrets: true` in Hermes config.
- searxng container runs with all capabilities dropped.
- Per-bot containers are filesystem-isolated; `/tools` is read-only.
- Remote MongoDB creds are in `.env` only; `clean` never touches the cluster.
