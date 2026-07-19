# Hermes Agent Scripts

Scripts to manage all [Hermes Agent](https://hermes-agent.nousresearch.com/) services — gateway, dashboard, and status.

## Prerequisites

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) installed (run `init.sh` or install via `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`)
- API keys or OAuth configured (via env vars with `init.sh`, or manually with `hermes auth`)

## Usage

```bash
# Initial setup (install + write preset configs)
HERMES_PROVIDER=openrouter \
HERMES_MODEL=deepseek/deepseek-chat-v3-0324:free \
HERMES_API_KEY=sk-or-v1-... \
./scripts/init.sh

# Start all services (gateway + dashboard)
./scripts/start.sh

# Show status of all services
./scripts/status.sh

# Stop all services (dashboard + gateway)
./scripts/stop.sh

# Restart all services
./scripts/restart.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `init.sh` | Install Hermes (if missing), write `config.yaml` and `.env` from env vars, run diagnostics |
| `start.sh` | Start gateway + dashboard in background |
| `status.sh` | Show gateway, dashboard, and profile status |
| `stop.sh` | Stop dashboard + gateway gracefully |
| `restart.sh` | Stop then start |

## Init Presets

| Env var | Default | Purpose |
|---------|---------|---------|
| `HERMES_PROVIDER` | `openrouter` | LLM provider |
| `HERMES_MODEL` | `deepseek/deepseek-chat-v3-0324:free` | Model name |
| `HERMES_API_KEY` | (none) | Provider API key |
| `HERMES_BASE_URL` | (none) | Custom endpoint URL |
| `HERMES_TERMINAL_BACKEND` | `local` | Terminal backend |
| `HERMES_MAX_TURNS` | `90` | Max conversation turns |
| `HERMES_REASONING` | `medium` | Reasoning effort |
| `HERMES_MEMORY_ENABLED` | `false` | Enable cross-session memory |
| `HERMES_DISABLED_TOOLSETS` | *(broad list)* | Toolsets to disable |
| `HERMES_EXTRA_KEYS` | (none) | Semicolon-separated `KEY=val` pairs |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `HERMES_HOME` | `~/.hermes` | Hermes data directory |
| `HERMES_DASHBOARD_PORT` | `9119` | Dashboard port |

## Files

| Path | Purpose |
|------|---------|
| `~/.hermes/dashboard.pid` | PID file for the running dashboard |
| `~/.hermes/dashboard.log` | Dashboard stdout/stderr |
| `~/.hermes/config.yaml` | Hermes configuration |
| `~/.hermes/.env` | API keys and environment |
| `~/.hermes/logs/gateway.log` | Gateway logs |

## Troubleshooting

- **Services won't start** — run `hermes doctor` to verify dependencies.
- **Port in use** — set `HERMES_DASHBOARD_PORT` to a different value.
- **Gateway fails** — check `~/.hermes/logs/gateway.log`. Ensure `sudo loginctl enable-linger $USER` is set for background service.
- **Hermes not on PATH** — add `~/.local/bin` to `PATH` (installer adds this to `.bashrc`/`.zshrc`; source or restart shell).
- **npm/web build errors** — `start.sh` uses `--skip-build` to avoid needing npm at runtime.
