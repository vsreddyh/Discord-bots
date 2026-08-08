# Money Bot

Hermes Agent profile: money tracking via Discord.

## Scope

- Log income/expenses in chat; answer questions by analyzing the data
- Daily + monthly summaries (Discord)
- Single bucket — no accounts, no budgets, no savings goals

## SQLite Schema

Local SQLite DB — a single file in the profile data dir. No remote/postgres
DB; all bots share this rule.

- `transactions` (date, amount, type, category, note)
  - `type`: `income` | `expense`
  - `category`: normalized (groceries, eating out, transport, bills, rent,
    shopping, health, fun, other, ...)

Agent queries SQLite directly (`sqlite3` CLI or inline Python).

## Chat Interaction

Free-form natural language. Agent infers intent (log vs question vs edit):

```
spent 300 on groceries
got 5000 salary
monthly salary credited
what did I spend this month?
how much on eating out in June?
biggest expense categories this month?
total income so far?
remove the 300 groceries entry
fix that to 350
```

Agent normalizes free-form descriptions into the `category` set, stores amount
and type, replies naturally.

## Summaries

- **Daily:** evening recap — total spent, top categories (via cron)
- **Monthly:** 1st of month — total in/out, breakdown by category, vs previous
  month (via cron)

## Profile

Isolated workspace, Discord-connected (same setup as food/workout bot). SQLite
DB in profile data dir.

### Discord identity

- Bot name: **Miser**
- Home channel: `1535611174039719976` (via `DISCORD_HOME_CHANNEL` /
  `channel_skill_bindings`)
- Token: per-profile `.env`, git-ignored — never commit it.
