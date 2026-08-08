"""Health Connect sync endpoint for the food bot.

Accepts POSTs from the Health Gateway Android app and persists to the
shared remote MongoDB collections that the food bot also reads
(food_daily_stats / food_sleep_log / food_workouts).

Auth: per-install tokens via `Authorization: Bearer <token>`.
HEALTH_API_TOKENS is a comma-separated list (one token per install).

Env:
  MONGODB_URI  connection string (required)
  MONGODB_DB   database name (default: hermes)
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Optional

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

try:
    from pymongo import MongoClient
except ImportError:
    MongoClient = None

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("health-api")

app = FastAPI(title="Health Sync API")

_raw_tokens = os.environ.get("HEALTH_API_TOKENS", "") or os.environ.get("HEALTH_SYNC_TOKEN", "")
TOKENS = {t.strip() for t in _raw_tokens.split(",") if t.strip()}


def _get_db():
    if MongoClient is None:
        raise RuntimeError("pymongo not installed")
    uri = os.environ.get("MONGODB_URI", "").strip()
    if not uri:
        raise RuntimeError("MONGODB_URI not set")
    db_name = os.environ.get("MONGODB_DB", "hermes").strip() or "hermes"
    return MongoClient(uri, serverSelectionTimeoutMS=8000)[db_name]


# ── Models matching the Android app's HealthSyncPayload ──
class SleepEntry(BaseModel):
    startIso: str
    endIso: str
    totalMinutes: int
    stages: dict[str, int] = Field(default_factory=dict)


class WorkoutEntry(BaseModel):
    startIso: str
    endIso: str
    title: str = "Workout"
    type: str = "WORKOUT"
    distanceMeters: Optional[float] = None
    caloriesKcal: Optional[float] = None


class HealthSyncPayload(BaseModel):
    device: str = "Redmi Watch 5 Lite"
    syncedAtIso: str
    steps: Optional[int] = None
    activeCaloriesKcal: Optional[float] = None
    sleep: list[SleepEntry] = Field(default_factory=list)
    workouts: list[WorkoutEntry] = Field(default_factory=list)


def _local_date(iso: str) -> str:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.astimezone().date().isoformat()
    except Exception:
        return iso[:10]


def _authorize(authorization: Optional[str]) -> None:
    if not TOKENS:
        logger.warning("HEALTH_API_TOKENS not set — rejecting all requests")
        raise HTTPException(status_code=503, detail="server not configured with tokens")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization[7:].strip()
    if token not in TOKENS:
        raise HTTPException(status_code=401, detail="invalid token")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/api/health/sync")
async def sync(payload: HealthSyncPayload, authorization: Optional[str] = Header(None)):
    _authorize(authorization)

    synced_at = datetime.now(timezone.utc).isoformat()
    stats_date = _local_date(payload.syncedAtIso)

    db = _get_db()
    daily = db["food_daily_stats"]
    sleep_c = db["food_sleep_log"]
    workout_c = db["food_workouts"]

    # daily_stats: merge the day's totals (steps/calories) into one doc per date.
    if payload.steps is not None or payload.activeCaloriesKcal is not None:
        existing = daily.find_one({"date": stats_date})
        steps = existing.get("steps") if existing else None
        cal = existing.get("active_calories") if existing else None
        if payload.steps is not None:
            steps = payload.steps
        if payload.activeCaloriesKcal is not None:
            cal = payload.activeCaloriesKcal
        daily.update_one(
            {"date": stats_date},
            {"$set": {"steps": steps, "active_calories": cal, "synced_at": synced_at}},
            upsert=True,
        )

    # sleep_log: append new sessions (dedupe on the exact start timestamp).
    for s in payload.sleep:
        wake_date = _local_date(s.endIso)
        dup = sleep_c.find_one({"sleep_start": s.startIso})
        if dup:
            continue
        sleep_c.insert_one({
            "date": wake_date,
            "sleep_start": s.startIso,
            "wake_time": s.endIso,
            "hours": round(s.totalMinutes / 60.0, 2),
            "synced_at": synced_at,
        })

    # workouts: append new sessions (dedupe on start + type).
    for w in payload.workouts:
        duration = _minutes_between(w.startIso, w.endIso)
        notes = _workout_notes(w)
        dup = workout_c.find_one({
            "date": _local_date(w.startIso),
            "type": w.type,
            "duration": duration,
        })
        if dup:
            continue
        workout_c.insert_one({
            "date": _local_date(w.startIso),
            "type": w.type,
            "duration": duration,
            "notes": notes,
            "synced_at": synced_at,
        })

    logger.info(
        "synced device=%s steps=%s calories=%s sleep=%d workouts=%d",
        payload.device, payload.steps, payload.activeCaloriesKcal,
        len(payload.sleep), len(payload.workouts),
    )

    await _post_discord_update(payload)

    return {"status": "ok", "synced_at": synced_at}


async def _post_discord_update(payload: HealthSyncPayload) -> None:
    """Post a summary to the bot's Discord home channel (best-effort).

    Reads DISCORD_BOT_TOKEN / DISCORD_HOME_CHANNEL from the environment.
    Failures are logged, never surfaced to the Android app (2xx already sent).
    """
    token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    channel = os.environ.get("DISCORD_HOME_CHANNEL", "").strip()
    if not token or not channel:
        logger.info("DISCORD_BOT_TOKEN / DISCORD_HOME_CHANNEL not set — skipping Discord post")
        return

    lines = [":watch: **Health sync received**"]
    if payload.steps is not None:
        lines.append(f"Steps: {payload.steps:,}")
    if payload.activeCaloriesKcal is not None:
        lines.append(f"Active calories: {payload.activeCaloriesKcal:.0f} kcal")
    for s in payload.sleep:
        lines.append(f"Sleep: {s.totalMinutes / 60:.1f} h ({s.startIso} → {s.endIso})")
    for w in payload.workouts:
        dist = f", {w.distanceMeters:.0f} m" if w.distanceMeters is not None else ""
        lines.append(f"Workout: {w.title} ({w.type}{dist})")
    if len(lines) == 1:
        lines.append("No health data yet.")

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"https://discord.com/api/v10/channels/{channel}/messages",
                headers={"Authorization": f"Bot {token}"},
                json={"content": "\n".join(lines)},
            )
        if resp.status_code >= 400:
            logger.warning("Discord post failed: HTTP %d %s", resp.status_code, resp.text[:200])
    except Exception as e:
        logger.warning("Discord post failed: %s", e)


def _minutes_between(start_iso: str, end_iso: str) -> Optional[int]:
    try:
        s = datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
        e = datetime.fromisoformat(end_iso.replace("Z", "+00:00"))
        return max(1, int((e - s).total_seconds() // 60))
    except Exception:
        return None


def _workout_notes(w: WorkoutEntry) -> str:
    parts = [w.title]
    if w.distanceMeters is not None:
        parts.append(f"{w.distanceMeters:.0f}m")
    if w.caloriesKcal is not None:
        parts.append(f"{w.caloriesKcal:.0f}kcal")
    return " · ".join(parts)
