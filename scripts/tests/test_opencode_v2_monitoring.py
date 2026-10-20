"""OpenCode 2.x monitoring: session_v2 + session_message fingerprinting.

OpenCode 2.x keeps the v1 session/message/part tables in opencode.db, frozen,
and writes new sessions only to session_v2/session_message. The weekly and
prebump fingerprints must sample the store being written, and the committed
sqlite_v2 fixture must describe it in the same buckets.
"""
import json
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch  # noqa: E402

FIXTURE_ROOT = REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "opencode" / "sqlite_v2"


def _write_db(path: Path, *, v1_updated: int, v2_updated: int, extra_assistant_key: str | None = None) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
                title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER,
                time_archived INTEGER, summary_additions INTEGER, summary_deletions INTEGER,
                summary_files INTEGER, summary_diffs TEXT
            );
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, project_id TEXT, slug TEXT, directory TEXT, title TEXT,
                version TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT
            );
            """
        )
        conn.execute(
            "INSERT INTO session VALUES ('ses_v1','p',NULL,'s','/tmp','t','1.19.3',1,?,NULL,NULL,NULL,NULL,NULL)",
            (v1_updated,),
        )
        conn.execute("INSERT INTO message VALUES ('msg_v1','ses_v1',1,'{\"role\":\"user\"}')")
        conn.execute(
            "INSERT INTO session_v2 VALUES ('ses_v2','p','s','/tmp','t','2.1.1','{\"id\":\"m\"}',1,?,NULL)",
            (v2_updated,),
        )
        assistant = {
            "time": {"created": 1, "completed": 2},
            "agent": "build",
            "model": {"id": "m", "providerID": "p"},
            "content": [
                {"type": "text", "text": "hi"},
                {"type": "tool", "id": "c1", "name": "shell",
                 "state": {"status": "completed", "input": {"command": "pwd"},
                           "content": [{"type": "text", "text": "/tmp"}]},
                 "time": {"created": 1, "completed": 2}},
            ],
            "finish": "stop",
            "tokens": {"input": 1, "output": 1, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        }
        if extra_assistant_key:
            assistant[extra_assistant_key] = True
        rows = [
            ("msg_u", "user", 0, {"time": {"created": 1}, "text": "pwd please", "files": [], "agents": []}),
            ("msg_a", "assistant", 1, assistant),
            ("msg_i", "idle", 2, {"time": {"created": 3}, "outcome": "succeeded"}),
        ]
        for row_id, row_type, seq, data in rows:
            conn.execute(
                "INSERT INTO session_message VALUES (?, 'ses_v2', ?, ?, 1, 1, ?)",
                (row_id, row_type, seq, json.dumps(data)),
            )
        conn.commit()
    finally:
        conn.close()


def test_v2_store_is_sampled_when_it_holds_the_newest_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)

    fp = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert fp["store"] == "session_v2"
    assert fp["session_version"] == "2.1.1"
    assert fp["message_rows_parsed"] == 3
    keys = fp["type_keys"]
    assert "session_message.assistant" in keys
    assert keys["session_message.assistant.content.tool"] == ["id", "name", "state", "time", "type"]
    assert keys["session_message.assistant.tool_state.completed"] == ["content", "input", "status"]
    assert keys["session_message.assistant.tokens"] == ["cache", "input", "output", "reasoning"]
    assert "session_message.idle" in keys
    assert not any(k.startswith("message.") or k.startswith("part.") for k in keys), "v1 rows must not be mixed in"


def test_v1_store_is_sampled_when_a_1x_build_wrote_the_newest_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=300, v2_updated=200)

    fp = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert "store" not in fp
    assert "session" in fp["type_keys"]
    assert "message.user" in fp["type_keys"]


def test_committed_v2_fixture_matches_a_clean_v2_sample(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fixtures = sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json"))
    assert len(fixtures) == 7

    baseline = agent_watch._baseline_type_keys_for_agent("opencode", fixtures)
    sample = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    for bucket, keys in sample["type_keys"].items():
        if bucket == "session_v2":
            continue  # the synthetic test table has fewer columns than the real one
        assert bucket in baseline, bucket
        assert set(keys) <= set(baseline[bucket]), (bucket, set(keys) - set(baseline[bucket]))


def test_new_assistant_key_in_v2_rows_is_reported_against_the_fixture(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, extra_assistant_key="brandNewField")
    fixtures = sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json"))

    baseline = agent_watch._baseline_type_keys_for_agent("opencode", fixtures)
    sample = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert "brandNewField" in sample["type_keys"]["session_message.assistant"]
    assert "brandNewField" not in baseline["session_message.assistant"]


def test_v2_fixture_has_no_real_paths_or_payloads():
    for path in FIXTURE_ROOT.rglob("*.json"):
        text = path.read_text(encoding="utf-8")
        assert "/Users/" not in text, path
        assert "base64" not in text, path
        json.loads(text)
