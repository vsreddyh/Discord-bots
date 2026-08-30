# Docker (Live Stack)

This directory is the **source of truth for the fully-Dockerized live stack**:
one compose file (`docker/docker-compose.yml`) that runs searxng, health-api,
the four Hermes bots + dashboard (one multiplexed gateway with dashboard supervised via `s6` when `HERMES_DASHBOARD=1`, direct to https://opencode.ai/zen/v1 — mirrors official `nousresearch/hermes-agent`),
and the one-shot retention job. Managed by `scripts/hermes.sh`.

## Services

| Service | Role | Port |
|---------|------|------|
| `searxng` | private metasearch engine | 8888 |
| `OpenCode Zen` | direct HTTPS `https://opencode.ai/zen/v1` | — |
| `health-api` | Health Connect sync endpoint → MongoDB | 8001 |
| `gateway` | ONE multiplexed Hermes process — all four bots + dashboard (gateway home `profiles/master` + story/money/food/resumes named profiles under `profiles/master/profiles/`), `HERMES_DASHBOARD=1` via `s6` (unified dashboard on `:9119`) | 9119 |
| `retention` | one-shot data lifecycle job (`tools/retention.py`) | — |

The bot image is built from `../test` (`test/Dockerfile` + `test/entrypoint.sh`),
which bakes in the `hermes-god` toolset + `s6-overlay` — the same image the
retention service builds from (dashboard now runs inside `gateway` via `s6`).

## Quick Start

Prefer the wrapper — it loads the root `.env` and handles everything:

```bash
./scripts/hermes.sh init     # build images, seed .env, install retention cron
./scripts/hermes.sh start    # up -d --build, then run retention
./scripts/hermes.sh status
```

Direct compose access:

```bash
docker compose -f docker/docker-compose.yml logs -f gateway
docker compose -f docker/docker-compose.yml restart gateway
docker compose -f docker/docker-compose.yml run --rm retention --dry-run
```

## Files

```
docker/
├── docker-compose.yml      # FULL live stack (searxng + health-api + 4 bots + dashboard in 1 gateway via s6 + retention)
├── Makefile                # searxng convenience commands
└── health-api/
    └── main.py             # Health Connect sync endpoint
```

## Notes

- `SEARXNG_PORT` (default `8888`), `SEARXNG_HOSTNAME`, and `SEARXNG_SECRET_KEY`
  come from the **root** `.env`; `scripts/hermes.sh` sources it before invoking
  compose and always passes `--env-file "$REPO/.env"`. Services get their
  secrets via `environment:` interpolation — there is no `env_file:` directive.
- `make setup` copies a `docker/.env.example` that doesn't exist — the
  authoritative env file is the repo-root `.env`. `make` is just a thin wrapper
  around `docker compose` for the searxng service.
- Bot state lives in the bind-mounted `profiles/master` tree (including the
  named profiles under `profiles/master/profiles/`) and shared `workspace/`
  dirs (git-ignored), so state survives container restarts and is visible on
  the host.
