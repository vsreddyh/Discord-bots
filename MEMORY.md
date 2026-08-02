# Project Memory

Persistent context for AI agents working in this repo. Read this before making changes.

## SANDBOX RULE (read first)

This project is a **sandbox**. Never modify, restart, or touch live Hermes
state on this machine (`~/.hermes/`, the `hermes` CLI, `hermes-gateway`
systemd unit, `hermes dashboard`, or the live Docker stack). Work only inside
this repo; the user applies changes to the live machine themselves. If a task
requires live Hermes action, STOP and ask first. (Also codified in AGENTS.md.)

Note: the 2026-08-02 config changes listed below were applied to the live
machine at the user's request; do not assume live state matches this repo.

## What this project is

`opencode-remote` runs [Hermes Agent](https://hermes-agent.nousresearch.com/) against a
credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on
credit/payment errors. Plus a private SearXNG instance for web search, a
Discord-integrated gateway, and a local dashboard.

## Architecture

```
Hermes Agent (custom provider)
   │ http://localhost:4000/v1
   ▼
zen-proxy (Docker :4000) ── primary: OpenCode Zen (opencode.ai/zen/v1)
   │                        fallback: DeepInfra (api.deepinfra.com) on credit errors
   ▼
searxng (:8888)  •  hermes-gateway (systemd user unit)  •  dashboard (:9119)
```

## Key decisions (2026-08-02)

- **Discord chat model**: anyone in a channel can talk (`DISCORD_ALLOW_ALL_USERS=true`),
  all share ONE conversation per channel (`group_sessions_per_user: false`),
  bot replies only on `@mention` (`discord.require_mention: true`),
  `discord.auto_thread: false` so mentions reply inline instead of spawning threads,
  new conversation via the built-in `/reset` (alias `/new`) slash command.
- Docs split: `README.md` = quick start; `documentation.md` = deep dive.
- `future.md` and `profile-plans/` exist locally but are intentionally NOT committed.
- `HERMES_MEMORY_ENABLED` default is `true` (hermes.sh line 44) — the old README said
  `false`, that was wrong.

## Discord routing settings (live + template)

| Setting | Value | File |
|---------|-------|------|
| `DISCORD_ALLOW_ALL_USERS` | `true` | `~/.hermes/.env` (live), `.env.example` |
| `group_sessions_per_user` | `false` | `~/.hermes/config.yaml:157`, `default-config.yaml` |
| `discord.require_mention` | `true` | config.yaml + template |
| `discord.auto_thread` | `false` | config.yaml + template |
| `/reset` | built-in | no config needed |

Tradeoffs of shared sessions: one running-agent slot per channel (messages
interrupt/queue), shared token costs, one long task bloats everyone's context.

## The proxy (docker/proxy/main.py)

- Backends hardcoded: Zen `https://opencode.ai/zen/v1`, DeepInfra
  `https://api.deepinfra.com/v1/openai`.
- `MODEL_MAP`: `deepseek-v4-flash-free` → `deepseek-ai/DeepSeek-V4-Flash`,
  `mimo-v2.5-free` → `MiniMaxAI/MiniMax-M3`.
- Fallback triggers on HTTP 402 or 400/403/404/429 bodies matching ~20 billing
  keywords (credits, quota exceeded, daily limit, ...). Mirrors Hermes'
  `_is_payment_error`.
- Endpoints: `GET /health`, `GET /v1/models` (static), `POST /v1/chat/completions`.
  No embeddings/audio endpoints.
- Streaming passthrough works; single shared `httpx.AsyncClient`.

## Key commands

```bash
./scripts/hermes.sh init|start|stop|restart|status   # everything
make -C docker up|down|logs|status|build              # docker only
hermes gateway restart                                # apply config.yaml/.env changes
curl localhost:4000/health                            # proxy health
```

## Gotchas

- `init` SKIPS writing config.yaml if `~/.hermes/config.yaml` already exists —
  edit live files directly, or delete them and re-init.
- `make setup` in docker/ references `docker/.env.example` which does not exist;
  compose reads the ROOT `.env` (`env_file: ../.env`). Root `.env` is authoritative.
- `.env` contains live secrets (Discord token, API keys) — never commit it.
  `.gitignore` protects it; only `.env.example` is tracked.
- `auto_thread` defaults to `true` in Hermes plugin — every mention spawns a
  new thread. Turn it off explicitly whenever a persistent shared channel
  conversation is wanted.
- Systemd user unit `hermes-gateway` needs `sudo loginctl enable-linger $USER`
  for headless operation.

## Empty placeholders (intentional)

`profiles/`, `tools/`, `workspace/`, `skills/improve-codebase-architecture/`
are empty. Planned: per-profile gateway isolation (`terminal.backend: docker`).
