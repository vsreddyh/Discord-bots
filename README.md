# opencode-remote

Run [Hermes Agent](https://hermes-agent.nousresearch.com/) against a credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on credit/payment errors. Includes a private SearXNG instance for web search and a Discord-integrated gateway with voice.

## Architecture

```
Hermes Agent (custom provider)
        │  http://localhost:4000/v1
        ▼
┌───────────────────────────────┐
│  zen-proxy (Docker, :4000)   │  FastAPI, OpenAI-compatible
│  primary: OpenCode Zen        │  https://opencode.ai/zen/v1
│  fallback: DeepInfra          │  only on credit/payment errors
└───────────────────────────────┘
        │
        ├─ web search  →  searxng (Docker, :8888)
        ├─ Discord bot  →  hermes-gateway (systemd user unit)
        └─ dashboard    →  http://127.0.0.1:9119
```

## Prerequisites

- Docker + Docker Compose
- `OPENCODE_API_KEY` (from [opencode.ai](https://opencode.ai))
- Optional: `DEEPINFRA_API_KEY` for fallback, `DISCORD_BOT_TOKEN` for Discord

## Quick Start

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

Full walkthrough: [documentation.md](documentation.md)

## Commands

### `scripts/hermes.sh` — everything

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

## How the fallback works

`docker/proxy/main.py` forwards every `/v1/chat/completions` request to OpenCode Zen. If Zen returns a payment/credit error (HTTP 402, or 400/403/404/429 bodies matching billing keywords), the proxy rewrites the model ID and retries on DeepInfra. All other errors pass through as-is.

| Zen model | DeepInfra fallback |
|-----------|--------------------|
| `deepseek-v4-flash-free` | `deepseek-ai/DeepSeek-V4-Flash` |
| `mimo-v2.5-free` | `MiniMaxAI/MiniMax-M3` |

## Layout

```
├── default-config.yaml      # Hermes config template (envsubst placeholders)
├── docker/
│   ├── docker-compose.yml   # zen-proxy (:4000) + searxng (:8888)
│   ├── Makefile             # docker compose wrappers
│   └── proxy/               # credit-aware FastAPI proxy
├── docs/                    # guides (Discord voice, ...)
├── scripts/
│   └── hermes.sh            # single entry point for all management
├── skills/                  # copied to ~/.hermes/skills/ on init
│   ├── docker-management/
│   └── i-have-adhd/
├── profile-plans/           # planned profiles (not yet implemented)
├── profiles/                # placeholder — future profile isolation
├── tools/                   # placeholder
└── workspace/               # host-only mount (git-ignored)
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

- **Proxy won't start** — `docker compose -f docker/docker-compose.yml logs zen-proxy`; verify `OPENCODE_API_KEY` is in `.env`
- **Hermes can't reach the proxy** — `curl localhost:4000/health` should return `{"status":"ok"}`
- **Port in use** — change the mapping in `docker/docker-compose.yml` and `HERMES_BASE_URL`
- **Gateway fails** — `~/.hermes/logs/gateway.log`; run `sudo loginctl enable-linger $USER`
- **Dashboard missing** — `~/.hermes/dashboard.log`; PID tracked in `~/.hermes/dashboard.pid`

## Security

`.env` contains live API keys and bot tokens. It is git-ignored — never commit it. Only `.env.example` is tracked.
