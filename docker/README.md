# SearXNG Docker Setup

Runs [SearXNG](https://docs.searxng.org/) (private metasearch engine) — the
**only** dockerized service in the live stack. The Zen proxy (`proxy/`) and
health-api (`health-api/`) are run natively by `scripts/hermes.sh`, not here.

## Quick Start

```bash
# Start SearXNG
make up

# View logs
make logs

# Check status
make status

# Stop
make down
```

## Files

```
docker/
├── docker-compose.yml      # searxng only (live stack)
├── Makefile                # Convenience commands
├── proxy/
│   ├── main.py             # Credit-aware API proxy (run natively on :4000)
│   └── ...
└── health-api/
    └── main.py             # Health Connect sync endpoint (run natively on :8001)
```

## Notes

- `SEARXNG_PORT` (default `8888`), `SEARXNG_HOSTNAME`, and `SEARXNG_SECRET_KEY`
  come from the **root** `.env` (`env_file: ../.env`).
- `make setup` copies a `docker/.env.example` that doesn't exist — the
  authoritative env file is the repo-root `.env`. `make` is just a thin wrapper
  around `docker compose` for the searxng service.
- The proxy and health-api source directories live here because the **test
  stack** (`test/docker-compose.yml`) builds them into containers; the live
  stack runs the same code natively.
