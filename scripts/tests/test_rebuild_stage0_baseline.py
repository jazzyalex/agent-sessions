import json
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import rebuild_stage0_baseline as rebuild


def _write_legacy_session(root: Path) -> Path:
    path = root / "project-1" / "ses_legacy.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"id": "ses_legacy", "title": "legacy"}) + "\n", encoding="utf-8")
    return path


def _write_opencode_db(path: Path, *, novel_part_key: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                project_id TEXT,
                parent_id TEXT,
                slug TEXT,
                directory TEXT,
                title TEXT,
                version TEXT,
                time_created INTEGER,
                time_updated INTEGER,
                summary_additions INTEGER,
                summary_deletions INTEGER,
                summary_files INTEGER,
                summary_diffs TEXT,
                time_archived INTEGER
            );
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                data TEXT NOT NULL,
                time_created INTEGER
            );
            CREATE TABLE part (
                id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                data TEXT NOT NULL,
                time_created INTEGER
            );
            """
        )
        conn.execute(
            """
            INSERT INTO session (
                id, project_id, parent_id, slug, directory, title, version,
                time_created, time_updated, summary_additions, summary_deletions,
                summary_files, summary_diffs, time_archived
            )
            VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)
            """,
            ("ses_db", "project-1", "slug", "/tmp/project", "DB session", "1", 1, 2),
        )
        conn.execute(
            "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?)",
            ("msg_1", "ses_db", json.dumps({"role": "user", "content": "hello"}), 3),
        )
        part = {"type": "text", "text": "hello"}
        if novel_part_key:
            part["dbOnlyNovelKey"] = "private-value-never-printed"
        conn.execute(
            "INSERT INTO part (id, message_id, session_id, data, time_created) VALUES (?, ?, ?, ?, ?)",
            ("prt_1", "msg_1", "ses_db", json.dumps(part), 4),
        )
        conn.commit()
    finally:
        conn.close()


def _baseline(*, include_legacy: bool = True) -> dict[str, list[str]]:
    baseline = {
        "session": ["directory", "id", "projectID", "slug", "time", "title", "version"],
        "message.user": ["content", "id", "role", "sessionID"],
        "part.text": ["id", "messageID", "sessionID", "text", "type"],
    }
    if include_legacy:
        baseline["<missing-type>"] = ["id", "title"]
    return baseline


def _db_config(db_path: Path, legacy_root: Path) -> dict:
    return {
        "weekly": {
            "local_schema": {
                "kind": "opencode_latest_session",
                "db_roots": [str(db_path)],
                "roots": [str(legacy_root)],
                "glob": "**/ses_*.json",
                "max_messages": 250,
                "max_parts": 2500,
            }
        }
    }


def _patch_inputs(monkeypatch, cfg: dict) -> None:
    monkeypatch.setattr(rebuild, "_load_config", lambda agent: cfg)
    monkeypatch.setattr(rebuild, "_baseline_paths", lambda agent: ["unused"])
    monkeypatch.setattr(
        rebuild.agent_watch,
        "_baseline_type_keys_for_agent",
        lambda agent, paths: _baseline(),
    )


def test_opencode_db_report_checks_configured_sqlite_before_clean_legacy_roots(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=True)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "part.text += dbOnlyNovelKey" in output
    assert "latest SQLite session" in output
    assert "sweeping 1 sessions on disk" not in output
    assert "private-value-never-printed" not in output


def test_opencode_missing_configured_db_fails_closed_instead_of_legacy_fallback(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    missing_db = tmp_path / "current" / "missing.db"
    _patch_inputs(monkeypatch, _db_config(missing_db, legacy_root))

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert rc != 0
    assert "sqlite" in output
    assert "missing" in output or "not found" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_corrupt_configured_db_fails_closed_instead_of_legacy_fallback(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    corrupt_db = tmp_path / "current" / "opencode.db"
    corrupt_db.parent.mkdir(parents=True)
    corrupt_db.write_bytes(b"not a sqlite database")
    _patch_inputs(monkeypatch, _db_config(corrupt_db, legacy_root))

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert rc != 0
    assert "sqlite" in output
    assert "failed" in output or "error" in output or "corrupt" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_unreadable_db_fingerprint_error_fails_closed(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    calls = []

    def unreadable(path, *, max_messages, max_parts):
        calls.append(path)
        return {
            "file": str(path),
            "type_counts": {},
            "type_keys": {},
            "message_rows_parsed": 0,
            "part_rows_parsed": 0,
            "parse_errors": 1,
            "error": "sqlite_open_failed: permission denied",
        }

    monkeypatch.setattr(
        rebuild.agent_watch,
        "_opencode_sqlite_latest_session_schema_fingerprint",
        unreadable,
    )

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert calls == [db_path]
    assert rc != 0
    assert "sqlite" in output
    assert "permission denied" in output or "unreadable" in output or "failed" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_db_emit_fails_closed_without_modifying_fixture(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=True)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    fixture_root = tmp_path / "fixtures"
    fixture = fixture_root / "opencode" / "small.jsonl"
    fixture.parent.mkdir(parents=True)
    original = '{"type":"sentinel","keep":"exact"}\n'
    fixture.write_text(original, encoding="utf-8")

    monkeypatch.setattr(rebuild, "REPO", tmp_path)
    monkeypatch.setattr(rebuild, "FIXTURES", fixture_root)
    monkeypatch.setattr(rebuild, "TARGET_FIXTURE", {"opencode": "opencode/small.jsonl"})

    rc = rebuild.main(["--agent", "opencode", "--emit"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert rc != 0
    assert "sqlite" in output
    assert "--emit" in output or "emit" in output
    assert fixture.read_text(encoding="utf-8") == original


def test_json_only_rebuild_behavior_is_preserved(tmp_path, monkeypatch, capsys):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    cfg = {
        "weekly": {
            "local_schema": {
                "kind": "opencode_storage_latest_session",
                "roots": [str(legacy_root)],
                "glob": "**/ses_*.json",
            }
        }
    }
    _patch_inputs(monkeypatch, cfg)

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()

    assert rc == 0
    assert "fixture already covers every bucket/key on disk" in captured.out


def test_opencode_clean_latest_db_is_not_reported_as_complete_rebuild(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "observed parsed SQLite rows show no schema gaps" in output
    assert "cannot establish complete coverage" in output
    assert "incomplete/unsupported" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_clean_latest_db_emit_fails_closed_without_modifying_fixture(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    fixture_root = tmp_path / "fixtures"
    fixture = fixture_root / "opencode" / "small.jsonl"
    fixture.parent.mkdir(parents=True)
    original = '{"type":"sentinel","keep":"clean-latest"}\n'
    fixture.write_text(original, encoding="utf-8")

    monkeypatch.setattr(rebuild, "REPO", tmp_path)
    monkeypatch.setattr(rebuild, "FIXTURES", fixture_root)
    monkeypatch.setattr(rebuild, "TARGET_FIXTURE", {"opencode": "opencode/small.jsonl"})

    rc = rebuild.main(["--agent", "opencode", "--emit"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "--emit is unsupported for DB-backed diagnostics" in output
    assert "cannot establish complete coverage" in output
    assert "fixture already covers every bucket/key on disk" not in output
    assert fixture.read_text(encoding="utf-8") == original


def test_opencode_inspects_every_configured_db_root_for_diagnostics(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    clean_db = tmp_path / "db-a" / "opencode.db"
    novel_db = tmp_path / "db-b" / "opencode.db"
    _write_opencode_db(clean_db, novel_part_key=False)
    _write_opencode_db(novel_db, novel_part_key=True)
    cfg = _db_config(clean_db, legacy_root)
    cfg["weekly"]["local_schema"]["db_roots"] = [str(clean_db), str(novel_db)]
    _patch_inputs(monkeypatch, cfg)

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "2 configured DB root(s)" in output
    assert "part.text += dbOnlyNovelKey" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_empty_db_fails_closed_without_legacy_clean_fallback(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("DELETE FROM session")
        conn.commit()
    finally:
        conn.close()
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert rc == 1
    assert "sqlite" in output
    assert "empty" in output or "no active sessions" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_parse_errors_fail_closed_even_with_covered_keys(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    _patch_inputs(monkeypatch, _db_config(db_path, legacy_root))

    calls = []

    def parse_error(path, *, max_messages, max_parts):
        calls.append(path)
        return {
            "file": str(path),
            "type_counts": {"session": 1, "message.user": 1, "part.text": 1},
            "type_keys": {
                "session": ["directory", "id", "projectID", "slug", "time", "title", "version"],
                "message.user": ["content", "id", "role", "sessionID"],
                "part.text": ["id", "messageID", "sessionID", "text", "type"],
            },
            "message_rows_parsed": 1,
            "part_rows_parsed": 1,
            "parse_errors": 1,
        }

    monkeypatch.setattr(
        rebuild.agent_watch,
        "_opencode_sqlite_latest_session_schema_fingerprint",
        parse_error,
    )

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert calls == [db_path]
    assert rc == 1
    assert "parse error" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_row_limit_is_explicitly_incomplete(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?)",
            ("msg_2", "ses_db", json.dumps({"role": "assistant", "content": "second"}), 5),
        )
        conn.commit()
    finally:
        conn.close()
    cfg = _db_config(db_path, legacy_root)
    cfg["weekly"]["local_schema"]["max_messages"] = 1
    _patch_inputs(monkeypatch, cfg)

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = (captured.out + captured.err).lower()

    assert rc == 1
    assert "max_messages row limit (1)" in output
    assert "incomplete" in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_missing_secondary_db_cannot_be_masked_by_healthy_root(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    healthy_db = tmp_path / "db-a" / "opencode.db"
    missing_db = tmp_path / "db-b" / "opencode.db"
    _write_opencode_db(healthy_db, novel_part_key=False)
    cfg = _db_config(healthy_db, legacy_root)
    cfg["weekly"]["local_schema"]["db_roots"] = [str(healthy_db), str(missing_db)]
    _patch_inputs(monkeypatch, cfg)

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert f"configured SQLite DB missing: {missing_db}" in output
    assert "configured DB evidence is incomplete" in output
    assert "latest SQLite session keys are covered by the fixture" not in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_latest_kind_without_db_roots_fails_closed_report(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    cfg = {
        "weekly": {
            "local_schema": {
                "kind": "opencode_latest_session",
                "roots": [str(legacy_root)],
                "glob": "**/ses_*.json",
            }
        }
    }
    _patch_inputs(monkeypatch, cfg)

    fixture_root = tmp_path / "fixtures"
    fixture = fixture_root / "opencode" / "small.jsonl"
    fixture.parent.mkdir(parents=True)
    original = '{"type":"sentinel","keep":"missing-db-roots-report"}\n'
    fixture.write_text(original, encoding="utf-8")
    monkeypatch.setattr(rebuild, "FIXTURES", fixture_root)
    monkeypatch.setattr(rebuild, "TARGET_FIXTURE", {"opencode": "opencode/small.jsonl"})

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "configured SQLite db_roots is missing or empty" in output
    assert "implicit HOME default DB path is not accessed" in output
    assert "sweeping 1 sessions on disk" not in output
    assert "fixture already covers every bucket/key on disk" not in output
    assert fixture.read_text(encoding="utf-8") == original


def test_opencode_latest_kind_without_db_roots_emit_never_writes_fixture(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    cfg = {
        "weekly": {
            "local_schema": {
                "kind": "opencode_latest_session",
                "roots": [str(legacy_root)],
                "glob": "**/ses_*.json",
            }
        }
    }
    _patch_inputs(monkeypatch, cfg)

    fixture_root = tmp_path / "fixtures"
    fixture = fixture_root / "opencode" / "small.jsonl"
    fixture.parent.mkdir(parents=True)
    original = '{"type":"sentinel","keep":"missing-db-roots-emit"}\n'
    fixture.write_text(original, encoding="utf-8")
    monkeypatch.setattr(rebuild, "FIXTURES", fixture_root)
    monkeypatch.setattr(rebuild, "TARGET_FIXTURE", {"opencode": "opencode/small.jsonl"})

    rc = rebuild.main(["--agent", "opencode", "--emit"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "configured SQLite db_roots is missing or empty" in output
    assert "implicit HOME default DB path is not accessed" in output
    assert "--emit is unsupported for DB-backed diagnostics" in output
    assert "sweeping 1 sessions on disk" not in output
    assert fixture.read_text(encoding="utf-8") == original


def test_opencode_max_parts_limit_is_reported_conservatively(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            "INSERT INTO part (id, message_id, session_id, data, time_created) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                "prt_2",
                "msg_1",
                "ses_db",
                json.dumps(
                    {
                        "type": "text",
                        "text": "second",
                        "dbOnlyNovelKey": "uninspected-private-value",
                    }
                ),
                5,
            ),
        )
        conn.commit()
    finally:
        conn.close()
    cfg = _db_config(db_path, legacy_root)
    cfg["weekly"]["local_schema"]["max_parts"] = 1
    _patch_inputs(monkeypatch, cfg)

    rc = rebuild.main(["--agent", "opencode"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "max_parts row limit (1)" in output
    assert "observed parsed SQLite rows show no schema gaps" in output
    assert "configured DB evidence is incomplete" in output
    assert "dbOnlyNovelKey" not in output
    assert "fixture already covers every bucket/key on disk" not in output


def test_opencode_non_dict_first_part_never_claims_complete_coverage_or_emits(
    tmp_path, monkeypatch, capsys
):
    legacy_root = tmp_path / "legacy"
    _write_legacy_session(legacy_root)
    db_path = tmp_path / "current" / "opencode.db"
    _write_opencode_db(db_path, novel_part_key=False)
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            "UPDATE part SET data = ? WHERE id = ?",
            (json.dumps([]), "prt_1"),
        )
        conn.execute(
            "INSERT INTO part (id, message_id, session_id, data, time_created) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                "prt_2",
                "msg_1",
                "ses_db",
                json.dumps(
                    {
                        "type": "text",
                        "text": "second",
                        "dbOnlyNovelKey": "uninspected-private-value",
                    }
                ),
                5,
            ),
        )
        conn.commit()
    finally:
        conn.close()
    cfg = _db_config(db_path, legacy_root)
    cfg["weekly"]["local_schema"]["max_parts"] = 1
    _patch_inputs(monkeypatch, cfg)

    fixture_root = tmp_path / "fixtures"
    fixture = fixture_root / "opencode" / "small.jsonl"
    fixture.parent.mkdir(parents=True)
    original = '{"type":"sentinel","keep":"non-dict-first-part"}\n'
    fixture.write_text(original, encoding="utf-8")
    monkeypatch.setattr(rebuild, "FIXTURES", fixture_root)
    monkeypatch.setattr(rebuild, "TARGET_FIXTURE", {"opencode": "opencode/small.jsonl"})

    rc = rebuild.main(["--agent", "opencode", "--emit"])
    captured = capsys.readouterr()
    output = captured.out + captured.err

    assert rc == 1
    assert "observed parsed SQLite rows show no schema gaps" in output
    assert "cannot establish complete coverage" in output
    assert "latest SQLite session keys are covered by the fixture" not in output
    assert "fixture already covers every bucket/key on disk" not in output
    assert "dbOnlyNovelKey" not in output
    assert "--emit is unsupported for DB-backed diagnostics" in output
    assert fixture.read_text(encoding="utf-8") == original
