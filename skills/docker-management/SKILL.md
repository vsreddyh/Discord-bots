---
name: docker-management
description: "Manage the project's Docker stack: SearXNG, container lifecycle, logs, health checks, and cleanup."
---

# Docker Management

## Services

- **LLM** — OpenCode Zen direct (https://opencode.ai/zen/v1), no proxy.
- **searxng** — Private metasearch engine. Port 8888.

## Common commands

### Status
```bash
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml ps --status running
```

### Logs
```bash
docker compose -f docker/docker-compose.yml logs gateway
docker compose -f docker/docker-compose.yml logs searxng
docker compose -f docker/docker-compose.yml logs -f --tail=50 gateway
```

### Restart single service
```bash
docker compose -f docker/docker-compose.yml restart gateway
```

### Rebuild and start
```bash
docker compose -f docker/docker-compose.yml up -d --build gateway
```

### Always clean the build cache after building
Build cache grows fast (7.6 GB on this box) and never shrinks on its own.
Run this after every `--build` / `up -d --build`:
```bash
docker builder prune -f        # drop dangling build cache
```
- Run it **every build**, not occasionally.
- `-f` = no prompt. Safe — only removes cached layers, never images/containers.
- Size check: `docker system df`

### Health check
```bash
curl -s https://opencode.ai/zen/v1/models -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" | head -20
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888
```

### Cleanup
```bash
docker compose -f docker/docker-compose.yml down          # Stop + remove containers
docker compose -f docker/docker-compose.yml down -v       # Also remove volumes
docker system prune -f --volumes                           # Full cleanup
```

## Pitfalls

- OpenCode Zen direct — requires OPENCODE_ZEN_API_KEY in .env
- SearXNG requires `SEARXNG_SECRET_KEY` to be set
- Port conflicts if `8888` is already in use — change port mapping in `docker-compose.yml`
- After `.env` changes, restart the service: `docker compose restart gateway`
