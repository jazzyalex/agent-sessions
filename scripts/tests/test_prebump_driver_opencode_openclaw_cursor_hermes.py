import sqlite3
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def _write_hermes_state_db(path: Path, *, marker: str | None, started_at: float, timestamp: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT,
                model TEXT,
                model_config TEXT,
                system_prompt TEXT,
                started_at REAL,
                ended_at REAL,
                message_count INTEGER
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY,
                session_id TEXT NOT NULL,
                role TEXT,
                content TEXT,
                tool_call_id TEXT,
                tool_calls TEXT,
                tool_name TEXT,
                timestamp REAL,
                finish_reason TEXT,
                reasoning TEXT,
                reasoning_content TEXT,
                codex_reasoning_items TEXT,
                codex_message_items TEXT
            );
            """
        )
        conn.execute(
            """
            INSERT INTO sessions (id, source, model, model_config, system_prompt, started_at, ended_at, message_count)
            VALUES ('hermes_probe', 'cli', 'test-model', '{}', 'system', ?, ?, 1)
            """,
            (started_at, timestamp),
        )
        conn.execute(
            """
            INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, reasoning_content, codex_reasoning_items, codex_message_items)
            VALUES (1, 'hermes_probe', 'user', ?, NULL, NULL, NULL, ?, NULL, NULL, NULL, NULL, NULL)
            """,
            (marker or "no probe marker", timestamp),
        )
        conn.commit()
    finally:
        conn.close()


def test_opencode_driver_runs_and_returns_storage_session(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert argv[:5] == ["opencode", "run", "--pure", "--format", "json"]
        assert "--dir" in argv
        assert env is not None
        assert env["HOME"] == str(sb)
        assert env["XDG_DATA_HOME"] == str(sb / ".local" / "share")
        storage = sb / ".local" / "share" / "opencode" / "storage"
        session_dir = storage / "session" / "project-1"
        message_dir = storage / "message" / "ses_1"
        part_dir = storage / "part" / "msg_1"
        session_dir.mkdir(parents=True)
        message_dir.mkdir(parents=True)
        part_dir.mkdir(parents=True)
        (session_dir / "ses_1.json").write_text('{"id":"ses_1","title":"demo"}')
        (message_dir / "msg_1.json").write_text('{"id":"msg_1","role":"user"}')
        (part_dir / "prt_1.json").write_text('{"type":"text","text":"hi"}')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"type":"done"}\n', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["opencode_run"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".local" / "share" / "opencode" / "storage" / "session" / "project-1" / "ses_1.json"


def test_opencode_driver_accepts_current_sqlite_store(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        db = Path(env["XDG_DATA_HOME"]) / "opencode" / "opencode.db"
        db.parent.mkdir(parents=True, exist_ok=True)
        db.write_bytes(b"SQLite format 3\x00")
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["opencode_run"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".local" / "share" / "opencode" / "opencode.db"


def test_openclaw_driver_runs_and_returns_session_jsonl(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert argv[:4] == ["openclaw", "agent", "--local", "--json"]
        assert "--session-key" in argv
        assert "--message" in argv
        assert env is not None
        assert env["OPENCLAW_STATE_DIR"] == str(sb / ".openclaw")
        marker = argv[argv.index("--message") + 1].split("Include this exact marker in your final answer: ", 1)[1]
        sess = sb / ".openclaw" / "agents" / "main" / "sessions"
        sess.mkdir(parents=True)
        (sess / "ignored.trajectory.jsonl").write_text('{"type":"session"}\n')
        out = sess / "prebump.jsonl"
        out.write_text(f'{{"type":"session","id":"s1"}}\n{{"type":"message","role":"assistant","text":"{marker}"}}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name == "prebump.jsonl"


def test_openclaw_driver_discovers_real_home_session(tmp_path):
    sb = tmp_path / "sb"
    real_home = tmp_path / "realhome"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env["OPENCLAW_STATE_DIR"] == str(real_home / ".openclaw")
        marker = argv[argv.index("--message") + 1].split("Include this exact marker in your final answer: ", 1)[1]
        sess = real_home / ".openclaw" / "agents" / "main" / "sessions"
        sess.mkdir(parents=True)
        out = sess / "real-prebump.jsonl"
        out.write_text(f'{{"type":"session","id":"s1"}}\n{{"type":"message","role":"assistant","text":"{marker}"}}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    env = {"HOME": str(real_home), "AGENT_WATCH_SESSION_HOME": str(real_home)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, env, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == real_home / ".openclaw" / "agents" / "main" / "sessions" / "real-prebump.jsonl"


def test_openclaw_driver_rejects_session_without_probe_marker(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        sess = sb / ".openclaw" / "agents" / "main" / "sessions"
        sess.mkdir(parents=True)
        out = sess / "prebump.jsonl"
        out.write_text('{"type":"session","id":"s1"}\n{"type":"message","role":"assistant","text":"hello"}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "openclaw_marker_missing"


def test_openclaw_driver_selects_marker_session_over_newer_unrelated_file(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        marker = argv[argv.index("--message") + 1].split("Include this exact marker in your final answer: ", 1)[1]
        sess = sb / ".openclaw" / "agents" / "main" / "sessions"
        sess.mkdir(parents=True)
        wanted = sess / "wanted.jsonl"
        unrelated = sess / "unrelated.jsonl"
        wanted.write_text(f'{{"type":"session","id":"s1"}}\n{{"type":"message","text":"{marker}"}}\n')
        unrelated.write_text('{"type":"session","id":"s2"}\n{"type":"message","text":"hello"}\n')
        import os
        os.utime(wanted, (2000, 2000))
        os.utime(unrelated, (3000, 3000))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["openclaw_local_agent"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".openclaw" / "agents" / "main" / "sessions" / "wanted.jsonl"


def test_cursor_driver_runs_agent_print_and_returns_transcript(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert argv[:4] == ["cursor-agent", "--print", "--output-format", "stream-json"]
        assert "--mode" in argv
        assert "ask" in argv
        assert "--trust" in argv
        assert "--workspace" in argv
        assert env is not None
        assert env["HOME"] == str(sb)
        marker = argv[-1].split("Include this exact marker in your final answer: ", 1)[1]
        out_dir = sb / ".cursor" / "projects" / "repo" / "agent-transcripts" / "chat-1"
        out_dir.mkdir(parents=True)
        (out_dir / "events.jsonl").write_text(f'{{"role":"user"}}\n{{"role":"assistant","text":"{marker}"}}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"type":"done"}\n', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["cursor_agent_print"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name == "events.jsonl"


def test_cursor_driver_discovers_real_home_session(tmp_path):
    sb = tmp_path / "sb"
    real_home = tmp_path / "realhome"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env["HOME"] == str(real_home)
        marker = argv[-1].split("Include this exact marker in your final answer: ", 1)[1]
        out_dir = real_home / ".cursor" / "projects" / "repo" / "agent-transcripts" / "chat-2"
        out_dir.mkdir(parents=True)
        (out_dir / "events.jsonl").write_text(f'{{"role":"user"}}\n{{"role":"assistant","text":"{marker}"}}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"type":"done"}\n', stderr="")

    env = {"HOME": str(real_home), "AGENT_WATCH_SESSION_HOME": str(real_home)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["cursor_agent_print"].run(sb, env, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == real_home / ".cursor" / "projects" / "repo" / "agent-transcripts" / "chat-2" / "events.jsonl"


def test_cursor_driver_rejects_transcript_without_probe_marker(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        out_dir = sb / ".cursor" / "projects" / "repo" / "agent-transcripts" / "chat-3"
        out_dir.mkdir(parents=True)
        (out_dir / "events.jsonl").write_text('{"role":"user"}\n{"role":"assistant","text":"hello"}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"type":"done"}\n', stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["cursor_agent_print"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "cursor_marker_missing"


def test_cursor_driver_selects_marker_transcript_over_newer_unrelated_file(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        marker = argv[-1].split("Include this exact marker in your final answer: ", 1)[1]
        base = sb / ".cursor" / "projects" / "repo" / "agent-transcripts"
        wanted_dir = base / "chat-wanted"
        unrelated_dir = base / "chat-unrelated"
        wanted_dir.mkdir(parents=True)
        unrelated_dir.mkdir(parents=True)
        wanted = wanted_dir / "events.jsonl"
        unrelated = unrelated_dir / "events.jsonl"
        wanted.write_text(f'{{"role":"user"}}\n{{"role":"assistant","text":"{marker}"}}\n')
        unrelated.write_text('{"role":"user"}\n{"role":"assistant","text":"hello"}\n')
        import os
        os.utime(wanted, (2000, 2000))
        os.utime(unrelated, (3000, 3000))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"type":"done"}\n', stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["cursor_agent_print"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".cursor" / "projects" / "repo" / "agent-transcripts" / "chat-wanted" / "events.jsonl"


def test_hermes_driver_runs_oneshot_and_returns_session_json(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert argv[:2] == ["hermes", "--oneshot"]
        assert "--accept-hooks" in argv
        assert "--ignore-rules" in argv
        assert env is not None
        assert env["HERMES_HOME"] == str(sb / ".hermes")
        assert env["HERMES_ACCEPT_HOOKS"] == "1"
        marker = argv[2].split("Include this exact marker in your final answer: ", 1)[1]
        sess = sb / ".hermes" / "sessions"
        sess.mkdir(parents=True)
        (sess / "session_demo.json").write_text(
            f'{{"id":"demo","messages":[{{"role":"user","content":"hi"}},{{"role":"assistant","content":"hello {marker}"}}]}}'
        )
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name == "session_demo.json"


def test_hermes_driver_discovers_real_home_session(tmp_path):
    sb = tmp_path / "sb"
    real_home = tmp_path / "realhome"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env["HOME"] == str(real_home)
        assert env["HERMES_HOME"] == str(real_home / ".hermes")
        marker = argv[2].split("Include this exact marker in your final answer: ", 1)[1]
        sess = real_home / ".hermes" / "sessions"
        sess.mkdir(parents=True)
        (sess / "session_real.json").write_text(
            f'{{"id":"real","messages":[{{"role":"user","content":"hi"}},{{"role":"assistant","content":"hello {marker}"}}]}}'
        )
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    env = {"HOME": str(real_home), "AGENT_WATCH_SESSION_HOME": str(real_home)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, env, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == real_home / ".hermes" / "sessions" / "session_real.json"


def test_hermes_driver_accepts_current_state_db(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        marker = argv[2].split("Include this exact marker in your final answer: ", 1)[1]
        db = sb / ".hermes" / "state.db"
        _write_hermes_state_db(db, marker=marker, started_at=1600, timestamp=1601)
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".hermes" / "state.db"


def test_hermes_driver_rejects_fresh_state_db_without_probe_marker(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        db = sb / ".hermes" / "state.db"
        _write_hermes_state_db(db, marker=None, started_at=1600, timestamp=1601)
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "hermes_no_session_store"


def test_hermes_driver_rejects_only_stale_artifacts(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        sessions = sb / ".hermes" / "sessions"
        sessions.mkdir(parents=True, exist_ok=True)
        legacy = sessions / "session_old.json"
        legacy.write_text('{"id":"old","messages":[]}')
        db = sb / ".hermes" / "state.db"
        _write_hermes_state_db(db, marker="AGENT_WATCH_PREBUMP_old", started_at=1200, timestamp=1201)
        import os
        os.utime(legacy, (1000, 1000))
        os.utime(db, (1100, 1100))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "hermes_no_session_store"


def test_hermes_driver_accepts_fresh_sqlite_wal_activity(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        marker = argv[2].split("Include this exact marker in your final answer: ", 1)[1]
        db = sb / ".hermes" / "state.db"
        _write_hermes_state_db(db, marker=marker, started_at=1600, timestamp=1601)
        wal = sb / ".hermes" / "state.db-wal"
        wal.write_bytes(b"wal")
        import os
        os.utime(db, (1000, 1000))
        os.utime(wal, (2000, 2000))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".hermes" / "state.db"
    assert res.session_path.stat().st_mtime >= 1500


def test_hermes_driver_prefers_newer_state_db_over_legacy_json(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        marker = argv[2].split("Include this exact marker in your final answer: ", 1)[1]
        sessions = sb / ".hermes" / "sessions"
        sessions.mkdir(parents=True, exist_ok=True)
        legacy = sessions / "session_old.json"
        legacy.write_text('{"id":"old","messages":[]}')
        db = sb / ".hermes" / "state.db"
        _write_hermes_state_db(db, marker=marker, started_at=1600, timestamp=1601)
        import os
        os.utime(legacy, (1000, 1000))
        os.utime(db, (2000, 2000))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    with (
        mock.patch.object(drv_mod.time, "time", return_value=1500),
        mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run),
    ):
        res = drv_mod.DRIVERS["hermes_oneshot"].run(sb, {"HOME": str(sb)}, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path == sb / ".hermes" / "state.db"
