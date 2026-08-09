---
name: docker-management
description: "Manage the project's Docker stack: zen-proxy, SearXNG, container lifecycle, logs, health checks, and cleanup."
---

# Docker Management

## Services

- **zen-proxy** — Credit-aware LLM proxy (OpenCode Zen → DeepInfra fallback). Port 4000. FastAPI.
- **searxng** — Private metasearch engine. Port 8888.

## Common commands

### Status
```bash
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml ps --status running
```

### Logs
```bash
docker compose -f docker/docker-compose.yml logs zen-proxy
docker compose -f docker/docker-compose.yml logs searxng
docker compose -f docker/docker-compose.yml logs -f --tail=50 zen-proxy
```

### Restart single service
```bash
docker compose -f docker/docker-compose.yml restart zen-proxy
```

### Rebuild and start
```bash
docker compose -f docker/docker-compose.yml up -d --build zen-proxy
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
curl -s http://localhost:4000/health
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888
```

### Cleanup
```bash
docker compose -f docker/docker-compose.yml down          # Stop + remove containers
docker compose -f docker/docker-compose.yml down -v       # Also remove volumes
docker system prune -f --volumes                           # Full cleanup
```

## Pitfalls

- Zen proxy won't start if `OPENCODE_API_KEY` is missing from `.env`
- SearXNG requires `SEARXNG_SECRET_KEY` to be set
- Port conflicts if `4000` or `8888` are already in use — change port mapping in `docker-compose.yml`
- After `.env` changes, restart the service: `docker compose restart zen-proxy`
