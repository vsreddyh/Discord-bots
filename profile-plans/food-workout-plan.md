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

## SQLite Schema

- `profile` (weight_kg, weight_goal_kg, height_cm, age, activity_level)
- `foods` (name, kcal, protein_g, carbs_g, fat_g, fiber_g per 100g, source)
- `meal_items` (meal_id, food_id, grams)
- `meals` (date, type)
- `workouts` (date, type, duration, notes) — from Health Connect
- `daily_stats` (date, steps, active_calories)
- `sleep_log` (date, sleep_start, wake_time, hours, quality) — gateway
  auto-fills hours, user confirms/annotates quality in the morning
- `targets` (protein_g, carbs_g, fat_g, fiber_g, kcal) — editable in chat

Python helper script: add meal, log weight/sleep, sync watch data,
fix/remove meals, daily/weekly summary.

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

watch → Mi Fitness (BLE) → Health Connect → gateway app → bot REST API → SQLite.

- Reads Health Connect via Jetpack SDK 1.1.0 (`readRecords()` for
  sleep/workouts, `aggregate()` for steps); foreground service, hourly sync;
  sideloadable
- Provides daily steps, active calories, sleep, workouts (distance, calories)
- NOT available: stress, VO2 max, sleep breathing quality
- Prereqs: watch bound in Mi Fitness, Health Connect data types enabled,
  permissions granted, Mi Fitness opened regularly (watch has no WiFi)

Flow: gateway syncs → bot posts Discord update (steps, active calories, sleep);
morning sleep confirmation in chat → `sleep_log`.

## Profile

Isolated workspace. REST endpoint for the gateway app — LAN reachable (or local
reverse proxy), token per install. SQLite DB in profile data dir.
