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

## Repo facts

- See MEMORY.md for architecture, routing config, and gotchas.
- `.env` is git-ignored; only `.env.example` is tracked.
- `future.md` and `profile-plans/` are intentionally NOT committed.
