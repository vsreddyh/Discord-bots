# Food & Workout Bot

A Hermes Agent profile for food and workout tracking.

## Behavior

- Log meals: name + quantity + calories; web search for unknown values
- Daily calorie goal from TDEE (pure Python)

## Data Storage — SQLite

- meals (date, type, name, quantity, calories)
- workouts (date, type, duration, notes) — from Health Connect
- daily_stats (date, steps, active_calories) — one row per day
- sleep_log (date, sleep_start, wake_time, hours, quality) — manual morning entry

Agent queries the DB via a Python helper script:
- add meal
- log sleep (daily morning entry)
- sync watch data from Health Connect gateway
- daily/weekly summary

## Watch Data (Redmi Watch 5 Lite)

Gateway: **Health Connect + custom Android app** — the only path with daily
steps, active calories, and sleep.

watch → Mi Fitness phone app (BLE) → Health Connect → custom Android gateway
app → bot's REST API → SQLite.

### The gateway app (Android, Kotlin)

- Reads Health Connect via Jetpack SDK (1.1.0 stable): `readRecords()` for
  sleep/workouts, `aggregate()` for steps (avoids double counting)
- Runs as a foreground service, syncs hourly
- Sideloadable — no Play Store approval needed
- Effort: ~1–2 days if you know Android, a week+ if not

### What you get

- Daily: steps, active calories, sleep
- Workouts: sessions with distance, calories
- NOT available (no Health Connect type): stress, VO2 max, sleep breathing
  quality
- Verify Mi Fitness exports sleep stages to Health Connect

### Phone-app prereqs

1. Watch bound in Mi Fitness; Health Connect installed (Android 14+ built-in)
2. Mi Fitness → Settings → Health Connect → enable data types
3. Health Connect → App permissions → Mi Fitness → grant all
4. Open Mi Fitness regularly so data pushes (watch has no WiFi)

### Flow

- Gateway app syncs Health Connect → bot API → SQLite (daily_stats, workouts)
- After every sync, bot posts a Discord update (steps so far, active calories,
  sleep)
- Morning: user confirms sleep in chat → sleep_log
- Bot answers trends: "you averaged 8k steps and 2h sleep this week"

## Profile

Isolated with its own terminal workspace. Receives watch data from the Health
Connect gateway app via a small REST endpoint — must be internet-reachable
from the phone (reverse proxy or VPN) and authenticated (token per install).
SQLite DB in profile data dir.
