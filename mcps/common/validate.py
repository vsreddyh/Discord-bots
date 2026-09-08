"""Shared validators for Hermes MCPs."""
from __future__ import annotations

import datetime as dt
import re

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MACRO_KEYS = ("kcal", "protein", "carbs", "fat", "fiber")


class StoreError(ValueError):
    pass


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def check_day(day: str) -> str:
    day = (day or "").strip()
    if not DATE_RE.match(day):
        raise StoreError(f"bad date '{day}' — use YYYY-MM-DD")
    try:
        dt.date.fromisoformat(day)
    except ValueError:
        raise StoreError(f"bad date '{day}' — not a real calendar date")
    return day


def check_macros(d: dict, ctx: str = "item") -> dict:
    for k in MACRO_KEYS:
        if k not in d:
            raise StoreError(f"{ctx} missing '{k}' — ask the user for it")
        try:
            v = float(d[k])
        except (TypeError, ValueError):
            raise StoreError(f"{ctx} field '{k}' must be a number")
        if v < 0:
            raise StoreError(f"{ctx} field '{k}' must be >= 0")
    return d


def sum_totals(items: list[dict]) -> dict:
    return {k: round(sum(float(i.get(k, 0)) for i in items), 1) for k in MACRO_KEYS}
