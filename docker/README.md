# Docker (Live Stack)

This directory is the **source of truth for the fully-Dockerized live stack**:
one compose file (`docker/docker-compose.yml`) that runs searxng, the zen-proxy,
health-api, the five Hermes bot gateways, the dashboard, and the one-shot
retention job. Managed by `scripts/hermes.sh`.

## Services

| Service | Role | Port |
|---------|------|------|
| `searxng` | private metasearch engine | 8888 |
| `zen-proxy` | credit-aware LLM proxy (OpenCode Zen → DeepInfra) | 4000 |
| `health-api` | Health Connect sync endpoint → MongoDB | 8001 |
| `master` / `story` / `helldivers` / `money` / `food` | one Hermes Discord bot each | — |
| `dashboard` | Hermes web dashboard (master profile, password auth) | 9119 |
| `retention` | one-shot data lifecycle job (`tools/retention.py`) | — |

The bot image is built from `../test` (`test/Dockerfile` + `test/entrypoint.sh`),
which bakes in the `hermes-god` toolset — the same image the test stack uses.

## Quick Start

Prefer the wrapper — it loads the root `.env` and handles everything:

```bash
./scripts/hermes.sh init     # build images, seed .env, install retention cron
./scripts/hermes.sh start    # up -d --build, then run retention
./scripts/hermes.sh status
```

Direct compose access:

```bash
docker compose -f docker/docker-compose.yml logs -f food
docker compose -f docker/docker-compose.yml restart master
docker compose -f docker/docker-compose.yml run --rm retention --dry-run
```

## Files

```
docker/
├── docker-compose.yml      # FULL live stack (searxng + proxy + health-api + 5 bots + dashboard + retention)
├── Makefile                # searxng convenience commands
├── proxy/
│   ├── main.py             # Credit-aware API proxy
│   └── ...
└── health-api/
    └── main.py             # Health Connect sync endpoint
```

## Notes

- `SEARXNG_PORT` (default `8888`), `SEARXNG_HOSTNAME`, and `SEARXNG_SECRET_KEY`
  come from the **root** `.env`; `scripts/hermes.sh` sources it before invoking
  compose. Services that need secrets use `env_file: ../.env`.
- `make setup` copies a `docker/.env.example` that doesn't exist — the
  authoritative env file is the repo-root `.env`. `make` is just a thin wrapper
  around `docker compose` for the searxng service.
- Bot state lives in the bind-mounted `profiles/<bot>` and `workspace/<bot>`
  dirs (all git-ignored), so state survives container restarts and is visible on
  the host.
