# Zen Proxy + SearXNG Docker Setup

Run the [Zen Proxy](proxy/) (credit-aware OpenCode Zen → DeepInfra proxy) and [SearXNG](https://docs.searxng.org/) (private metasearch engine) in Docker.

## Quick Start

```bash
# 1. Setup — copies .env.example → .env, starts services
make setup

# 2. Edit .env with your API keys
#    At minimum, set OPENCODE_API_KEY
vim .env

# 3. Restart to apply
make restart
```

## Usage

```bash
# Start all services
make up

# View logs
make logs

# Check status
make status

# Stop all
make down
```

## Files

```
docker/
├── docker-compose.yml      # Service definitions
├── Makefile                # Convenience commands
docker/proxy/
├── main.py                 # Credit-aware API proxy
├── Dockerfile              # Proxy container
└── requirements.txt        # Python deps
```

## About the Zen Proxy

The proxy sits on port `4000` and forwards all requests to OpenCode Zen. If OpenCode Zen returns a credit/payment error (HTTP 402 or billing-related message), the proxy automatically retries the request on DeepInfra. All other errors pass through as-is.

Set `OPENCODE_API_KEY` and optionally `DEEPINFRA_API_KEY` in `.env`.
