"""Persistence. SQLite by default so the service runs with nothing installed;
set DATABASE_URL to point at Postgres for anything beyond a demo. The same SQL
lives in sql/schema.sql for Supabase, with row level security.
"""
from __future__ import annotations

import os
import secrets
import sqlite3
import json
from contextlib import contextmanager
from datetime import datetime, timezone

DB_PATH = os.getenv("GEOX_DB", os.path.join(os.path.dirname(__file__), "geox.sqlite3"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS suggested_sites (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       TEXT,
    email         TEXT,
    name          TEXT    NOT NULL,
    latitude      REAL    NOT NULL,
    longitude     REAL    NOT NULL,
    category      TEXT,
    why           TEXT    NOT NULL,
    status        TEXT    NOT NULL DEFAULT 'pending',
    created_at    TEXT    NOT NULL
);
CREATE TABLE IF NOT EXISTS shortlists (
    code          TEXT PRIMARY KEY,
    user_id       TEXT,
    target_id     TEXT,
    site_ids      TEXT    NOT NULL,
    created_at    TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_suggested_status ON suggested_sites(status);
"""


@contextmanager
def conn():
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    try:
        yield c
        c.commit()
    finally:
        c.close()


def init() -> None:
    with conn() as c:
        c.executescript(SCHEMA)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --------------------------------------------------------------- suggestions
def add_suggestion(*, name: str, latitude: float, longitude: float, why: str,
                   category: str | None, user_id: str | None,
                   email: str | None) -> dict:
    with conn() as c:
        cur = c.execute(
            "INSERT INTO suggested_sites"
            " (user_id,email,name,latitude,longitude,category,why,status,created_at)"
            " VALUES (?,?,?,?,?,?,?,'pending',?)",
            (user_id, email, name, latitude, longitude, category, why, _now()))
        new_id = cur.lastrowid
    # read it back only after the block above has committed; a second connection
    # cannot see an uncommitted row
    return get_suggestion(new_id)


def get_suggestion(sid: int) -> dict | None:
    with conn() as c:
        r = c.execute("SELECT * FROM suggested_sites WHERE id=?", (sid,)).fetchone()
        return dict(r) if r else None


def list_suggestions(status: str | None = None, limit: int = 100) -> list[dict]:
    q = "SELECT * FROM suggested_sites"
    args: tuple = ()
    if status:
        q += " WHERE status=?"
        args = (status,)
    q += " ORDER BY created_at DESC LIMIT ?"
    with conn() as c:
        return [dict(r) for r in c.execute(q, args + (limit,)).fetchall()]


def set_status(sid: int, status: str) -> dict | None:
    with conn() as c:
        c.execute("UPDATE suggested_sites SET status=? WHERE id=?", (status, sid))
    return get_suggestion(sid)


# ---------------------------------------------------------------- shortlists
def save_shortlist(site_ids: list[str], target_id: str | None,
                   user_id: str | None) -> dict:
    code = secrets.token_urlsafe(6)
    with conn() as c:
        c.execute(
            "INSERT INTO shortlists (code,user_id,target_id,site_ids,created_at)"
            " VALUES (?,?,?,?,?)",
            (code, user_id, target_id, json.dumps(site_ids), _now()))
    return {"code": code, "target_id": target_id, "site_ids": site_ids}


def get_shortlist(code: str) -> dict | None:
    with conn() as c:
        r = c.execute("SELECT * FROM shortlists WHERE code=?", (code,)).fetchone()
    if not r:
        return None
    d = dict(r)
    d["site_ids"] = json.loads(d["site_ids"])
    return d
