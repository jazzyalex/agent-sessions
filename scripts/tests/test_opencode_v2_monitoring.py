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


def _write_db(
    path: Path,
    *,
    v1_updated: int,
    v2_updated: int | None,
    extra_assistant_key: str | None = None,
    mutate_assistant=None,
    rows_override: list | None = None,
    newer_archived_v2: bool = False,
) -> None:
    """A database with one v1 session and one v2 session.

    rows_override replaces the v2 session's rows; a row's data may be a raw
    string to store unparsed. newer_archived_v2 adds an archived v2 session
    newer than everything else, which must never be sampled.
    """
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
                id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT,
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
            "INSERT INTO session_v2 VALUES ('ses_v2','p',NULL,'s','/tmp','t','2.1.1','{\"id\":\"m\"}',1,?,NULL)",
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
        if mutate_assistant:
            mutate_assistant(assistant)
        rows = [
            ("msg_u", "user", 0, {"time": {"created": 1}, "text": "pwd please", "files": [], "agents": []}),
            ("msg_a", "assistant", 1, assistant),
            ("msg_i", "idle", 2, {"time": {"created": 3}, "outcome": "succeeded"}),
        ]
        if rows_override is not None:
            rows = rows_override
        for row_id, row_type, seq, data in rows:
            conn.execute(
                "INSERT INTO session_message VALUES (?, 'ses_v2', ?, ?, 1, 1, ?)",
                (row_id, row_type, seq, data if isinstance(data, str) else json.dumps(data)),
            )
        if newer_archived_v2:
            conn.execute(
                "INSERT INTO session_v2 VALUES ('ses_arch','p',NULL,'s','/tmp','t','2.1.1',NULL,1,999999,999999)"
            )
            conn.execute(
                "INSERT INTO session_message VALUES ('msg_arch', 'ses_arch', 'archived-only-kind', 0, 1, 1, '{}')"
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


def _fingerprint(db: Path) -> dict:
    return agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)


def _baseline() -> dict:
    return agent_watch._baseline_type_keys_for_agent("opencode", sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json")))


PREBUMP_REQUIRED = [
    "session_message.user",
    "session_message.assistant",
    "session_message.assistant.tool_state.completed",
]


def test_configured_prebump_requires_user_assistant_and_completed_tool_buckets():
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text())
    assert cfg["agents"]["opencode"]["prebump"]["required_schema_buckets"] == PREBUMP_REQUIRED


def test_header_only_v2_session_fails_the_prebump_gate(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, rows_override=[])

    fp = _fingerprint(db)
    _, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert fp["store"] == "session_v2"
    assert agent_watch._observed_event_count(fp) == 0, "a session header is not an observed record"
    assert matches is False


def test_session_without_a_completed_tool_fails_the_prebump_gate(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a.__setitem__("content", [{"type": "text", "text": "hi"}]))

    schema_diff, matches = agent_watch._prebump_schema_check(
        fingerprint=_fingerprint(db), baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert matches is False
    assert schema_diff["missing_required_schema_buckets"] == ["session_message.assistant.tool_state.completed"]


def test_rich_v2_session_passes_the_prebump_gate_and_counts_physical_rows(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)

    fp = _fingerprint(db)
    _, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert matches is True
    assert agent_watch._observed_event_count(fp) == 3, "three rows, not the sum of their nested buckets"


def test_non_object_and_invalid_rows_are_parse_errors_that_fail_both_gates(tmp_path):
    db = tmp_path / "opencode.db"
    good = [
        ("msg_u", "user", 0, {"time": {"created": 1}, "text": "hi", "files": [], "agents": []}),
    ]
    for bad_data in ("[]", "null", "42", "{not json"):
        path = tmp_path / f"db_{abs(hash(bad_data))}.db"
        _write_db(path, v1_updated=100, v2_updated=200,
                  rows_override=good + [("msg_bad", "assistant", 1, bad_data)])
        fp = _fingerprint(path)
        assert fp["parse_errors"] == 1, bad_data

        _, prebump_ok = agent_watch._prebump_schema_check(fingerprint=fp, baseline_type_keys=_baseline())
        assert prebump_ok is False, bad_data

        schema_diff = agent_watch._schema_diff(
            observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
            observed_event_count=agent_watch._observed_event_count(fp),
        )
        assert schema_diff["unknown_only_is_empty"], "the readable rows alone look clean"
        assert agent_watch._weekly_schema_matches(schema_diff, fp) is False, bad_data
        assert schema_diff["parse_errors"] == 1


def test_weekly_gate_still_passes_a_clean_sample(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert agent_watch._weekly_schema_matches(schema_diff, fp) is True


def test_equal_timestamps_sample_the_original_v1_rows(tmp_path):
    # An untouched migrated copy has the v1 row's time_updated and may have
    # lost assistant steps; the v1 rows are the faithful sample.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=200, v2_updated=200)
    fp = _fingerprint(db)
    assert "store" not in fp
    assert "message.user" in fp["type_keys"]


def test_null_v2_timestamp_does_not_beat_a_v1_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=None)
    assert "store" not in _fingerprint(db)


def test_archived_v2_session_is_never_sampled(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, newer_archived_v2=True)
    fp = _fingerprint(db)
    assert fp["store"] == "session_v2"
    assert "session_message.archived-only-kind" not in fp["type_keys"]
    assert "session_message.assistant" in fp["type_keys"]


def test_nested_cache_token_rename_is_drift(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a["tokens"].__setitem__("cache", {"hit": 0, "write": 0}))
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert schema_diff["unknown_keys"] == {"session_message.assistant.tokens.cache": ["hit"]}
    assert agent_watch._weekly_schema_matches(schema_diff, fp) is False


def test_model_structure_change_is_drift(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a.__setitem__("model", {"ref": "p/m"}))
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert schema_diff["unknown_keys"] == {"session_message.assistant.model": ["ref"]}


def test_capture_export_keeps_malformed_rows_instead_of_dropping_the_export(tmp_path):
    import capture_latest_agent_sessions as capture

    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              rows_override=[("msg_u", "user", 0, {"text": "hi"}), ("msg_bad", "assistant", 1, "{not json")])

    export = capture._export_latest_opencode_sqlite_session(db)

    assert export["store"] == "session_v2"
    assert export["parse_errors"] == 1
    bad = export["messages"][1]
    assert bad["raw_data"] == "{not json" and "parse_error" in bad and "data" not in bad
    assert export["messages"][0]["data"] == {"text": "hi"}


def test_capture_export_uses_v1_rows_on_equal_timestamps(tmp_path):
    import capture_latest_agent_sessions as capture

    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=200, v2_updated=200)
    export = capture._export_latest_opencode_sqlite_session(db)
    assert "store" not in export
    assert export["session"]["id"] == "ses_v1"


# The only string values the sqlite_v2 fixture may contain. Anything else is
# real data that escaped redaction.
_FIXTURE_PLACEHOLDERS = {"redacted", "fixture.png", "fixture", "/tmp/fixture", "ses_fixture_v2", "proj_fixture", "2.1.1", ""}
# Schema discriminators, which are the schema itself and survive redaction.
_FIXTURE_DISCRIMINATOR_KEYS = {"type", "status", "reason", "outcome", "finish"}
_FIXTURE_TOOL_NAMES = {"todowrite", "shell", "read", "edit", "write", "grep", "glob", "list", "bash", "task", "webfetch"}


def _fixture_string_violations(value, key=None, path="$"):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from _fixture_string_violations(v, k, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from _fixture_string_violations(v, key, f"{path}[{i}]")
    elif isinstance(value, str):
        if value in _FIXTURE_PLACEHOLDERS:
            return
        if key in _FIXTURE_DISCRIMINATOR_KEYS and len(value) <= 40 and " " not in value:
            return
        if key == "name" and value in _FIXTURE_TOOL_NAMES:
            return
        yield f"{path}={value!r}"
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        if value != 0:
            yield f"{path}={value!r} (numbers are redacted to 0)"


def test_v2_fixture_values_follow_the_redaction_policy():
    files = sorted(FIXTURE_ROOT.rglob("*.json"))
    assert len(files) == 7
    violations = []
    for path in files:
        obj = json.loads(path.read_text(encoding="utf-8"))
        # session_message files wrap the row: {"type": <row type>, "data": {...}}
        violations += [f"{path.name}: {v}" for v in _fixture_string_violations(obj)]
    assert violations == []


def test_redaction_policy_catches_a_leaked_prompt_path_and_secret():
    leaked = {
        "data": {
            "text": "please fix my billing code",
            "files": [{"name": "/home/someone/notes.txt"}],
            "tokens": {"input": 1234},
            "auth": "sk-live-abc",
        }
    }
    found = list(_fixture_string_violations(leaked))
    assert len(found) == 4, found
