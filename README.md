# Hermes Agent Scripts

Scripts to manage [Hermes Agent](https://hermes-agent.nousresearch.com/) with a credit-aware proxy that routes through OpenCode Zen and falls back to DeepInfra on credit/payment errors.

## Prerequisites

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) installed (run `./scripts/hermes.sh init`)
- [Docker](https://docs.docker.com/engine/install/) and Docker Compose
- `OPENCODE_API_KEY` set in `.env`

## Quick Start

```bash
# 1. Set up API keys
cp .env.example .env && nano .env

# 2. Init Hermes config (installs Hermes + writes configs)
./scripts/hermes.sh init

# 3. Start everything (proxy → gateway → dashboard)
./scripts/hermes.sh start

# 4. Check status
./scripts/hermes.sh status

# 5. Stop everything
./scripts/hermes.sh stop
```

## Commands

| Command | Description |
|---------|-------------|
| `init` | Install Hermes, write config.yaml, install skills, set up Discord, run diagnostics |
| `start` | Start Docker services → Hermes gateway → dashboard |
| `stop` | Stop dashboard → gateway → Docker services |
| `restart` | Stop then start |
| `status` | Show all service states |
| `docker logs [svc]` | Tail container logs (default: zen-proxy) |
| `docker rebuild` | Rebuild zen-proxy image |
| `docker shell [svc]` | Open shell in container |
| `docker ps` | List containers |
| `docker prune` | Clean up unused Docker resources |

## Skills

Skills in `skills/` are installed to `~/.hermes/skills/` during `init`. Currently includes:

| Skill | Description |
|-------|-------------|
| `i-have-adhd` | ADHD-friendly output formatting (action-first, no preamble, numbered steps) |

To auto-load a skill in a Discord channel, uncomment and fill in `channel_skill_bindings` in `default-config.yaml`:

```yaml
discord:
  channel_skill_bindings:
    - id: "YOUR_CHANNEL_ID"
      skills:
        - i-have-adhd
```

Then run `./scripts/hermes.sh init && hermes gateway restart`.

## Layout

```
scripts/
├── hermes.sh       # Single entry point for all management tasks
docker/
├── docker-compose.yml   # Zen proxy + SearXNG
├── .env                 # API keys (git-ignored)
└── proxy/
    ├── main.py          # Credit-aware proxy (FastAPI)
    ├── Dockerfile       # Proxy container
    └── requirements.txt # Python deps
skills/
└── i-have-adhd/
    └── SKILL.md          # ADHD-friendly output formatting skill
```

## Init Presets

| Env var | Default | Purpose |
|---------|---------|---------|
| `HERMES_PROVIDER` | `custom` | Provider (proxy on localhost:4000) |
| `HERMES_MODEL` | `deepseek-v4-flash-free` | Model name |
| `HERMES_API_KEY` | (none) | API key |
| `HERMES_BASE_URL` | `http://localhost:4000/v1` | Proxy endpoint |
| `HERMES_TERMINAL_BACKEND` | `local` | Terminal backend |
| `HERMES_MAX_TURNS` | `90` | Max conversation turns |
| `HERMES_REASONING` | `medium` | Reasoning effort |
| `HERMES_MEMORY_ENABLED` | `false` | Enable cross-session memory |
| `HERMES_DISABLED_TOOLSETS` | *(broad list)* | Toolsets to disable |
| `HERMES_EXTRA_KEYS` | (none) | Semicolon-separated `KEY=val` |

## Troubleshooting

- **Proxy won't start** — check `docker compose -f docker/docker-compose.yml logs zen-proxy`
- **Hermes can't reach the proxy** — verify `http://localhost:4000/v1` is accessible (`curl localhost:4000/health`)
- **Port in use** — change the port mapping in `docker/docker-compose.yml`
- **Gateway fails** — check `~/.hermes/logs/gateway.log`, run `sudo loginctl enable-linger $USER`
