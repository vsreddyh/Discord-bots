# AGENTS.md

## Hard rule: this is a sandbox project

- NEVER modify, restart, or touch live Hermes state on this machine:
  - `~/.hermes/` (config.yaml, .env, logs, skills, state)
  - `hermes` CLI, `hermes-gateway` systemd unit, `hermes dashboard`
  - Docker stack on this machine (`zen-proxy`, `searxng`) — compose files in
    this repo are the source of truth, but do NOT run `docker compose` or
    `./scripts/hermes.sh start|stop|restart|init` against the live daemons
    while working here.
- Work only inside this repo. Preview/validate changes here; the user applies
  them to the live machine themselves.
- If a task requires live Hermes action, STOP and ask the user first.

## What this project is

Runs [Hermes Agent](https://hermes-agent.nousresearch.com/) against a credit-aware
LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on credit/payment
errors. Plus private SearXNG search, Discord-integrated gateway, and dashboard.

```
Hermes Agent (custom provider) ──> zen-proxy (:4000)
   ── primary: OpenCode Zen (opencode.ai/zen/v1)
   ── fallback: DeepInfra (api.deepinfra.com) on credit errors
searxng (:8888)  •  hermes-gateway (systemd user unit)  •  dashboard (:9119)
```

## Repo facts

- `.env` is git-ignored; only `.env.example` is tracked.
- Docs: `README.md` = quick start; `documentation.md` = deep dive.
- `scripts/hermes.sh` = single entry point (`init|start|stop|restart|status`).
- Docker: `docker/Makefile` + `docker/docker-compose.yml` (zen-proxy, searxng).
- Proxy model map (`docker/proxy/main.py` `MODEL_MAP`):
  `deepseek-v4-flash-free` → `deepseek-ai/DeepSeek-V4-Flash`,
  `mimo-v2.5-free` → `MiniMaxAI/MiniMax-M3`. Fallback fires on HTTP 402 or
  billing-keyword bodies (credits, quota exceeded, daily limit, ...).
- Discord routing: `DISCORD_ALLOW_ALL_USERS=true`, `group_sessions_per_user:
  false` (one shared conversation per channel), `discord.require_mention: true`,
  `discord.auto_thread: false` (inline replies, no threads), new conversation
  via built-in `/reset` (alias `/new`).
- Env defaults live in `hermes.sh` `cmd_init` (e.g. `HERMES_MEMORY_ENABLED`
  defaults `true`, `HERMES_BASE_URL` `http://localhost:4000/v1`,
  `HERMES_MODEL` `deepseek-v4-flash-free`).

## Gotchas

- `init` SKIPS writing config.yaml if `~/.hermes/config.yaml` exists — edit live
  files directly (on the live machine, by the user) or delete them and re-init.
- `make setup` in docker/ references `docker/.env.example` which doesn't exist;
  compose reads the ROOT `.env` (`env_file: ../.env`).
- `auto_thread` defaults `true` in Hermes — must be disabled for a persistent
  shared channel conversation.
- systemd `hermes-gateway` needs `sudo loginctl enable-linger $USER`.
- Shared sessions = one running-agent slot per channel (messages interrupt/
  queue), shared token costs.
