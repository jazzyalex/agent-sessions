"""Weekly sampling must not let real-home prebump sessions crowd out real sessions.

`--allow-real-home` prebump runs write short one-prompt sessions into the real agent
store. They are the newest sessions, so the weekly newest-N union filled up with them:
on 2026-10-21 copilot's union held four 16-event prebump sessions and one empty
session, and the weekly reported `blocked_thin_sample` at a version whose 05:04 weekly
had sampled 122 baseline types. The weekly now skips prebump-written sessions while
enough real sessions exist and tops the sample up with them only when it must.
"""
import json
import os
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch  # noqa: E402

MARKER = "AGENT_WATCH_PREBUMP_" + "0123456789abcdef" * 2
SANDBOX = "/repo/scripts/probe_scan_output/agent_watch/20261021-190037-1Z-p1-prebump/cline/agent-watch-prebump-cline-51ss3vmc/workspace"


def _write_jsonl(path: Path, records: list[dict], mtime: float) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
    os.utime(path, (mtime, mtime))
    return path


def _copilot_session(root: Path, name: str, mtime: float, *, prompt: str, extra: int) -> Path:
    records = [
        {"type": "session.start", "data": {"context": {"cwd": "/repo"}}},
        {"type": "user.message", "data": {"content": prompt}},
        {"type": "assistant.message", "data": {"content": "ok"}},
    ]
    records += [{"type": f"real.event_{i}", "data": {"n": i}} for i in range(extra)]
    records.append({"type": "session.shutdown", "data": {}})
    return _write_jsonl(root / name / "events.jsonl", records, mtime)


# ------------------------------------------------------------------ the signal


def test_marker_in_the_session_head_marks_a_prebump_session(tmp_path):
    path = _write_jsonl(
        tmp_path / "a.jsonl",
        [{"type": "session.start"}, {"type": "user.message", "data": {"content": f"List files. {MARKER}"}}],
        1.0,
    )
    assert agent_watch._is_prebump_session_file(path) is True


def test_marker_deep_inside_a_real_session_does_not_mark_it(tmp_path):
    """A real session that later quotes prebump output is still a real session."""
    records = [{"type": "user.message", "data": {"content": "debug the weekly"}}]
    records += [{"type": "assistant.message", "data": {"content": "x"}} for _ in range(40)]
    records.append({"type": "tool.execution_complete", "data": {"output": MARKER}})
    path = _write_jsonl(tmp_path / "b.jsonl", records, 1.0)
    assert agent_watch._is_prebump_session_file(path) is False


def test_configured_prebump_prompt_marks_a_claude_print_session(tmp_path):
    """claude_print has no marker; its configured prompt is the first queued record."""
    prompt = "Say hi, then use the Bash tool to run pwd."
    path = _write_jsonl(
        tmp_path / "c.jsonl",
        [{"type": "queue-operation", "operation": "enqueue", "content": prompt},
         {"type": "user", "cwd": "/repo", "message": {"role": "user", "content": prompt}}],
        1.0,
    )
    needles = agent_watch._prebump_prompt_needles({"prebump": {"prompt": prompt}})
    assert agent_watch._is_prebump_session_file(path, needles) is True
    assert agent_watch._is_prebump_session_file(path) is False


def test_sandbox_cwd_in_a_cline_manifest_marks_it(tmp_path):
    manifest = tmp_path / "1_abc" / "1_abc.json"
    manifest.parent.mkdir()
    manifest.write_text(json.dumps({"version": 1, "cwd": SANDBOX, "prompt": "x"}, indent=2), encoding="utf-8")
    real = tmp_path / "2_def" / "2_def.json"
    real.parent.mkdir()
    real.write_text(json.dumps({"version": 1, "cwd": "/Users/me/repo", "prompt": "x"}, indent=2), encoding="utf-8")
    assert agent_watch._is_prebump_session_file(manifest) is True
    assert agent_watch._is_prebump_session_file(real) is False


def test_sandbox_name_in_the_store_path_marks_cursor_and_dsh_sessions(tmp_path):
    cursor = (
        tmp_path / "Users-me-repo-scripts-probe-scan-output-agent-watch-20261021-1Z-p1-prebump-cursor-"
        "agent-watch-prebump-cursor-s7to6qnk" / "agent-transcripts" / "t" / "t.jsonl"
    )
    dsh = (
        tmp_path / "--Users-me-repo-scripts-probe_scan_output-agent_watch-20261021-1Z-p1-prebump-deepseek_harness-"
        "agent-watch-prebump-deepseek_harness-q1bglo47-workspace--" / "session-1" / "session.v4.jsonl.zstd"
    )
    real = tmp_path / "Users-me-repo" / "agent-transcripts" / "t" / "t.jsonl"
    for path in (cursor, dsh, real):
        _write_jsonl(path, [{"role": "user", "message": {"content": "hi"}}], 1.0)
    assert agent_watch._is_prebump_session_file(cursor) is True
    assert agent_watch._is_prebump_session_file(dsh, read_head=False) is True
    assert agent_watch._is_prebump_session_file(real) is False


# --------------------------------------------------------------- the selection


def test_prefer_real_sessions_skips_prebump_when_enough_real_exist():
    order = ["p1", "p2", "r1", "p3", "r2", "r3", "r4", "r5", "r6"]
    picked, stats = agent_watch._prefer_real_sessions(order, 5, lambda s: s.startswith("p"))
    assert picked == ["r1", "r2", "r3", "r4", "r5"]
    assert stats == {"sampled_prebump_sessions": 0, "skipped_prebump_sessions": 3}


def test_prefer_real_sessions_tops_up_with_the_newest_prebump_sessions():
    order = ["p1", "r1", "p2", "p3", "r2", "p4"]
    picked, stats = agent_watch._prefer_real_sessions(order, 5, lambda s: s.startswith("p"))
    # Newest-first order is kept; the oldest prebump session is the one left out.
    assert picked == ["p1", "r1", "p2", "p3", "r2"]
    assert stats == {"sampled_prebump_sessions": 3, "skipped_prebump_sessions": 1}


# ------------------------------------------------------- weekly, per store kind


def _weekly_copilot(tmp_path, monkeypatch, store: Path) -> dict:
    report_root = tmp_path / "out"
    cfg = {
        "report_root": str(report_root),
        "agents": {
            "copilot": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["copilot", "--version"],
                "upstream": [],
                "risk_keywords": {"schema": [], "usage": []},
                "prebump": {"driver": "copilot_prompt", "prompt": "List file names.", "real_home_session": True},
                "weekly": {
                    "local_schema": {
                        "kind": "jsonl_newest",
                        "roots": [str(store)],
                        "glob": "**/*.jsonl",
                        "max_lines": 2500,
                    }
                },
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["copilot", "--version"], 0, "1.0.102", "", "1.0.102"),
    )
    monkeypatch.setattr(agent_watch, "_resolve_cli_binary_mtime", lambda _argv: ("/tmp/fake-copilot", None))
    assert agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)]) == 0
    report = json.loads(next(report_root.glob("*/report.json")).read_text())
    return report["results"]["copilot"]["weekly"]


def test_weekly_union_excludes_prebump_sessions_when_enough_real_exist(tmp_path, monkeypatch):
    store = tmp_path / "session-state"
    real = [
        _copilot_session(store, f"real-{i}", 1000.0 + i, prompt="refactor the parser", extra=10)
        for i in range(6)
    ]
    for i in range(4):
        _copilot_session(store, f"prebump-{i}", 2000.0 + i, prompt=f"List file names. {MARKER}", extra=0)

    local = _weekly_copilot(tmp_path, monkeypatch, store)["local_schema"]
    newest_real_first = [str(p) for p in reversed(real)][:5]
    assert local["sampled_files"] == newest_real_first
    assert local["file"] == newest_real_first[0]
    assert local["sampled_prebump_sessions"] == 0
    assert local["skipped_prebump_sessions"] == 4


def test_weekly_union_counts_events_across_every_sampled_session(tmp_path, monkeypatch):
    """The thin gate read the lead session's line count, not the union's."""
    store = tmp_path / "session-state"
    for i in range(5):
        _copilot_session(store, f"real-{i}", 1000.0 + i, prompt="work", extra=3)

    weekly = _weekly_copilot(tmp_path, monkeypatch, store)
    assert weekly["local_schema"]["sampled_total_parsed_lines"] == 5 * 7
    assert weekly["schema_diff"]["observed_event_count"] == 5 * 7


def test_weekly_union_falls_back_to_prebump_sessions_when_real_ones_are_few(tmp_path, monkeypatch):
    store = tmp_path / "session-state"
    real = [_copilot_session(store, f"real-{i}", 1000.0 + i, prompt="work", extra=5) for i in range(2)]
    prebump = [
        _copilot_session(store, f"prebump-{i}", 2000.0 + i, prompt=f"List file names. {MARKER}", extra=0)
        for i in range(4)
    ]
    # A session started with the configured prompt alone (no marker) is also prebump.
    _copilot_session(store, "prebump-old-driver", 900.0, prompt="List file names.", extra=0)

    local = _weekly_copilot(tmp_path, monkeypatch, store)["local_schema"]
    expected = [str(p) for p in reversed(prebump)][:3] + [str(p) for p in reversed(real)]
    assert local["sampled_files"] == expected
    assert local["sampled_prebump_sessions"] == 3
    assert local["skipped_prebump_sessions"] == 2


def test_cursor_union_excludes_sandbox_project_dirs(tmp_path):
    projects = tmp_path / "projects"
    real = []
    for i in range(5):
        real.append(_write_jsonl(
            projects / "Users-me-repo" / "agent-transcripts" / f"r{i}" / f"r{i}.jsonl",
            [{"role": "user", "message": {"content": [{"type": "text", "text": "hi"}]}}],
            1000.0 + i,
        ))
    sandbox_dir = projects / "Users-me-repo-scripts-probe-scan-output-agent-watch-1-prebump-cursor-agent-watch-prebump-cursor-abcd1234"
    _write_jsonl(
        sandbox_dir / "agent-transcripts" / "p" / "p.jsonl",
        [{"role": "user", "message": {"content": [{"type": "text", "text": "hi"}]}}],
        2000.0,
    )
    fp = agent_watch._cursor_recent_schema_fingerprint(
        [str(projects)], "**/agent-transcripts/**/*.jsonl", max_lines=100, exclude_prebump=True
    )
    assert fp["sampled_files"] == [str(p) for p in reversed(real)]
    assert fp["sampled_prebump_sessions"] == 0
    assert fp["skipped_prebump_sessions"] == 1


def _openclaw_store(path: Path) -> Path:
    fixture = REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "openclaw" / "sqlite" / "openclaw-agent.sql"
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(fixture.read_text(encoding="utf-8"))
        for i, key in enumerate(["agent:main:prebump-a", "agent:main:prebump-b"]):
            sid = f"prebump-{i}"
            t = 1800000000000 + i
            conn.execute(
                "INSERT INTO session_windows (session_id, session_key, created_at, updated_at) VALUES (?, ?, ?, ?)",
                (sid, key, t, t),
            )
            conn.execute(
                "INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES (?, 1, ?, ?)",
                (sid, json.dumps({"type": "session", "id": sid}), t),
            )
        conn.commit()
    finally:
        conn.close()
    return path


def test_openclaw_sqlite_sample_excludes_prebump_session_keys(tmp_path):
    db = _openclaw_store(tmp_path / "openclaw-agent.sqlite")
    weekly = agent_watch._openclaw_sqlite_schema_fingerprint(db, exclude_prebump=True)
    # Fewer than five real sessions: the two prebump sessions top the sample up.
    assert weekly["sampled_session_ids"] == [
        "prebump-1", "prebump-0", "openclaw-fixture-native", "openclaw-fixture-migrated"
    ]
    assert weekly["sampled_prebump_sessions"] == 2
    assert weekly["skipped_prebump_sessions"] == 0
    one = agent_watch._openclaw_sqlite_schema_fingerprint(db, sample_count=2, exclude_prebump=True)
    assert one["sampled_session_ids"] == ["openclaw-fixture-native", "openclaw-fixture-migrated"]
    assert one["sampled_prebump_sessions"] == 0
    assert one["skipped_prebump_sessions"] == 2


def _hermes_db(path: Path) -> Path:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, model TEXT, model_config TEXT,
                system_prompt TEXT, started_at REAL, ended_at REAL, message_count INTEGER);
            CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT,
                content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
                finish_reason TEXT, reasoning TEXT, reasoning_content TEXT, codex_reasoning_items TEXT);
            """
        )
        rows = [("real", 100.0, "summarise the logs"), ("prebump", 200.0, f"Say hi. {MARKER}")]
        for n, (sid, started, text) in enumerate(rows):
            conn.execute(
                "INSERT INTO sessions (id, source, started_at, message_count) VALUES (?, 'cli', ?, 1)",
                (sid, started),
            )
            conn.execute(
                "INSERT INTO messages (id, session_id, role, content, timestamp) VALUES (?, ?, 'user', ?, ?)",
                (n + 1, sid, text, started),
            )
        conn.commit()
    finally:
        conn.close()
    return path


def test_hermes_weekly_sample_skips_a_newer_prebump_session(tmp_path):
    db = _hermes_db(tmp_path / "state.db")
    weekly = agent_watch._hermes_state_db_latest_session_schema_fingerprint(db, max_messages=10, exclude_prebump=True)
    assert weekly["session_id"] == "real"
    assert weekly["sampled_prebump_sessions"] == 0
    assert weekly["skipped_prebump_sessions"] == 1
    # The prebump fresh-session diff still reads the newest session.
    fresh = agent_watch._hermes_state_db_latest_session_schema_fingerprint(db, max_messages=10)
    assert fresh["session_id"] == "prebump"
