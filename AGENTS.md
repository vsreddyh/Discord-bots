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

Runs **three Hermes profiles** (story, resumes, default-god) against
OpenCode Zen directly (no proxy). Private SearXNG, ONE multiplexed Discord gateway process
for all three profiles (Hermes `gateway.multiplex_profiles`; domain profiles are
nested under `profiles/master/profiles/<bot>/`), a password-protected dashboard
(supervised alongside gateway via `s6`, `HERMES_DASHBOARD=1` in the same `gateway`
container — mirrors official `nousresearch/hermes-agent`),
and remote MongoDB for domain data (money, health, cookbook). **The live stack
is fully Dockerized** — one compose file (`docker/docker-compose.yml`): searxng
+ health-api + one `gateway` container (all 3 profiles + dashboard, direct to `https://opencode.ai/zen/v1`, `s6` supervised) +
a one-shot retention job (plus ephemeral `mongodb` in dev). Development runs the SAME single compose file;
`HERMES_ENV=dev` in the root `.env` switches every data consumer to a temporary
local `mongodb` container (`mongodb://mongodb:27017`, no volume, ephemeral).
No host Hermes install, no native processes.

```
story+resumes+default
   └─► ONE docker `gateway` container (HERMES_HOME=/hermes-home = profiles/master, HERMES_DASHBOARD=1 via s6)
        └─► OpenCode Zen direct (https://opencode.ai/zen/v1, model muse-spark-1.2-free)
searxng (:8888)  •  health-api (:8001)  •  dashboard (:9119, password, s6 alongside gateway)
MongoDB (remote prod; ephemeral local in dev)  •  retention (one-shot container)
workspace/portals (lore vault, repo vsreddyh/portals) + workspace/resumes (repo vsreddyh/Resume) — separate git repos
```

## Repo facts

- ONLY the root `.env` exists (git-ignored; `.env.example` tracked). Every env
  var for the whole stack lives there — per-bot Discord tokens/channels
  (`DISCORD_BOT_TOKEN_<BOT>`/`DISCORD_HOME_CHANNEL_<BOT>`), proxy keys, Mongo
   URI, dashboard auth. compose maps them into each service; there is
  NO `profiles/*/.env`. Stale per-profile `.env` files from before the
  consolidation are ignored by the entrypoint and can be deleted.
- Docs: `README.md` = quick start; `documentation.md` = deep dive.
- `scripts/hermes.sh` = single entry point (`init|start|stop|restart|status|clean`),
  a thin Docker orchestrator over `docker/docker-compose.yml`. No host installs.
  `init` self-installs the host tools it needs: **docker + compose, curl,
  python3, cron** (only git + sudo must pre-exist). Hermes harness only —
  `init` never installs the opencode CLI. Dashboard (:9119) and health-api (:8001) bind `0.0.0.0` inside Docker.
- `scripts/retention.sh` = wrapper for the one-shot `retention` service
  (`docker compose run --rm retention` → `tools/retention.py`); cron daily 03:00
   installed by `init`, also runs on every `start`. money wipes transactions >90d;
   health-check prunes `hc_meals`/`hc_days` >30d (never `hc_weight`); cookbook is
   permanent; story/resumes (git repos) are no-ops.
- `tools/mongo.py` = shared pymongo CLI; `tools/retention.py` = data lifecycle.
  `MONGODB_URI`/`MONGODB_DB` in root `.env` for prod; `HERMES_ENV=dev` switches
  to ephemeral local `mongodb` container (`mongodb://mongodb:27017`, no volume)
  via `scripts/lib/common.sh` (`COMPOSE_PROFILES=dev`). `clean` removes the
  ephemeral dev data on `down -v` (or container remove) since there is no volume.
- Docker: `docker/docker-compose.yml` = the whole stack (searxng
   + health-api + gateway (+ dashboard via s6 when HERMES_DASHBOARD=1) + retention) — the ONLY compose file. Dev and
   prod run the same file; `HERMES_ENV=dev` keeps dev writes on a `test_`-prefixed
   DB, never the prod DB. The bot image is built from `test/Dockerfile` +
   `test/entrypoint.sh` (bakes in `hermes-god` + `s6-overlay`); those are the image source, not
   a mirror stack.
   Per-bot tokens/channels are injected via compose `environment:` interpolation
   from the root `.env`; `docker_compose()` always passes `--env-file "$REPO/.env"`
   (compose otherwise looks for `.env` in the compose file's dir and every `${VAR}`
   silently falls back empty/default).
- LLM: direct to OpenCode Zen (`https://opencode.ai/zen/v1`, model `muse-spark-1.2-free`) — no proxy container.
- Discord routing: `DISCORD_ALLOW_ALL_USERS=true`, `group_sessions_per_user:
  false` (one shared conversation per channel), `discord.require_mention: true`,
  `discord.auto_thread: false` (inline replies, no threads), new conversation
  via built-in `/reset` (alias `/new`).
- Bot config source is `profiles/master/config.yaml.template` (gateway home,
  not a bot) and `profiles/master/profiles/<bot>/config.yaml.template` (the four
  domain bots — nested because Hermes multiplexes named profiles under the
  gateway home). Templates use `${HERMES_BASE_URL}` and `${HERMES_CWD}` plus
  `${DISCORD_HOME_CHANNEL}` (entrypoint exports per-profile channel before render).
  `test/entrypoint.sh` renders each to a git-ignored `config.yaml` at container
  start with docker defaults: `https://opencode.ai/zen/v1` + `/workspace/<bot>`, and
  writes each profile's `.env` (`DISCORD_BOT_TOKEN`/`DISCORD_HOME_CHANNEL`)
  from the compose-injected vars.
- The `hermes-god` toolset is baked into the bot image (`test/Dockerfile`
   patches `toolsets.py` + `platforms.py` at build time) — there is NO host
   Hermes install to patch. `HERMES_DASHBOARD=1` makes the same entrypoint run
   `hermes dashboard` alongside `hermes gateway run` via `s6` in the same
   container (uses the prebuilt `hermes_cli/web_dist`, no npm).
- Dashboard binds `0.0.0.0:9119` with `HERMES_HOME=/hermes-home` (mounts
   `profiles/master`, supervised alongside gateway via `s6` when `HERMES_DASHBOARD=1`); auth via `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`_PASSWORD`/
   `_SECRET` in the root `.env` (a public bind requires an auth provider).
- Skills: project skills live in `skills/` and are copied into every profile on
  init. Hermes skill content (incl. autogenerated + `nousresearch/`), the
  skill-curator learning state (`.curator_state`/`.usage.json`),
  and each `SOUL.md` are **committed** so bot personality + learned state
  survives moving between VPSes. Only transient session/log/state files are
  git-ignored (runtime `memories/` are not tracked).
- No tests, linter, or CI in this repo. Verify with `bash -n scripts/*.sh` + render a template to /tmp,
  `docker compose -f docker/docker-compose.yml config`, then check gateway logs on the live machine.

## Gotchas

- `init` copies `.env.example` → `.env` (single root file) when none exists, then
  tells you to EDIT it — placeholder tokens/URIs won't work until you do.
- `make setup` in docker/ references `docker/.env.example` which doesn't exist;
  compose reads the ROOT `.env` via `--env-file "$REPO/.env"` (there is no
  `env_file:` directive). `make` is only relevant for the searxng service now.
- `auto_thread` defaults `true` in Hermes — must be disabled for a persistent
  shared channel conversation.
- Legacy native install: `start` detects stale `run/bots/*.pid` processes and
  stops them first; if a `hermes-gateway` systemd unit survives, `stop`
  best-effort stops it. `clean` no longer touches `~/.hermes` (no host install).
- Migration (first Docker start after the native era): stop old native bots /
  dashboard / health-api before `./scripts/hermes.sh start`, or two
  gateways will fight over the same Discord tokens.
- Remote MongoDB is never touched by `clean`. Creds live only in git-ignored `.env`.
- Dev isolation = `HERMES_ENV=dev` in the root `.env` uses a temporary local
  `mongodb` container (`mongodb://mongodb:27017`, no volume, ephemeral) for
  bots, health-api, and retention. Prod (or unset) = remote `MONGODB_URI` as-is.
  Keep `HERMES_ENV=dev` on dev machines — dropping it silently points dev at the
  prod DB. Dev machines run the same single compose file with `COMPOSE_PROFILES=dev`.
- Shared sessions = one running-agent slot per channel (messages interrupt/
  queue), shared token costs.
