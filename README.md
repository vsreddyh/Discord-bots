# opencode-remote

Fully Dockerized Discord bot stack running **four Hermes profiles** (story, money, food, resumes) direct against OpenCode Zen (`https://opencode.ai/zen/v1`). Includes private SearXNG search, **one multiplexed Discord gateway container** with an embedded password-protected dashboard, Android Health Connect sync via `health-api`, and remote MongoDB persistence.

---

## Architecture

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

| Service | Container / Process | Published Port | Purpose |
|---|---|---|---|
| `gateway` | `gateway` container (`s6` supervised) | `9119` (dashboard) | Multiplexed Discord gateway for all 4 profiles + embedded Web UI dashboard |
| `health-api` | `health-api` container | `8001` | Ingests Health Connect sync data from Android and persists to MongoDB |
| `searxng` | `searxng` container | `8888` | Private search backend for web search tool |
| `retention` | `retention` container (one-shot) | — | Data retention policy runner (`tools/retention.py`) |
| `mongodb` | `mongodb` container (dev-only) | `27017` (internal) | Ephemeral local MongoDB active only when `HERMES_ENV=dev` |

---

## Profiles & Domains

| Profile | Bot Name | Channel Secret Key | Purpose & Storage | Data Retention Policy |
|---|---|---|---|---|
| `story` | Portas-Maintainer | `DISCORD_HOME_CHANNEL_STORY` | Mana Revolution lore vault in Git repo (`workspace/portals`, `vsreddyh/portals`) | No DB retention (Git tracked) |
| `money` | Miser | `DISCORD_HOME_CHANNEL_MONEY` | Expense/income tracking (`money_transactions` in MongoDB) | Autowiped when oldest entry > 90 days |
| `food` | Saitama | `DISCORD_HOME_CHANNEL_FOOD` | Food, weight, workouts, Health Connect sync (`food_*` in MongoDB) | Date rows pruned after 30 days; `food_weight` **never pruned** |
| `resumes` | Job Bot | `DISCORD_HOME_CHANNEL_RESUMES` | LaTeX resume tailoring & cover letters in Git repo (`workspace/resumes`, `vsreddyh/Resume`) | No DB retention (Git tracked) |

---

## Prerequisites & System Requirements

### VPS Sizing Guidelines

| Specification | Minimum Requirement | Recommended (Production) | Notes |
|---|---|---|---|
| **CPU** | 1 vCPU (x86_64 or ARM64) | 2–4 vCPUs | Docker image build (LaTeX/tectonic, Hermes) and SearXNG engine queries benefit from multiple cores. |
| **RAM** | 2 GB RAM (+ 2 GB swap) | 4–8 GB RAM | The multiplexed `gateway` (Python + 4 bots + web dashboard) and `searxng` consume ~1.2–1.8 GB steady-state. 2 GB minimum with swap is required to avoid OOM during `docker build`. |
| **Disk Storage** | 15 GB SSD | 30+ GB SSD | Docker base images, pip caches, SearXNG indices, local repo clones, LaTeX build artifacts, and logs. |
| **OS** | Linux (Ubuntu 22.04+, Debian 12+, Arch, Fedora) | Ubuntu 22.04/24.04 LTS or Debian 12 | Linux kernel 5.10+ with systemd and package manager (`apt`, `pacman`, or `dnf`). |

### Required Host Tools & Access
- **Git** (`git`) and **sudo** privileges (pre-installed).
- **Docker Engine** (24.0+) & **Docker Compose v2** (`docker compose` plugin). Auto-installed by `./scripts/hermes.sh init` if missing.
- **SSH Key Pair**: Configured in `~/.ssh` with read/write access to private GitHub repos for Git-backed bots:
  - `git@github.com:vsreddyh/portals.git` (Story bot lore vault)
  - `git@github.com:vsreddyh/Resume.git` (Resumes bot CV repository)

### Required External Services & API Keys
- **OpenCode Zen API Key**: `OPENCODE_ZEN_API_KEY` from [opencode.ai](https://opencode.ai) (model: `muse-spark-1.2-free`).
- **Discord Bot Tokens & Channels**: 4 application bot tokens with Message Content Intent enabled + Home Channel IDs:
  - `DISCORD_BOT_TOKEN_STORY` / `DISCORD_HOME_CHANNEL_STORY`
  - `DISCORD_BOT_TOKEN_MONEY` / `DISCORD_HOME_CHANNEL_MONEY`
  - `DISCORD_BOT_TOKEN_FOOD` / `DISCORD_HOME_CHANNEL_FOOD`
  - `DISCORD_BOT_TOKEN_RESUMES` / `DISCORD_HOME_CHANNEL_RESUMES`
- **MongoDB Cluster**: MongoDB connection URI (`MONGODB_URI`) and database name (`MONGODB_DB`, default `hermes`). (In dev mode, `HERMES_ENV=dev` provides an ephemeral local container).
- **USDA FoodData Central API Key**: `USDA_API_KEY` (or default demo key) for food nutrition lookups.
- **Health Sync Secret**: `HEALTH_SYNC_TOKEN` Bearer token matching the Android Health Gateway app.
- **Dashboard Web Credentials**: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`, and `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (32+ chars).

### Network & Firewall Ports
- Port `9119/tcp` (Hermes Dashboard) — Inbound access restricted or behind reverse proxy with Basic Auth.
- Port `8001/tcp` (Health API) — Inbound HTTP access for Android sync POST requests.
- Port `8888/tcp` (SearXNG) — Internal compose network (optional host publish).
- Outbound HTTPS (`443/tcp`) for Discord API/Gateway, OpenCode Zen (`opencode.ai`), MongoDB Atlas, and GitHub.

---

## Quick Start

### Setup and Execution

```bash
# 1. Initialize environment file and workspace
cp .env.example .env && nano .env

# 2. Build images and register daily retention cron
./scripts/hermes.sh init

# 3. Start the entire Docker stack
./scripts/hermes.sh start

# 4. Inspect container health and logs
./scripts/hermes.sh status
docker compose -f docker/docker-compose.yml logs -f gateway

# 5. Stop the stack
./scripts/hermes.sh stop
```

Dashboard is accessible at `http://<host>:9119` using credentials configured via `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` in `.env`.

---

## Management CLI

`scripts/hermes.sh` is the single entry-point orchestrator:

| Command | Action |
|---|---|
| `./scripts/hermes.sh init` | Self-installs host deps (curl, docker + compose, python3, cron, opencode CLI), builds images, creates directories, copies skills, sets up cron. |
| `./scripts/hermes.sh start` | Starts all services (`docker compose up -d --build`) and runs retention once. |
| `./scripts/hermes.sh stop` | Shuts down the stack (`docker compose down`). |
| `./scripts/hermes.sh restart` | Performs a clean stop and start sequence. |
| `./scripts/hermes.sh status` | Displays container health and published ports (`docker compose ps`). |
| `./scripts/hermes.sh clean` | **Destructive.** Wipes containers, volumes, `run/`, rendered configs, per-profile `.env` files, and retention cron. Remote MongoDB is untouched. |

---

## Development Mode

Setting `HERMES_ENV=dev` in the root `.env` switches the stack to an isolated dev environment:
- Starts a local ephemeral `mongo:7` container (`mongodb://mongodb:27017`, no volume).
- All services (gateway, health-api, retention) connect to the local container.
- Production remote MongoDB is never touched.
- Data resets cleanly upon container destruction.

---

## Health Connect Ingestion

1. **Android App** (`android/health-gateway/`): Reads steps, calories, sleep stages, and workout sessions from Health Connect. Syncs periodically or manually to `POST /api/health/sync` with Bearer auth (`HEALTH_SYNC_TOKEN`).
2. **`health-api` Service**: Validates auth, upserts daily totals (`food_daily_stats`), dedupes sessions (`food_sleep_log`, `food_workouts`), and broadcasts an instant update to the food Discord channel.

---

## Remote MongoDB & Data Retention

The shared CLI tool `tools/mongo.py` provides database operations:

```bash
python3 tools/mongo.py insert money_transactions '{"date":"2026-08-08","amount":300,"type":"expense","category":"groceries"}'
python3 tools/mongo.py aggregate money_transactions '[{"$group":{"_id":"$category","total":{"$sum":"$amount"}}}]'
```

Data lifecycle is governed by `tools/retention.py` (`scripts/retention.sh run`):
- `money_transactions`: Purges records where `date < today - 90d`.
- `food_daily_stats`, `food_sleep_log`, `food_workouts`: Purges records where `date < today - 30d`.
- `food_weight`: **Permanent retention** (never pruned).

---

## Repository Layout

```
├── AGENTS.md                # Agent sandbox rules and guidelines
├── README.md                # Stack overview and quickstart guide
├── documentation.md         # Deep-dive architecture and component documentation
├── docker/
│   ├── docker-compose.yml   # Unified compose configuration (searxng + health-api + gateway + retention)
│   ├── health-api/          # Health Connect FastAPI sync service
│   └── README.md            # Docker services documentation
├── test/
│   ├── Dockerfile           # Shared bot image definition (Alpine + hermes-god + s6-overlay)
│   └── entrypoint.sh        # Config rendering and s6 service orchestration
├── profiles/
│   └── master/              # Gateway home
│       ├── config.yaml.template
│       ├── SOUL.md
│       └── profiles/        # Nested named profiles (story, money, food, resumes)
├── tools/
│   ├── mongo.py             # MongoDB CLI helper for bot toolsets
│   └── retention.py         # Data lifecycle prune runner
├── scripts/
│   ├── hermes.sh            # Main orchestration CLI
│   ├── retention.sh         # Retention execution wrapper
│   └── sysmon.sh            # Resource metrics monitoring script
└── skills/                  # Core skill definitions propagated to bot profiles
```
