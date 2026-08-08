"""Health Connect sync endpoint for the food bot.

Accepts POSTs from the Health Gateway Android app and persists to the
shared SQLite DB (profiles/food/data/health.db) that the bot also reads.

Auth: per-install tokens via `Authorization: Bearer <token>`.
HEALTH_API_TOKENS is a comma-separated list (one token per install).
"""

from __future__ import annotations

import logging
import os
import sqlite3
from datetime import datetime, timezone
from typing import Optional

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("health-api")

app = FastAPI(title="Health Sync API")

DB_PATH = os.environ.get("HEALTH_DB_PATH", "/data/health.db")
_raw_tokens = os.environ.get("HEALTH_API_TOKENS", "") or os.environ.get("HEALTH_SYNC_TOKEN", "")
TOKENS = {t.strip() for t in _raw_tokens.split(",") if t.strip()}


# ── Schema mirrors profiles/*/data SQLite schema from the bot plan ──
SCHEMA = """
CREATE TABLE IF NOT EXISTS daily_stats (
    date            TEXT PRIMARY KEY,
    steps           INTEGER,
    active_calories REAL,
    synced_at       TEXT
);
CREATE TABLE IF NOT EXISTS sleep_log (
    date        TEXT,
    sleep_start TEXT,
    wake_time   TEXT,
    hours       REAL,
    quality     TEXT,
    synced_at   TEXT
);
CREATE TABLE IF NOT EXISTS workouts (
    date     TEXT,
    type     TEXT,
    duration INTEGER,
    notes    TEXT,
    synced_at TEXT
);
"""


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


def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(SCHEMA)
    return conn


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

    conn = _connect()
    try:
        # daily_stats: upsert the day's totals
        if payload.steps is not None or payload.activeCaloriesKcal is not None:
            existing = conn.execute(
                "SELECT steps, active_calories FROM daily_stats WHERE date = ?",
                (stats_date,),
            ).fetchone()
            steps = existing[0] if existing else None
            cal = existing[1] if existing else None
            if payload.steps is not None:
                steps = payload.steps
            if payload.activeCaloriesKcal is not None:
                cal = payload.activeCaloriesKcal
            conn.execute(
                """
                INSERT INTO daily_stats (date, steps, active_calories, synced_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET
                    steps = excluded.steps,
                    active_calories = excluded.active_calories,
                    synced_at = excluded.synced_at
                """,
                (stats_date, steps, cal, synced_at),
            )

        # sleep_log: append new sessions (dedupe on the exact start timestamp)
        for s in payload.sleep:
            wake_date = _local_date(s.endIso)
            dup = conn.execute(
                "SELECT 1 FROM sleep_log WHERE sleep_start = ?", (s.startIso,)
            ).fetchone()
            if dup:
                continue
            conn.execute(
                """
                INSERT INTO sleep_log
                    (date, sleep_start, wake_time, hours, synced_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    wake_date,
                    s.startIso,
                    s.endIso,
                    round(s.totalMinutes / 60.0, 2),
                    synced_at,
                ),
            )

        # workouts: append new sessions (dedupe on start + type)
        for w in payload.workouts:
            duration = _minutes_between(w.startIso, w.endIso)
            notes = _workout_notes(w)
            dup = conn.execute(
                "SELECT 1 FROM workouts WHERE date = ? AND type = ? AND duration = ?",
                (_local_date(w.startIso), w.type, duration),
            ).fetchone()
            if dup:
                continue
            conn.execute(
                """
                INSERT INTO workouts
                    (date, type, duration, notes, synced_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (_local_date(w.startIso), w.type, duration, notes, synced_at),
            )

        conn.commit()
    finally:
        conn.close()

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
