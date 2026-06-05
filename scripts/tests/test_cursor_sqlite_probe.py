import json
import sqlite3
from pathlib import Path

import cursor_sqlite_probe


def _write_cursor_store_db(path: Path, meta: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    try:
        con.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        encoded = json.dumps(meta).encode("utf-8").hex()
        con.execute("INSERT INTO meta (key, value) VALUES ('0', ?)", (encoded,))
        con.commit()
    finally:
        con.close()


def test_probe_reports_cursor_desktop_agent_window_metadata(tmp_path):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "agentId": "agent-123",
        "name": "New Agent",
        "createdAt": 1780432415748,
        "mode": "search",
        "lastUsedModel": "gpt-5.5",
        "latestRootBlobId": "blob-1",
        "isRunEverything": False,
    })

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is True
    assert result["agent_id"] == "agent-123"
    assert result["created_at_utc"] == "2026-06-02T20:33:35.748000+00:00"
    assert result["mode"] == "search"
    assert result["last_used_model"] == "gpt-5.5"
    assert result["schema_fingerprint"]["type_keys"]["meta"] == [
        "agentId",
        "createdAt",
        "isRunEverything",
        "lastUsedModel",
        "latestRootBlobId",
        "mode",
        "name",
    ]
    assert result["error"] is None


def test_probe_rejects_meta_missing_required_agent_id(tmp_path):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "name": "New Agent",
        "createdAt": 1780432415748,
    })

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is False
    assert "agentId" in result["error"]
