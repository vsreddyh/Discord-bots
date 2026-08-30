# GATEWAY HOME — Multiplex Host (not a bot)

This directory is the Hermes gateway home (`HERMES_HOME=/hermes-home`).
It does NOT run a bot itself. It hosts the 4 named profiles under
`profiles/`:

- **story** (Portas-Maintainer) — Mana Revolution lore vault (`workspace/portals`, repo `vsreddyh/portals`).
- **money** (Miser) — money management, `money_transactions` in remote MongoDB.
- **food** (Caped Baldy / Saitama) — food, workouts, weight; Health Connect sync.
- **resumes** (Job Bot) — tailored resumes + cover letters (`workspace/resumes`, repo `vsreddyh/Resume`).

The gateway (`hermes gateway run --force --accept-hooks`) multiplexes all 4.
See `documentation.md` and `README.md` for lifecycle (`scripts/hermes.sh`).
