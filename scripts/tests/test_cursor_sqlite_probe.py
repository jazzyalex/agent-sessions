import hashlib
import json
import sqlite3
from pathlib import Path

import pytest

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


def _proto(field: int, payload: bytes) -> bytes:
    assert len(payload) < 128
    return bytes([(field << 3) | 2, len(payload)]) + payload


def _write_acp_store(
    root: Path,
    *,
    root_meta_overrides: dict | None = None,
    sidecar: dict | None = None,
    include_blobs_table: bool = True,
    root_blob: bytes | None = None,
) -> Path:
    session_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    session_dir = root / "acp-sessions" / session_id
    session_dir.mkdir(parents=True)

    user_blob = _proto(1, b"synthetic user")
    user_id = hashlib.sha256(user_blob).digest()
    assistant_blob = _proto(1, b"synthetic assistant")
    assistant_id = hashlib.sha256(assistant_blob).digest()
    step_blob = _proto(1, assistant_id)
    step_id = hashlib.sha256(step_blob).digest()
    agent_turn = _proto(1, user_id) + _proto(2, step_id)
    turn_blob = _proto(1, agent_turn)
    turn_id = hashlib.sha256(turn_blob).digest()
    root_blob = root_blob if root_blob is not None else _proto(8, turn_id)
    root_id = hashlib.sha256(root_blob).digest()

    root_meta = {
        "agentId": session_id,
        "latestRootBlobId": root_id.hex(),
        "createdAt": 1_700_000_000,
        "name": "Synthetic ACP",
    }
    root_meta.update(root_meta_overrides or {})

    db = session_dir / "store.db"
    con = sqlite3.connect(db)
    try:
        con.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        if include_blobs_table:
            con.execute("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)")
        encoded = json.dumps(root_meta).encode("utf-8").hex()
        con.execute("INSERT INTO meta (key, value) VALUES ('0', ?)", (encoded,))
        if include_blobs_table:
            for blob_id, blob in (
                (root_id, root_blob),
                (turn_id, turn_blob),
                (user_id, user_blob),
                (step_id, step_blob),
                (assistant_id, assistant_blob),
            ):
                con.execute("INSERT INTO blobs (id, data) VALUES (?, ?)",
                            (blob_id.hex(), blob))
        con.commit()
    finally:
        con.close()

    if sidecar is not None:
        (session_dir / "meta.json").write_text(json.dumps(sidecar), encoding="utf-8")
    else:
        (session_dir / "meta.json").write_text(
            json.dumps({"schemaVersion": 1, "cwd": "/synthetic/project"}),
            encoding="utf-8",
        )
    return db


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
    assert result["schema_fingerprint"]["type_keys"]["meta"] == [
        "agentId",
        "createdAt",
        "isRunEverything",
        "lastUsedModel",
        "latestRootBlobId",
        "mode",
        "name",
    ]
    assert result["schema_fingerprint"]["key_types"]["agentId"] == "string"
    assert result["schema_fingerprint"]["key_types"]["createdAt"] == "number"
    assert result["error"] is None
    assert "agent-123" not in json.dumps(result)


def test_probe_rejects_meta_missing_required_agent_id(tmp_path):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "name": "New Agent",
        "createdAt": 1780432415748,
    })

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is False
    assert result["missing_required_keys"] == ["agentId"]


def test_probe_rejects_wrong_typed_agent_id(tmp_path):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "agentId": 123,
        "name": "New Agent",
        "createdAt": 1780432415748,
    })

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is False
    assert result["error"] == "invalid_required_types"
    assert result["invalid_required_types"] == ["agentId:string"]
    assert result["exit_code"] == 3


def test_probe_rejects_legacy_metadata_larger_than_budget(tmp_path, monkeypatch):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "agentId": "agent-123", "name": "New Agent", "createdAt": 1780432415748,
    })
    monkeypatch.setattr(cursor_sqlite_probe, "CHAT_MAX_META_HEX_CHARS", 1)

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is False
    assert result["error"] == "meta_size_limit"
    assert result["exit_code"] == 2


@pytest.mark.parametrize("created_at", ["1780432415748", True])
def test_probe_rejects_wrong_typed_created_at(tmp_path, created_at):
    db = tmp_path / ".cursor" / "chats" / "workspacehash" / "agent-123" / "store.db"
    _write_cursor_store_db(db, {
        "agentId": "agent-123",
        "name": "New Agent",
        "createdAt": created_at,
    })

    result = cursor_sqlite_probe.probe(db)

    assert result["ok"] is False
    assert result["error"] == "invalid_required_types"
    assert result["invalid_required_types"] == ["createdAt:number"]
    assert result["exit_code"] == 3


def test_acp_probe_validates_sqlite_metadata_and_protobuf_without_values(tmp_path):
    db = _write_acp_store(tmp_path)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is True
    fingerprint = result["schema_fingerprint"]
    assert fingerprint["table_columns"] == {
        "blobs": ["id", "data"],
        "meta": ["key", "value"],
    }
    assert fingerprint["root_meta_key_types"]["agentId"] == "string"
    assert fingerprint["sidecar_key_types"]["schemaVersion"] == "number"
    assert fingerprint["protobuf_wire_fields"] == {
        "agent_turn": ["1:2", "2:2"],
        "assistant_message": ["1:2"],
        "root": ["8:2"],
        "step": ["1:2"],
        "turn": ["1:2"],
        "user_message": ["1:2"],
    }
    serialized = json.dumps(result)
    assert "a1b2c3d4-e5f6-7890-abcd-ef1234567890" not in serialized
    assert "synthetic user" not in serialized
    assert str(tmp_path) not in serialized


def test_acp_probe_rejects_missing_required_blobs_table(tmp_path):
    db = _write_acp_store(tmp_path, include_blobs_table=False)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_sqlite_schema_mismatch"


def test_acp_probe_rejects_wrong_typed_required_root_metadata(tmp_path):
    db = _write_acp_store(tmp_path, root_meta_overrides={"agentId": 123})

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_agent_id_missing_or_wrong_type"


def test_acp_probe_rejects_missing_required_sidecar(tmp_path):
    db = _write_acp_store(tmp_path)
    (db.parent / "meta.json").unlink()

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_meta_sidecar_missing_or_not_regular"


def test_acp_probe_rejects_wrong_protobuf_wire_type(tmp_path):
    db = _write_acp_store(tmp_path, root_blob=b"\x43")

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_root_blob_missing_or_malformed"


def test_acp_probe_rejects_blob_larger_than_read_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_BLOB_BYTES", 1)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_blob_size_limit"


def test_acp_probe_rejects_cumulative_blob_bytes_over_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_TOTAL_BLOB_BYTES", 1)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_total_blob_size_limit"


def test_acp_probe_rejects_protobuf_field_count_over_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_PROTO_FIELDS", 0)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_protobuf_field_count_limit"


def test_acp_probe_rejects_reference_graph_larger_than_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_REFERENCES", 0)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_reference_count_limit"


def test_acp_probe_rejects_sidecar_larger_than_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_SIDECAR_BYTES", 1)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_meta_sidecar_size_limit"


def test_acp_probe_rejects_root_metadata_larger_than_budget(tmp_path, monkeypatch):
    db = _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_ROOT_META_HEX_CHARS", 1)

    result = cursor_sqlite_probe.probe_acp(db)

    assert result["ok"] is False
    assert result["error"] == "acp_root_meta_size_limit"


def test_acp_root_probe_checks_synthetic_store_without_disclosing_path(tmp_path):
    _write_acp_store(tmp_path)

    result = cursor_sqlite_probe.probe_acp_root(tmp_path / "acp-sessions")

    assert result["ok"] is True
    assert result["status"] == "checked"
    assert result["sample_count"] == 1
    assert str(tmp_path) not in json.dumps(result)


def test_acp_root_probe_rejects_discovery_larger_than_budget(tmp_path, monkeypatch):
    _write_acp_store(tmp_path)
    monkeypatch.setattr(cursor_sqlite_probe, "ACP_MAX_DISCOVERY_ENTRIES", 0)

    result = cursor_sqlite_probe.probe_acp_root(tmp_path / "acp-sessions")

    assert result["ok"] is False
    assert result["error"] == "acp_discovery_entry_limit"


def test_main_accepts_acp_only_home_without_disclosing_values(tmp_path, monkeypatch, capsys):
    _write_acp_store(tmp_path / ".cursor")
    monkeypatch.setenv("HOME", str(tmp_path))

    exit_code = cursor_sqlite_probe.main()

    result = json.loads(capsys.readouterr().out)
    assert exit_code == 0
    assert result["ok"] is True
    assert result["chat"]["status"] == "not_found"
    assert result["acp"]["status"] == "checked"
    serialized = json.dumps(result)
    assert str(tmp_path) not in serialized
    assert "synthetic user" not in serialized


def test_main_rejects_legacy_chat_discovery_over_budget(tmp_path, monkeypatch, capsys):
    chat_root = tmp_path / ".cursor" / "chats" / "workspacehash"
    chat_root.mkdir(parents=True)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(cursor_sqlite_probe, "CHAT_MAX_DISCOVERY_ENTRIES", 0)

    exit_code = cursor_sqlite_probe.main()

    result = json.loads(capsys.readouterr().out)
    assert exit_code == 2
    assert result["error"] == "chat_probe_failed"
    assert result["chat"]["error"] == "chat_discovery_entry_limit"


def test_main_fails_weekly_probe_for_wrong_typed_acp_metadata(tmp_path, monkeypatch, capsys):
    _write_acp_store(tmp_path / ".cursor", root_meta_overrides={"agentId": 123})
    monkeypatch.setenv("HOME", str(tmp_path))

    exit_code = cursor_sqlite_probe.main()

    result = json.loads(capsys.readouterr().out)
    assert exit_code == 3
    assert result["ok"] is False
    assert result["error"] == "acp_probe_failed"
    assert result["acp"]["error"] == "acp_agent_id_missing_or_wrong_type"
    assert str(tmp_path) not in json.dumps(result)
