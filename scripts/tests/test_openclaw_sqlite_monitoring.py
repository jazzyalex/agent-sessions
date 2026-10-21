"""OpenClaw 2026.10.5 monitoring: the per-agent SQLite transcript store.

OpenClaw imports `agents/<id>/sessions/*.jsonl` into
`agents/<id>/agent/openclaw-agent.sqlite` (`transcript_events`, same record
shapes, some rows zstd-compressed) and moves the originals to
`session-sqlite-import-archive/`. Weekly and prebump must sample that store,
decode compressed rows, and never mistake the embedded Codex harness's rollouts
under `agents/<id>/agent/codex-home/sessions/` for OpenClaw transcripts.
"""
import json
import re
import sqlite3
import subprocess as _sp
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch  # noqa: E402
import agent_watch_prebump_drivers as drv_mod  # noqa: E402

FIXTURE = REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "openclaw" / "sqlite" / "openclaw-agent.sql"
JSONL_FIXTURES = [
    REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "openclaw" / "small.jsonl",
    REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "openclaw" / "large.jsonl",
]


def _build_store(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(FIXTURE.read_text(encoding="utf-8"))
        conn.commit()
    finally:
        conn.close()
    return path


def _execute(path: Path, sql: str) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(sql)
        conn.commit()
    finally:
        conn.close()


def _baseline() -> dict:
    return agent_watch._baseline_type_keys_for_agent(
        "openclaw", [str(p) for p in JSONL_FIXTURES] + [str(FIXTURE)]
    )


def _diff(fp: dict) -> dict:
    return agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"],
        baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )


# ---------------------------------------------------------------- fingerprint


def test_fixture_fingerprint_decodes_the_compressed_row():
    fp = agent_watch._openclaw_sqlite_schema_fingerprint(
        FIXTURE, sample_count=0, sql_script=FIXTURE.read_text(encoding="utf-8")
    )
    assert fp["parse_errors"] == 0
    assert fp["compressed_events"] == 1
    assert fp["schema_version"] == 25 and fp["app_version"] == "2026.10.5"
    assert fp["type_counts"] == {"message": 8, "session": 2}
    # `__openclaw.toolOutput` exists only inside the zstd row.
    assert "message.message.__openclaw.toolOutput" in fp["type_keys"]
    assert fp["type_keys"]["sqlite.transcript_events.payload"] == ["event_json", "event_zstd"]
    assert "event_zstd" in fp["type_keys"]["sqlite.transcript_events"]


def test_store_built_from_fixture_matches_the_baseline(tmp_path):
    db = _build_store(tmp_path / "agents" / "main" / "agent" / "openclaw-agent.sqlite")
    fp = agent_watch._openclaw_sqlite_schema_fingerprint(db)
    diff = _diff(fp)
    assert diff["unknown_only_is_empty"], diff
    assert fp["sampled_sessions"] == 2
    assert fp["logical_mtime_epoch"] > 1_700_000_000


def test_baseline_unions_the_jsonl_and_sqlite_fixtures():
    baseline = _baseline()
    assert "model_change" in baseline  # JSONL-only record type
    assert "sqlite.session_windows" in baseline  # store columns
    assert "contextUsage" in baseline["message.message.usage"]


def test_corrupt_compressed_row_is_a_parse_error(tmp_path):
    db = _build_store(tmp_path / "openclaw-agent.sqlite")
    _execute(db, "UPDATE transcript_events SET event_zstd = X'28B52FFD0000DEADBEEF' WHERE event_json IS NULL;")
    fp = agent_watch._openclaw_sqlite_schema_fingerprint(db)
    assert fp["parse_errors"] == 1
    assert not agent_watch._weekly_schema_matches(_diff(fp), fp)


def test_compressed_row_with_wrong_recorded_size_is_a_parse_error(tmp_path):
    db = _build_store(tmp_path / "openclaw-agent.sqlite")
    _execute(db, "UPDATE transcript_events SET event_utf8_bytes = event_utf8_bytes + 1 WHERE event_json IS NULL;")
    assert agent_watch._openclaw_sqlite_schema_fingerprint(db)["parse_errors"] == 1


def test_new_store_column_reads_as_storage_drift(tmp_path):
    db = _build_store(tmp_path / "openclaw-agent.sqlite")
    _execute(db, "ALTER TABLE session_windows ADD COLUMN future_column TEXT;")
    diff = _diff(agent_watch._openclaw_sqlite_schema_fingerprint(db))
    assert diff["unknown_keys"] == {"sqlite.session_windows": ["future_column"]}


def test_details_first_level_keys_are_watched_but_nested_objects_are_not(tmp_path):
    """ToolTextBlockNormalizer reads details.exitCode/status; tool-defined nested objects are free-form."""
    db = _build_store(tmp_path / "openclaw-agent.sqlite")
    renamed = json.dumps({"type": "message", "id": "t", "message": {
        "role": "toolResult", "toolCallId": "c", "toolName": "exec", "isError": False,
        "content": [{"type": "text", "text": "x"}],
        "details": {"status": "completed", "exit_code": 0,
                    "messageDelivery": {"brandNewNestedKey": 1}}}})
    _execute(db, f"""
        INSERT INTO transcript_events (session_id, seq, event_json, created_at)
        VALUES ('openclaw-fixture-native', 6, '{renamed}', 1792494406000);
    """)
    diff = _diff(agent_watch._openclaw_sqlite_schema_fingerprint(db))
    assert diff["unknown_keys"] == {"message.message.details": ["exit_code"]}
    assert diff["unknown_types"] == []


def test_store_missing_a_column_the_app_reads_is_unreadable(tmp_path):
    db = tmp_path / "openclaw-agent.sqlite"
    _execute(db, """
        CREATE TABLE session_windows (session_id TEXT, created_at INTEGER, updated_at INTEGER);
        CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER);
    """)
    fp = agent_watch._openclaw_sqlite_schema_fingerprint(db)
    assert fp["parse_errors"] == 1
    assert "session_windows.display_name:missing" in fp["required_field_violations"]


def test_unopenable_store_is_a_read_failure_not_drift(tmp_path):
    db = tmp_path / "openclaw-agent.sqlite"
    db.write_bytes(b"not a database")
    fp = agent_watch._openclaw_sqlite_schema_fingerprint(db)
    assert agent_watch._sample_read_failed(fp)


# --------------------------------------------------------------------- weekly


def _weekly_cfg(root: Path) -> dict:
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text(encoding="utf-8"))
    local = dict(cfg["agents"]["openclaw"]["weekly"]["local_schema"])
    local["roots"] = [str(root)]
    return local


def test_weekly_samples_the_store_and_not_the_codex_harness(tmp_path):
    state = tmp_path / ".openclaw"
    db = _build_store(state / "agents" / "main" / "agent" / "openclaw-agent.sqlite")
    rollout = state / "agents" / "main" / "agent" / "codex-home" / "sessions" / "2026" / "10" / "20" / "rollout-x.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_text('{"type":"session_meta","payload":{}}\n', encoding="utf-8")
    fp = agent_watch._openclaw_weekly_sqlite_fingerprint(_weekly_cfg(state))
    assert fp is not None
    assert Path(fp["file"]) == db
    assert "session_meta" not in fp["type_keys"]


def test_weekly_returns_none_without_a_store(tmp_path):
    state = tmp_path / ".openclaw"
    (state / "agents" / "main" / "sessions").mkdir(parents=True)
    assert agent_watch._openclaw_weekly_sqlite_fingerprint(_weekly_cfg(state)) is None


def test_discovery_contract_accepts_the_store_and_legacy_jsonl():
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text(encoding="utf-8"))
    contract = cfg["agents"]["openclaw"]["weekly"]["discovery_path_contract"]
    check = agent_watch._check_discovery_path_contract
    assert check("/h/.openclaw/agents/main/agent/openclaw-agent.sqlite", contract)["ok"]
    assert check("/h/.openclaw/agents/main/sessions/abc.jsonl", contract)["ok"]
    assert not check(
        "/h/.openclaw/agents/main/agent/codex-home/sessions/2026/10/20/rollout-x.jsonl", contract
    )["ok"]
    assert not check(
        "/h/.openclaw/agents/main/agent/openclaw-agent.sqlite.pre-startup-migration-x.bak", contract
    )["ok"]


# -------------------------------------------------------------------- prebump


def _marker_from(argv: list[str]) -> str:
    return argv[argv.index("--message") + 1].split("Include this exact marker in your final answer: ", 1)[1]


def test_driver_returns_the_sqlite_session_written_for_its_key(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()
    db_path = sb / ".openclaw" / "agents" / "main" / "agent" / "openclaw-agent.sqlite"

    def fake_run(argv, *, env=None, **kwargs):
        _write_prebump_session(db_path, argv[argv.index("--session-key") + 1], _marker_from(argv), reply=True)
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True, res.error
    assert res.session_path == db_path
    assert res.session_id == "prebump-session"


def _write_prebump_session(db_path: Path, key: str, marker: str, *, reply: bool) -> None:
    _build_store(db_path)
    user = json.dumps({"type": "message", "id": "u", "message": {"role": "user", "content": f"Say hi. {marker}"}})
    answer = marker if reply else "I could not run."
    assistant = json.dumps({"type": "message", "id": "a", "message": {
        "role": "assistant", "content": [{"type": "text", "text": answer}]}})
    _execute(db_path, f"""
        INSERT INTO session_windows (session_id, session_key, created_at, updated_at)
        VALUES ('prebump-session', '{key}', 1, 2);
        INSERT INTO transcript_events (session_id, seq, event_json, created_at)
        VALUES ('prebump-session', 1, '{{"type":"session","id":"prebump-session"}}', 1),
               ('prebump-session', 2, '{user}', 2),
               ('prebump-session', 3, '{assistant}', 3);
    """)


def test_driver_rejects_a_session_whose_marker_is_only_in_the_prompt(tmp_path):
    """The prompt carries the marker, so only a reply record proves a turn ran."""
    sb = tmp_path / "sb"
    sb.mkdir()
    db_path = sb / ".openclaw" / "agents" / "main" / "agent" / "openclaw-agent.sqlite"

    def fake_run(argv, *, env=None, **kwargs):
        _write_prebump_session(db_path, argv[argv.index("--session-key") + 1], _marker_from(argv), reply=False)
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "openclaw_marker_missing"


def test_driver_never_returns_the_embedded_codex_rollout(tmp_path):
    """The 2026-10-20 discovery_violation: the harness rollout carries the marker too."""
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        marker = _marker_from(argv)
        rollout = (sb / ".openclaw" / "agents" / "main" / "agent" / "codex-home" / "sessions"
                   / "2026" / "10" / "20" / "rollout-2026-10-20T21-54-15-x.jsonl")
        rollout.parent.mkdir(parents=True)
        rollout.write_text(json.dumps({"type": "session_meta", "payload": {"text": marker}}) + "\n")
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "openclaw_marker_missing"


def test_driver_finds_marker_inside_a_compressed_row(tmp_path):
    db = _build_store(tmp_path / "agents" / "main" / "agent" / "openclaw-agent.sqlite")
    # The fixture's compressed tool result holds this file list entry.
    found = drv_mod._openclaw_sqlite_session_for_key(
        tmp_path / "agents", "agent:main:recovered:openclaw-fixture-migrated", "fixture-file-39.txt"
    )
    assert found == (db, "openclaw-fixture-migrated")


def test_discovery_validation_checks_the_named_session_in_the_store(tmp_path):
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text(encoding="utf-8"))
    contract = cfg["agents"]["openclaw"]["prebump"]["discover_session"]
    db = _build_store(tmp_path / ".openclaw" / "agents" / "main" / "agent" / "openclaw-agent.sqlite")
    agent_watch._validate_session_discovery(db, contract, tmp_path, session_id="openclaw-fixture-native")
    try:
        agent_watch._validate_session_discovery(db, contract, tmp_path)
    except agent_watch._DiscoveryViolation as exc:
        assert "named no session" in str(exc)
    else:
        raise AssertionError("a shared store without a session id must not validate")
    try:
        agent_watch._validate_session_discovery(db, contract, tmp_path, session_id="missing")
    except agent_watch._DiscoveryViolation as exc:
        assert "missing required types" in str(exc)
    else:
        raise AssertionError("a session with no records must not validate")


def test_prebump_requires_a_real_tool_call(tmp_path):
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text(encoding="utf-8"))
    pb = cfg["agents"]["openclaw"]["prebump"]
    db = _build_store(tmp_path / "openclaw-agent.sqlite")
    with_tool = agent_watch._openclaw_sqlite_schema_fingerprint(db, session_ids=["openclaw-fixture-native"])
    _, ok = agent_watch._prebump_schema_check(
        fingerprint=with_tool, baseline_type_keys=_baseline(),
        required_schema_buckets=agent_watch._required_schema_buckets_for(pb, with_tool), agent_name="openclaw",
    )
    assert ok
    _execute(db, """
        DELETE FROM transcript_events WHERE session_id = 'openclaw-fixture-native' AND seq IN (3, 4);
    """)
    without_tool = agent_watch._openclaw_sqlite_schema_fingerprint(db, session_ids=["openclaw-fixture-native"])
    diff, ok = agent_watch._prebump_schema_check(
        fingerprint=without_tool, baseline_type_keys=_baseline(),
        required_schema_buckets=agent_watch._required_schema_buckets_for(pb, without_tool), agent_name="openclaw",
    )
    assert not ok
    assert diff["missing_required_schema_buckets"] == ["message.message.content:toolCall"]


# ------------------------------------------------------------------ redaction


def test_fixture_values_follow_the_redaction_policy():
    """Section 7: no real paths, ids, emails or prompt text, including inside the zstd row."""
    conn = sqlite3.connect(":memory:")
    conn.executescript(FIXTURE.read_text(encoding="utf-8"))
    texts = [FIXTURE.read_text(encoding="utf-8")]
    for event_json, event_zstd, size in conn.execute(
        "SELECT event_json, event_zstd, event_utf8_bytes FROM transcript_events"
    ):
        texts.append(agent_watch._openclaw_decode_event_payload(event_json, event_zstd, size))
    blob = "\n".join(texts)
    assert "/Users/" not in blob and "/home/" not in blob
    assert not re.search(r"[\w.+-]+@[\w-]+\.[\w.]+", blob)
    assert not re.search(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", blob)
    assert not re.search(r"\bcall_[A-Za-z0-9]{8,}\b", blob)
