#!/usr/bin/env python3
"""
cursor_sqlite_probe.py — Lightweight health check for Cursor SQLite chat databases.

Finds the newest store.db under ~/.cursor/chats/*/*/store.db, opens it,
verifies the meta table exists and returns parseable JSON metadata.

Exit codes:
  0 — ok
  1 — no store.db found
  2 — meta table missing or unreadable
  3 — unexpected schema (required keys absent)
"""
import glob
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


REQUIRED_META_KEYS = {"agentId", "name", "createdAt"}


def _epoch_ms_to_utc_iso(value) -> str | None:
    try:
        ms = float(value)
    except (TypeError, ValueError):
        return None
    if ms <= 0:
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()


def find_newest_store_db() -> Path | None:
    pattern = str(Path.home() / ".cursor" / "chats" / "*" / "*" / "store.db")
    candidates = glob.glob(pattern)
    if not candidates:
        return None
    return Path(max(candidates, key=os.path.getmtime))


def probe(db_path: Path) -> dict:
    try:
        db_mtime = db_path.stat().st_mtime
    except OSError:
        db_mtime = None

    try:
        con = sqlite3.connect(str(db_path))
    except Exception as e:
        return {"ok": False, "db_path": str(db_path), "error": f"open_failed: {e}", "exit_code": 2}

    try:
        cur = con.execute("SELECT value FROM meta WHERE key='0' LIMIT 1")
        row = cur.fetchone()
    except Exception as e:
        con.close()
        return {"ok": False, "db_path": str(db_path), "error": f"meta_read_failed: {e}", "exit_code": 2}

    con.close()

    if row is None:
        return {"ok": False, "db_path": str(db_path), "error": "meta_key_0_missing", "exit_code": 2}

    hex_value = row[0]
    try:
        raw = bytes.fromhex(hex_value).decode("utf-8")
        meta = json.loads(raw)
    except Exception as e:
        return {"ok": False, "db_path": str(db_path), "error": f"meta_decode_failed: {e}", "exit_code": 2}

    if not isinstance(meta, dict):
        return {"ok": False, "db_path": str(db_path), "error": "meta_not_dict", "exit_code": 3}

    meta_keys = sorted(meta.keys())
    missing = REQUIRED_META_KEYS - set(meta_keys)
    if missing:
        return {
            "ok": False,
            "db_path": str(db_path),
            "meta_keys": meta_keys,
            "error": f"missing_required_keys: {sorted(missing)}",
            "exit_code": 3,
        }

    agent_id = meta.get("agentId")
    created_at = meta.get("createdAt")
    return {
        "ok": True,
        "db_path": str(db_path),
        "db_mtime_epoch": db_mtime,
        "db_mtime_utc": datetime.fromtimestamp(db_mtime, tz=timezone.utc).isoformat() if db_mtime else None,
        "agent_id": agent_id if isinstance(agent_id, str) else None,
        "created_at_epoch_ms": created_at if isinstance(created_at, (int, float)) else None,
        "created_at_utc": _epoch_ms_to_utc_iso(created_at),
        "mode": meta.get("mode") if isinstance(meta.get("mode"), str) else None,
        "name": meta.get("name") if isinstance(meta.get("name"), str) else None,
        "last_used_model": meta.get("lastUsedModel") if isinstance(meta.get("lastUsedModel"), str) else None,
        "meta_keys": meta_keys,
        "schema_fingerprint": {
            "type_counts": {"meta": 1},
            "type_keys": {"meta": meta_keys},
        },
        "error": None,
        "exit_code": 0,
    }


def main() -> int:
    db_path = find_newest_store_db()
    if db_path is None:
        print(json.dumps({"ok": False, "db_path": None, "error": "no_store_db_found"}))
        return 1

    result = probe(db_path)
    exit_code = result.pop("exit_code")
    print(json.dumps(result))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
