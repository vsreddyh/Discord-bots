# Food & Workout Bot

Hermes Agent profile: food, weight, sleep, and workout tracking.

## Skill

Uses Hermes' built-in `official/health/fitness-nutrition` skill (install into
this profile via `hermes skills install official/health/fitness-nutrition`):

- USDA FoodData Central food lookup — macros + calories, 380k foods
  (`USDA_API_KEY` env var; `DEMO_KEY` works without signup)
- TDEE, BMI, macro splits, 1RM, body fat — `scripts/body_calc.py`, pure Python
- wger exercise lookup for workouts

Custom build adds what the skill lacks: persistent logging, watch data,
chat-triggered summaries.

## Scope

- Track weight, calories, macros (kcal, protein, carbs, fat, fiber)
- Out of scope: micros, barcode, photo logging, water, reminders, weekly reports

## MongoDB Schema

Remote MongoDB (`hermes` DB) for prod; temporary local `mongodb:27017` (no volume) for dev via `HERMES_ENV=dev`. No local SQLite.

- `food_daily_stats` (date, steps, active_calories) — one doc per date
- `food_sleep_log` (date, sleep_start, wake_time, hours) — gateway auto-fills hours
- `food_workouts` (date, type, duration, notes) — from Health Connect
- `food_weight` (date, weight_kg) — **never pruned by retention**
- `food` lookups via USDA (`foods` cache conceptually now in-memory/LLM, not SQLite `foods`/`meal_items`)

Python helper: `tools/mongo.py` + `tools/retention.py` (30d prune for date rows, weight untouched).

## Food Lookup

- USDA via the skill (search by name, scale per-100g to portion)
- Unknown/not found → LLM knowledge + user confirm, saved as `user` food
- Results cached in `foods`; repeats hit cache only

## Targets

- kcal: TDEE from the skill's `body_calc.py`; adaptive — each `weight` entry
  recalibrates toward the trend
- weight goal: 65 kg; calorie goal adjusts deficit/surplus toward it
- protein 1.6–2.2 g/kg, fat 25–35% kcal, carbs remainder, fiber 14 g/1000 kcal

## Watch Data (Redmi Watch 5 Lite)

Health Connect + custom Android gateway app:

watch → Mi Fitness (BLE) → Health Connect → gateway app → health-api (:8001) → MongoDB.

- Reads Health Connect via Jetpack SDK 1.1.0 (`readRecords()` for
  sleep/workouts, `aggregate()` for steps); foreground service, hourly sync;
  sideloadable
- Provides daily steps, active calories, sleep, workouts (distance, calories)
- NOT available: stress, VO2 max, sleep breathing quality
- Prereqs: watch bound in Mi Fitness, Health Connect data types enabled,
  permissions granted, Mi Fitness opened regularly (watch has no WiFi)

### Android app (built)

`android/health-gateway/` — Kotlin, Jetpack Compose, Health Connect SDK 1.1.0.
Build: `./gradlew assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`.
Verified on emulator (install, launch, hourly WorkManager schedule, no crash).

- Reads: steps + active calories (aggregate), sleep stages + workout sessions
  (readRecords); workouts' distance/calories via Distance/TotalCaloriesBurned
  records keyed by metadata.id
- Flow: hourly `SyncWorker` (foreground dataSync) + boot restart via
  `BootReceiver`; manual "Sync now" in the UI
- Config stored in SharedPreferences: server URL + per-install auth token
- POSTs to `POST {server}/api/health/sync` with `Authorization: Bearer {token}`

Request body (JSON):

```json
{
  "device": "Redmi Watch 5 Lite",
  "syncedAtIso": "2026-08-08T12:00:00Z",
  "steps": 12345,
  "activeCaloriesKcal": 456.7,
  "sleep": [
    {
      "startIso": "2026-08-08T22:00:00Z",
      "endIso": "2026-08-08T06:30:00Z",
      "totalMinutes": 510,
      "stages": { "SLEEPING": 300, "DEEP": 120, "REM": 90 }
    }
  ],
  "workouts": [
    {
      "startIso": "2026-08-08T07:00:00Z",
      "endIso": "2026-08-08T07:45:00Z",
      "title": "Morning Walk",
      "type": "WALKING",
      "distanceMeters": 3500.0,
      "caloriesKcal": 180.0
    }
  ]
}
```

Bot (health-api) must accept this and persist to MongoDB; respond 2xx. App treats non-2xx or
network failure as sync failure (retry next hour). `steps`/`activeCaloriesKcal`
are null before the first Health Connect read.

Flow: gateway syncs → bot posts Discord update (steps, active calories, sleep);
morning sleep confirmation in chat → `sleep_log`.

## Profile

Isolated workspace (`/workspace/food`). REST endpoint via `health-api` (:8001), token per install. Remote MongoDB (`food_*`), retention prunes date rows >30d (weight never).

### Discord identity

- Bot name: **Saitama**
- Home channel: `1535613331610669117` (via `DISCORD_HOME_CHANNEL` /
  `channel_skill_bindings`)
- Token: per-profile `.env`, git-ignored — never commit it.
