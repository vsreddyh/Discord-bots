# AGENTS.md

## Hard rule: this is a sandbox project

- NEVER modify, restart, or touch live Hermes state on this machine:
  - `~/.hermes/` (config.yaml, .env, logs, skills, state)
  - `hermes` CLI, `hermes-gateway` systemd unit, `hermes dashboard`
  - Docker stack on this machine (`searxng`) — compose files in
    this repo are the source of truth, but do NOT run `docker compose` or
    `./scripts/hermes.sh start|stop|restart|init` against the live daemons
    while working here.
- Work only inside this repo. Preview/validate changes here; the user applies
  them to the live machine themselves.
- If a task requires live Hermes action, STOP and ask the user first.

## What this project is

Runs **six Hermes bots** (1 master coordinator + 5 domain bots) against a
credit-aware LLM proxy: **OpenCode Zen** primary, **DeepInfra** fallback on
credit/payment errors. Private SearXNG, one Discord gateway per bot, a
password-protected dashboard, and remote MongoDB for domain data (money, food,
helldivers). **The live stack is fully Dockerized** — one compose file
(`docker/docker-compose.yml`): searxng + zen-proxy + health-api + 6 bots +
dashboard + a one-shot retention job. Development runs the SAME single compose
file; `HERMES_ENV=dev` in the root `.env` points every data consumer at a
separate `test_`-prefixed DB on the same remote cluster (`hermes` → `test_hermes`).
No host Hermes install, no native processes.

```
master ─┐
story ──┤ docker containers (HERMES_HOME=/hermes-home)
helldivers ├─► zen-proxy (:4000)  ── primary: OpenCode Zen ──► DeepInfra fallback
money ──┤    searxng (:8888)  •  health-api (:8001)  •  dashboard (:9119, password)
food ───┘    MongoDB (remote; money/food/helldivers)  •  retention (one-shot container)
resumes ──┤  Resumes repo clone (workspace/resumes)
```

## Repo facts

- ONLY the root `.env` exists (git-ignored; `.env.example` tracked). Every env
  var for the whole stack lives there — per-bot Discord tokens/channels
  (`DISCORD_BOT_TOKEN_<BOT>`/`DISCORD_HOME_CHANNEL_<BOT>`), proxy keys, Mongo
  URI, dashboard auth, USDA key. compose maps them into each service; there is
  NO `profiles/*/.env`. Stale per-profile `.env` files from before the
  consolidation are ignored by the entrypoint and can be deleted.
- Docs: `README.md` = quick start; `documentation.md` = deep dive.
- `scripts/hermes.sh` = single entry point (`init|start|stop|restart|status|clean`),
  a thin Docker orchestrator over `docker/docker-compose.yml`. No host installs.
  `init` self-installs the host tools it needs: **docker + compose, curl,
  python3, cron, opencode CLI** (only git + sudo must pre-exist), plus
  **Tailscale** (install + `up` with login URL + idempotent
  ufw allow-rules on `tailscale0` when ufw is active; never auto-enables
  default-deny). Skip Tailscale with `HERMES_NO_TAILSCALE=1`, opencode with
  `HERMES_NO_OPENCODE=1`. Dashboard (:9119) and health-api (:8001) are reached
  **only over the tailnet**.
- `scripts/retention.sh` = wrapper for the one-shot `retention` service
  (`docker compose run --rm retention` → `tools/retention.py`); cron daily 03:00
  installed by `init`, also runs on every `start`. money wipes transactions >90d;
  food prunes date rows >30d (never `food_weight`); helldivers (static) and story
  (no DB) are no-ops.
- `tools/mongo.py` = shared pymongo CLI; `tools/retention.py` = data lifecycle.
  `MONGODB_URI`/`MONGODB_DB` in root `.env`. `HERMES_ENV=dev` prefixes the DB
  name (`test_hermes`); `scripts/lib/common.sh` derives `MONGODB_DB_PREFIX=test_`.
- Docker: `docker/docker-compose.yml` = the whole stack (searxng + zen-proxy +
  health-api + 6 bots + dashboard + retention) — the ONLY compose file. Dev and
  prod run the same file; `HERMES_ENV=dev` keeps dev writes on a `test_`-prefixed
  DB, never the prod DB. The bot image is built from `test/Dockerfile` +
  `test/entrypoint.sh` (bakes in `hermes-god`); those are the image source, not
  a mirror stack.
  Per-bot tokens/channels are injected via compose `environment:` interpolation
  from the root `.env`; `docker_compose()` always passes `--env-file "$REPO/.env"`
  (compose otherwise looks for `.env` in the compose file's dir and every `${VAR}`
  silently falls back empty/default).
- Proxy model map (`docker/proxy/main.py` `MODEL_MAP`):
  `deepseek-v4-flash-free` → `deepseek-ai/DeepSeek-V4-Flash`,
  `mimo-v2.5-free` → `MiniMaxAI/MiniMax-M3`. Fallback fires on HTTP 402 or
  billing-keyword bodies (credits, quota exceeded, daily limit, ...).
  `MODEL_MAP` and the static `/v1/models` list must stay in sync.
- Discord routing: `DISCORD_ALLOW_ALL_USERS=true`, `group_sessions_per_user:
  false` (one shared conversation per channel), `discord.require_mention: true`,
  `discord.auto_thread: false` (inline replies, no threads), new conversation
  via built-in `/reset` (alias `/new`).
- Bot config source is `profiles/<bot>/config.yaml.template` (`${HERMES_BASE_URL}`,
  `${HERMES_CWD}`, master also `${DISCORD_HOME_CHANNEL}`). `test/entrypoint.sh`
  renders it to the git-ignored `profiles/<bot>/config.yaml` at container start
  with docker defaults: `zen-proxy:4000/v1` + `/workspace`.
- The `hermes-god` toolset is baked into the bot image (`test/Dockerfile`
  patches `toolsets.py` + `platforms.py` at build time) — there is NO host
  Hermes install to patch. `HERMES_MODE=dashboard` makes the same entrypoint run
  `hermes dashboard` (uses the prebuilt `hermes_cli/web_dist`, no npm).
- Dashboard binds `0.0.0.0:9119` with `HERMES_HOME=/hermes-home` (mounts
  `profiles/master`); auth via `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`/
  `_SECRET` in the root `.env` (a public bind requires an auth provider).
- Skills: project skills live in `skills/` and are copied into every profile on
  init. Hermes skill content (incl. autogenerated + `nousresearch/`), the
  skill-curator learning state (`.curator_state`/`.usage.json`), `memories/`,
  and each `SOUL.md` are **committed** so bot personality + learned state
  survives moving between VPSes. Only transient session/log/state files are
  git-ignored.
- No tests, linter, or CI in this repo; the proxy (`docker/proxy/main.py`) has
  zero tests. Verify with `bash -n scripts/*.sh` + render a template to /tmp,
  `docker compose -f docker/docker-compose.yml config`, then
  `curl localhost:4000/health` on the live machine.

## Gotchas

- `init` copies `.env.example` → `.env` (single root file) when none exists, then
  tells you to EDIT it — placeholder tokens/URIs won't work until you do.
- `make setup` in docker/ references `docker/.env.example` which doesn't exist;
  compose reads the ROOT `.env` (`env_file: ../.env`). `make` is only relevant
  for the searxng service now.
- `auto_thread` defaults `true` in Hermes — must be disabled for a persistent
  shared channel conversation.
- Legacy native install: `start` detects stale `run/bots/*.pid` processes and
  stops them first; if a `hermes-gateway` systemd unit survives, `stop`
  best-effort stops it. `clean` no longer touches `~/.hermes` (no host install).
- Migration (first Docker start after the native era): stop old native bots /
  dashboard / proxy / health-api before `./scripts/hermes.sh start`, or two
  gateways will fight over the same Discord tokens.
- Remote MongoDB is never touched by `clean`. Creds live only in git-ignored `.env`.
- Dev isolation = `HERMES_ENV=dev` in the root `.env` (prefixes DB: `test_hermes`)
  for bots, health-api, and retention. prod (or unset) = DB as-is. Keep
  `HERMES_ENV=dev` on dev machines — dropping it silently points dev at the prod
  DB. Dev machines run the same single compose file.
- Shared sessions = one running-agent slot per channel (messages interrupt/
  queue), shared token costs.
