#!/usr/bin/env bash
set -euo pipefail

# Data retention for the Hermes bots. Runs via cron (installed by
# scripts/hermes.sh init) and once on every start.
#
# Policies:
#   story       no domain DB                   — no-op
#   helldivers  static wiki DB (reference)     — no-op, never wiped
#   money       transactions autowiped when the oldest entry is >90 days old
#   food        date-based rows pruned after 30 days; food_weight is NEVER touched
#
# Remote MongoDB is the only store these policies touch. Environment comes
# from the repo-root .env (MONGODB_URI / MONGODB_DB).

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$REPO/.env" ]]; then
    set -a
    source "$REPO/.env"
    set +a
fi

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
else
    DRY_RUN=0
fi

python3 - "$DRY_RUN" <<'PY'
import datetime
import os
import sys

dry_run = int(sys.argv[1])
uri = os.environ.get("MONGODB_URI", "").strip()
if not uri:
    print("[retention] MONGODB_URI not set — skipping.")
    raise SystemExit(0)

try:
    from pymongo import MongoClient
except ImportError:
    print("[retention] pymongo not installed — skipping.")
    raise SystemExit(0)

db = MongoClient(uri, serverSelectionTimeoutMS=8000)[
    os.environ.get("MONGODB_DB", "hermes").strip() or "hermes"
]

today = datetime.date.today()

# ── money: wipe transactions older than 90 days ──────────────
money_cutoff = (today - datetime.timedelta(days=90)).isoformat()
money_res = db["money_transactions"].delete_many({"date": {"$lt": money_cutoff}})
print(f"[retention] money: removed {money_res.deleted_count} transactions older than {money_cutoff}")

# ── food: prune date-based rows older than 30 days ───────────
# food_weight is intentionally NOT in this list — weight history is kept.
food_cutoff = (today - datetime.timedelta(days=30)).isoformat()
for col in ("food_daily_stats", "food_sleep_log", "food_workouts"):
    res = db[col].delete_many({"date": {"$lt": food_cutoff}})
    print(f"[retention] food: removed {res.deleted_count} from {col} older than {food_cutoff}")

# ── helldivers / story: static or no data — no-op ────────────
print("[retention] helldivers/story: no retention policy (static/no DB).")
PY
