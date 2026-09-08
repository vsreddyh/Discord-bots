#!/usr/bin/env python3
"""Health-check — cal-in + cal-out + weight MCP server.

Storage: MongoDB (hc_meals, hc_weight NEVER pruned, hc_days).
Run (stdio): pip install -r requirements.txt; python server.py
"""
from __future__ import annotations

import datetime as dti
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv

load_dotenv()

try:
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP("health-check")
except ImportError:
    from mcp.server.mcpserver import MCPServer

    mcp = MCPServer("health-check")

from health_check.store import StoreError, from_env

store = from_env()


def _err(e: Exception) -> dict:
    return {"ok": False, "error": str(e)}


def _day(date: str) -> str:
    return (date or "").strip() or dti.date.today().isoformat()


@mcp.tool()
def log_meal(description: str, items: list, date: str = "") -> dict:
    """Log a meal. Agent parses user text into items[{name, qty?, kcal, protein,
    carbs, fat, fiber}] — MCP validates and names any missing macro field."""
    try:
        return {"ok": True, "meal": store.log_meal(_day(date), description, items)}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def fix_last_meal(description: str, items: list) -> dict:
    """Replace the most recent meal's items with corrected items."""
    try:
        meal = store.fix_last_meal(description, items)
        if not meal:
            return {"ok": False, "error": "No meals to fix."}
        return {"ok": True, "meal": meal}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def query_meals(start: str, end: str) -> dict:
    """List meals between start/end dates (YYYY-MM-DD inclusive)."""
    try:
        rows = store.query_meals(start, end)
        return {"ok": True, "count": len(rows), "meals": rows}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def delete_meals(date: str = "") -> dict:
    """Delete meals for one date (YYYY-MM-DD, default today)."""
    try:
        return {"ok": True, "deleted": store.delete_meals(_day(date))}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def log_weight(kg: float, date: str = "") -> dict:
    """Log body weight in kg (upserts one row per date). Never pruned."""
    try:
        return {"ok": True, "weight": store.log_weight(_day(date), float(kg))}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def log_sleep(hours: float, date: str = "") -> dict:
    """Log sleep hours. Date = morning of wake-up."""
    try:
        return {"ok": True, "sleep": store.log_sleep(_day(date), float(hours))}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def log_workout(type: str, minutes: float, kcal: float = 0, date: str = "") -> dict:
    """Log a workout (type e.g. run/lift/walk, minutes, optional kcal burn)."""
    try:
        return {"ok": True, "workout": store.log_workout(_day(date), type, float(minutes), float(kcal))}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def daily_summary(date: str = "") -> dict:
    """Daily recap: cal-in totals vs cal-out (workouts + active) + weight/sleep/steps."""
    try:
        return {"ok": True, "summary": store.daily_summary(_day(date))}
    except (StoreError, Exception) as e:
        return _err(e)


@mcp.tool()
def prune_old(days: int = 30, dry_run: bool = True) -> dict:
    """Prune hc_meals/hc_days older than `days`. NEVER touches hc_weight.
    dry_run=true (default) only reports counts."""
    try:
        return {"ok": True, "dry_run": dry_run, **store.prune(days=days, dry_run=dry_run)}
    except (StoreError, Exception) as e:
        return _err(e)


if __name__ == "__main__":
    mcp.run(transport="stdio")
