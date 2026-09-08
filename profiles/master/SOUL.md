# GATEWAY HOME — Multiplex Host (not a bot)

This directory is the Hermes gateway home (`HERMES_HOME=/hermes-home`).
It does NOT run a bot itself. It hosts the 3 named profiles under
`profiles/`:

- **story** (Portas-Maintainer) — Mana Revolution lore vault (`workspace/portals`, repo `vsreddyh/portals`).
- **resumes** (Job Bot) — tailored resumes + cover letters (`workspace/resumes`, repo `vsreddyh/Resume`).
- **default** (god profile) — general operator with three MCP tool backends:
  miser-money (`money_transactions` in remote MongoDB), cookbook
  (`cookbook_*`, permanent recipes), health-check (`hc_meals`/`hc_days`/`hc_weight`;
  Health Connect sync via `health-api`).

The gateway (`hermes gateway run --force --accept-hooks`) multiplexes all 3.
See `documentation.md` and `README.md` for lifecycle (`scripts/hermes.sh`).
