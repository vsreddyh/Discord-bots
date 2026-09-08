"""Shared MongoDB helpers for Hermes MCPs (cookbook, health-check).

Env: MONGODB_URI (required), MONGODB_DB (default: hermes).
Client + db are cached per process.
"""
from __future__ import annotations

import os

_client = None
_db = None


def get_db():
    global _client, _db
    if _db is not None:
        return _db
    uri = os.environ.get("MONGODB_URI", "").strip()
    if not uri:
        raise ValueError("MONGODB_URI is not set.")
    from pymongo import MongoClient

    _client = MongoClient(uri, serverSelectionTimeoutMS=8000, retryWrites=True)
    db_name = os.environ.get("MONGODB_DB", "hermes").strip() or "hermes"
    _db = _client[db_name]
    return _db


def col(name: str):
    return get_db()[name]


def from_env_db_name() -> str:
    return os.environ.get("MONGODB_DB", "hermes").strip() or "hermes"
