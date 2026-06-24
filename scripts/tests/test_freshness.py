# scripts/tests/test_freshness.py
import json as _json
import os
import sqlite3
from pathlib import Path as _Path
from unittest import mock

import agent_watch
from agent_watch import _resolve_cli_binary_mtime  # added in Task 1.2


def test_freshness_module_under_test_is_importable():
    # Sanity: agent_watch is on sys.path and the freshness helper that
    # Phase 1 builds out is now reachable from this test module.
    assert callable(_resolve_cli_binary_mtime)
    assert hasattr(agent_watch, "main")


def test_upstream_fetch_rate_limit_is_degraded_not_monitoring_failure():
    assert agent_watch._upstream_fetch_degraded([
        {"error": "fetch_failed", "detail": "HTTP Error 403: rate limit exceeded"}
    ])
    assert not agent_watch._upstream_fetch_degraded([
        {"error": "fetch_failed", "detail": "HTTP Error 403: forbidden"}
    ])
    assert agent_watch._upstream_fetch_degraded([
        {"error": "fetch_failed", "detail": "HTTP Error 429: too many requests"}
    ])
    assert not agent_watch._upstream_fetch_degraded([
        {"error": "fetch_failed", "detail": "HTTP Error 500: server error"}
    ])


def test_http_get_text_uses_github_token_for_api(monkeypatch):
    monkeypatch.setenv("GITHUB_TOKEN", "ghp_test")
    seen = {}

    def fake_run(argv, timeout):
        seen["argv"] = argv
        return 0, "{}", ""

    monkeypatch.setattr(agent_watch, "_run_cmd", fake_run)
    assert agent_watch._http_get_text("https://api.github.com/repos/o/r/releases/latest", timeout=5) == "{}"
    assert "Authorization: Bearer ghp_test" in seen["argv"]


def test_cached_upstream_evidence_uses_prior_successful_report(tmp_path):
    reports_root = tmp_path / "agent_watch"
    old_dir = reports_root / "20260601-120000Z"
    old_dir.mkdir(parents=True)
    report_path = old_dir / "report.json"
    report_path.write_text(_json.dumps({
        "timestamp_utc": "2026-06-01T12:00:00+00:00",
        "mode": "weekly",
        "results": {
            "codex": {
                "upstream": {
                    "parsed_version": "0.136.0",
                    "source_used": {
                        "ok": True,
                        "version": "0.136.0",
                        "url": "https://api.github.com/repos/openai/codex/releases/latest",
                    },
                },
            },
        },
    }))
    os.utime(report_path, (2_000.0, 2_000.0))

    evidence = agent_watch._latest_cached_upstream_evidence(
        agent_name="codex",
        reports_root=reports_root,
    )

    assert evidence is not None
    assert evidence["kind"] == "cached_prior_report"
    assert evidence["version"] == "0.136.0"
    assert evidence["report"].endswith("report.json")
    assert evidence["cached_source_used"]["ok"] is True


def test_cached_upstream_evidence_orders_by_report_timestamp_not_file_mtime(tmp_path):
    reports_root = tmp_path / "agent_watch"
    older_dir = reports_root / "20260601-120000Z"
    newer_dir = reports_root / "20260602-120000Z"
    older_dir.mkdir(parents=True)
    newer_dir.mkdir(parents=True)
    older_report = older_dir / "report.json"
    newer_report = newer_dir / "report.json"

    def write_report(path: _Path, ts: str, version: str) -> None:
        path.write_text(_json.dumps({
            "timestamp_utc": ts,
            "mode": "weekly",
            "results": {
                "codex": {
                    "upstream": {
                        "parsed_version": version,
                        "source_used": {
                            "ok": True,
                            "version": version,
                            "url": "https://api.github.com/repos/openai/codex/releases/latest",
                        },
                    },
                },
            },
        }))

    write_report(older_report, "2026-06-01T12:00:00+00:00", "0.135.0")
    write_report(newer_report, "2026-06-02T12:00:00+00:00", "0.136.0")
    os.utime(older_report, (3_000.0, 3_000.0))
    os.utime(newer_report, (2_000.0, 2_000.0))

    evidence = agent_watch._latest_cached_upstream_evidence(
        agent_name="codex",
        reports_root=reports_root,
    )

    assert evidence is not None
    assert evidence["version"] == "0.136.0"
    assert evidence["report_timestamp_utc"] == "2026-06-02T12:00:00+00:00"


def test_hermes_state_db_latest_session_schema_fingerprint(tmp_path):
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(db_path)
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
                codex_reasoning_items TEXT
            );
            INSERT INTO sessions (id, source, model, model_config, system_prompt, started_at, ended_at, message_count)
            VALUES ('hermes_sqlite_demo', 'cli', 'qwen3.5-9b', '{"cwd":"/tmp/hermes"}', 'system', 1780000000.0, 1780000002.0, 2);
            INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, reasoning_content, codex_reasoning_items)
            VALUES (1, 'hermes_sqlite_demo', 'user', 'hello', NULL, NULL, NULL, 1780000000.1, NULL, NULL, NULL, NULL);
            """
        )
        conn.execute(
            """
            INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, reasoning_content, codex_reasoning_items)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                2,
                "hermes_sqlite_demo",
                "assistant",
                "done",
                None,
                _json.dumps([
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "shell", "arguments": "{\"cmd\":\"pwd\"}"},
                    }
                ]),
                None,
                1780000001.0,
                None,
                "thinking",
                None,
                None,
            ),
        )
        conn.commit()
    finally:
        conn.close()

    fingerprint = agent_watch._hermes_state_db_latest_session_schema_fingerprint(db_path, max_messages=10)
    assert fingerprint["parse_errors"] == 0
    assert fingerprint["parsed_messages"] == 2
    assert fingerprint["parsed_tool_calls"] == 1
    assert fingerprint["type_counts"]["root"] == 1
    assert fingerprint["type_counts"]["message.user"] == 1
    assert fingerprint["type_counts"]["message.assistant"] == 1
    assert fingerprint["type_counts"]["tool_call.function"] == 1
    assert "tool_calls" in fingerprint["type_keys"]["message.assistant"]


def test_latest_successful_prebump_evidence_requires_fresh_matching_report(tmp_path):
    reports_root = tmp_path / "agent_watch"
    report_dir = reports_root / "20260528-120000Z-prebump"
    report_dir.mkdir(parents=True)
    report_path = report_dir / "report.json"
    report_path.write_text(_json.dumps({
        "mode": "prebump",
        "results": {
            "antigravity": {
                "ok": True,
                "session_path": "/tmp/session.md",
                "evidence": {
                    "schema_matches_baseline": True,
                    "fresh_session_matches_baseline": True,
                    "fresh_evidence_available": True,
                    "schema_diff": {"unknown_types": []},
                    "sample_freshness": {
                        "is_stale": False,
                        "stale_reason": None,
                        "sample_older_than_cli": False,
                    },
                },
            }
        },
    }))
    os.utime(report_path, (2_000.0, 2_000.0))

    evidence = agent_watch._latest_successful_prebump_evidence(
        agent_name="antigravity",
        reports_root=reports_root,
        cli_binary_mtime=1_500.0,
    )

    assert evidence is not None
    assert evidence["source"] == "latest_prebump_report"
    assert evidence["session_path"] == "/tmp/session.md"
    assert evidence["sample_freshness"]["is_stale"] is False

    stale_to_cli = agent_watch._latest_successful_prebump_evidence(
        agent_name="antigravity",
        reports_root=reports_root,
        cli_binary_mtime=2_500.0,
    )
    assert stale_to_cli is None


def test_latest_failed_prebump_evidence_classifies_auth_failure(tmp_path):
    reports_root = tmp_path / "agent_watch"
    report_dir = reports_root / "20260602-120000Z-prebump"
    agent_dir = report_dir / "claude"
    agent_dir.mkdir(parents=True)
    stdout = agent_dir / "stdout.txt"
    stderr = agent_dir / "stderr.txt"
    stdout.write_text("Not logged in · Please run /login\n")
    stderr.write_text("")
    (report_dir / "report.json").write_text(_json.dumps({
        "mode": "prebump",
        "results": {
            "claude": {
                "ok": False,
                "error": "claude_print_failed rc=1",
                "stdout_file": str(stdout),
                "stderr_file": str(stderr),
            }
        },
    }))

    evidence = agent_watch._latest_failed_prebump_evidence(
        agent_name="claude",
        reports_root=reports_root,
        cli_binary_mtime=None,
    )

    assert evidence is not None
    assert evidence["source"] == "latest_failed_prebump_report"
    assert evidence["failure_class"] == "auth_failed"
    assert evidence["error"] == "claude_print_failed rc=1"


def test_resolve_cli_binary_mtime_returns_path_and_mtime(tmp_path):
    fake_bin = tmp_path / "codex"
    fake_bin.write_text("#!/bin/sh\nexit 0\n")
    fake_bin.chmod(0o755)
    os.utime(fake_bin, (1_700_000_000, 1_700_000_000))

    with mock.patch("agent_watch.shutil.which", return_value=str(fake_bin)):
        path, mtime = agent_watch._resolve_cli_binary_mtime(["codex", "--version"])

    assert path == str(fake_bin)
    assert mtime == 1_700_000_000.0


def test_resolve_cli_binary_mtime_handles_missing_binary():
    with mock.patch("agent_watch.shutil.which", return_value=None):
        path, mtime = agent_watch._resolve_cli_binary_mtime(["nope", "--version"])
    assert path is None
    assert mtime is None


def test_resolve_cli_binary_mtime_handles_empty_cmd():
    path, mtime = agent_watch._resolve_cli_binary_mtime(None)
    assert path is None
    assert mtime is None


def test_installed_version_cmds_fall_back_after_broken_primary():
    cfg = {
        "installed_version_cmd": ["cursor", "--version"],
        "installed_version_fallback_cmds": [["/Applications/Cursor.app/Contents/Resources/app/bin/cursor", "--version"]],
    }

    def fake_run(argv, timeout):
        if argv[0] == "cursor":
            return (1, "", "No Cursor IDE installation found")
        return (0, "3.5.38\n009bb5a\narm64\n", "")

    with mock.patch("agent_watch._run_cmd", side_effect=fake_run):
        argv, rc, stdout, stderr, version = agent_watch._run_installed_version_cmds(cfg)

    assert argv == ["/Applications/Cursor.app/Contents/Resources/app/bin/cursor", "--version"]
    assert rc == 0
    assert stdout.startswith("3.5.38")
    assert stderr == ""
    assert version == "3.5.38"


def test_sample_freshness_fresh_when_sample_newer_than_cli():
    result = agent_watch._compute_sample_freshness(
        sample_mtime=2_000.0,
        cli_binary_path="/usr/local/bin/codex",
        cli_binary_mtime=1_000.0,
        freshness_window_seconds=14 * 86400,
        now_epoch=2_500.0,
        mode_context="normal",
        force_fresh=False,
    )
    assert result["is_stale"] is False
    assert result["stale_reason"] is None
    assert result["mode_context"] == "normal"
    assert result["sample_older_than_cli"] is False
    assert result["sample_older_than_window"] is False


def test_sample_freshness_stale_when_sample_older_than_cli():
    result = agent_watch._compute_sample_freshness(
        sample_mtime=1_000.0,
        cli_binary_path="/usr/local/bin/codex",
        cli_binary_mtime=2_000.0,
        freshness_window_seconds=14 * 86400,
        now_epoch=2_500.0,
        mode_context="normal",
        force_fresh=False,
    )
    assert result["is_stale"] is True
    assert result["stale_reason"] == "sample_older_than_cli"
    assert result["sample_older_than_cli"] is True


def test_sample_freshness_window_fallback_when_binary_unresolved():
    result = agent_watch._compute_sample_freshness(
        sample_mtime=0.0,
        cli_binary_path=None,
        cli_binary_mtime=None,
        freshness_window_seconds=14 * 86400,
        now_epoch=100 * 86400,
        mode_context="normal",
        force_fresh=False,
    )
    assert result["is_stale"] is True
    assert result["stale_reason"] == "cli_binary_unresolved"
    assert result["sample_older_than_cli"] is None
    assert result["sample_older_than_window"] is True


def test_sample_freshness_forced_fresh_suppresses_stale():
    result = agent_watch._compute_sample_freshness(
        sample_mtime=1_000.0,
        cli_binary_path="/usr/local/bin/codex",
        cli_binary_mtime=2_000.0,  # would normally be stale
        freshness_window_seconds=14 * 86400,
        now_epoch=3_000.0,
        mode_context="normal",
        force_fresh=True,
    )
    assert result["is_stale"] is False
    assert result["stale_reason"] == "forced_fresh"
    # flags left untouched so the operator can still see what would have fired
    assert result["sample_older_than_cli"] is None
    assert result["sample_older_than_window"] is None


def _write_jsonl(path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(_json.dumps(x) for x in lines) + "\n")


def test_weekly_run_emits_sample_freshness_block(tmp_path, monkeypatch):
    # Build a tiny fake codex session tree under a fake HOME.
    home = tmp_path / "home"
    sess = home / ".codex" / "sessions" / "2026" / "04" / "06"
    stale_file = sess / "rollout-stale.jsonl"
    _write_jsonl(stale_file, [{"type": "session_meta", "id": "x"}])
    os.utime(stale_file, (1_700_000_000, 1_700_000_000))

    fake_bin = tmp_path / "codex"
    fake_bin.write_text("#!/bin/sh\nexit 0\n")
    fake_bin.chmod(0o755)
    os.utime(fake_bin, (1_800_000_000, 1_800_000_000))  # newer than sample

    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("CODEX_HOME", str(home / ".codex"))
    monkeypatch.setattr(agent_watch.shutil, "which", lambda name: str(fake_bin) if name == "codex" else None)

    freshness = agent_watch._compute_sample_freshness(
        sample_mtime=stale_file.stat().st_mtime,
        cli_binary_path=str(fake_bin),
        cli_binary_mtime=fake_bin.stat().st_mtime,
        freshness_window_seconds=14 * 86400,
        now_epoch=fake_bin.stat().st_mtime + 10,
        mode_context="normal",
        force_fresh=False,
    )
    assert freshness["is_stale"] is True
    assert freshness["stale_reason"] == "sample_older_than_cli"
    assert set(freshness.keys()) == {
        "sample_mtime_utc", "cli_binary_mtime_utc", "cli_binary_path",
        "freshness_window_seconds", "sample_older_than_cli",
        "sample_older_than_window", "is_stale", "stale_reason", "mode_context",
    }


def test_config_freshness_windows_per_agent():
    repo = _Path(__file__).resolve().parents[2]
    cfg = _json.loads(
        (repo / "docs" / "agent-support" / "agent-watch-config.json").read_text()
    )
    hot = {"codex", "claude", "copilot"}
    cold = {"antigravity", "opencode", "openclaw"}
    for name in hot:
        w = cfg["agents"][name]["weekly"].get("freshness_window_days")
        assert w == 14, f"{name}: want 14, got {w}"
    for name in cold:
        w = cfg["agents"][name]["weekly"].get("freshness_window_days")
        assert w == 30, f"{name}: want 30, got {w}"


def test_stale_sample_blocks_bump_downgrade():
    # Simulate the override block from main() in isolation.
    severity, recommendation = agent_watch._apply_stale_override(
        severity="low",
        recommendation="bump_verified_version",
        installed_newer_than_verified=True,
        schema_matches_baseline=True,
        sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
        probe_failed=False,
    )
    assert severity == "medium"
    assert recommendation == "run_prebump_validator"


def test_fresh_sample_keeps_bump_downgrade():
    severity, recommendation = agent_watch._apply_stale_override(
        severity="low",
        recommendation="bump_verified_version",
        installed_newer_than_verified=True,
        schema_matches_baseline=True,
        sample_freshness={"is_stale": False, "stale_reason": None},
        probe_failed=False,
    )
    assert severity == "low"
    assert recommendation == "bump_verified_version"


def test_stale_override_preserves_high_severity():
    # Weekly runs can produce severity=high for reasons independent of
    # version/schema state (probe failure, monitoring failure). The stale
    # override must not silently demote those to medium even when the
    # four "would-have-bumped" conditions incidentally coincide.
    severity, recommendation = agent_watch._apply_stale_override(
        severity="high",
        recommendation="prepare_hotfix",
        installed_newer_than_verified=True,
        schema_matches_baseline=True,
        sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
        probe_failed=False,
    )
    assert severity == "high"
    assert recommendation == "prepare_hotfix"


def test_stale_override_passthrough_when_probe_failed():
    # When probe_failed is True, _pick_severity's recommendation must
    # survive — the stale override only exists to block the clean-probe
    # bump_verified_version auto-downgrade path.
    severity, recommendation = agent_watch._apply_stale_override(
        severity="medium",
        recommendation="run_weekly_now",
        installed_newer_than_verified=True,
        schema_matches_baseline=True,
        sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
        probe_failed=True,
    )
    assert severity == "medium"
    assert recommendation == "run_weekly_now"


def test_summary_line_formats_stale_token():
    line = agent_watch._format_summary_line(
        agent_name="codex",
        severity="medium",
        verified="0.119.0",
        installed="0.120.0",
        upstream="0.120.0",
        recommendation="run_prebump_validator",
        sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
    )
    assert "stale=true(sample_older_than_cli)" in line
    assert "rec=run_prebump_validator" in line


def test_summary_line_forced_fresh_reads_false_with_reason():
    line = agent_watch._format_summary_line(
        agent_name="codex",
        severity="low",
        verified="0.119.0",
        installed="0.120.0",
        upstream="0.120.0",
        recommendation="bump_verified_version",
        sample_freshness={"is_stale": False, "stale_reason": "forced_fresh"},
    )
    assert "stale=false(forced_fresh)" in line


def test_summary_line_no_reason_omits_parens():
    line = agent_watch._format_summary_line(
        agent_name="codex",
        severity="low",
        verified="0.119.0",
        installed="0.119.0",
        upstream="0.119.0",
        recommendation="monitor",
        sample_freshness={"is_stale": False, "stale_reason": None},
    )
    assert "stale=false" in line
    assert "stale=false(" not in line


def _compat(**overrides):
    base = {
        "verified": "1.0.0",
        "installed": "1.0.0",
        "upstream": "1.0.0",
        "upstream_sources_configured": True,
        "upstream_errors": [],
        "installed_newer_than_verified": False,
        "upstream_newer_than_verified": False,
        "monitoring_failed": False,
        "schema_matches_baseline": True,
        "schema_diff": {"unknown_only_is_empty": True},
        "sample_freshness": {"is_stale": False, "stale_reason": None},
        "fresh_evidence_source": None,
        "probe_failed": False,
        "real_session_driver_configured": True,
    }
    base.update(overrides)
    return agent_watch._build_compatibility_assessment(**base)


def test_compatibility_supports_latest_with_fresh_matching_evidence():
    result = _compat(fresh_evidence_source="latest_prebump_report")
    assert result["verdict"] == "supports_latest"
    assert result["scope"] == "latest"
    assert result["supports_latest"] is True
    assert result["confidence"] == "high"
    assert result["latest_status"] == "current_fetch_known"


def test_compatibility_cached_latest_does_not_hide_degraded_source():
    result = _compat(
        upstream_source_status="cached_prior_report",
        upstream_errors=[{"error": "fetch_failed", "detail": "HTTP Error 429: too many requests"}],
        fresh_evidence_source="latest_prebump_report",
    )
    assert result["latest_status"] == "cached_latest"
    assert "latest_source_degraded" in result["blockers"]
    assert result["verdict"] == "supports_installed_only"
    assert result["supports_latest"] is False


def test_compatibility_supports_latest_when_installed_is_latest_candidate():
    result = _compat(
        verified="0.135.0",
        installed="0.136.0",
        upstream="0.136.0",
        installed_newer_than_verified=True,
        upstream_newer_than_verified=True,
        fresh_evidence_source="latest_prebump_report",
    )
    assert result["verdict"] == "supports_latest"
    assert result["scope"] == "latest"
    assert result["supports_latest"] is True


def test_compatibility_does_not_support_latest_when_installed_lags_upstream():
    result = _compat(
        verified="0.136.0",
        installed="0.135.0",
        upstream="0.136.0",
        fresh_evidence_source="latest_prebump_report",
    )
    assert result["verdict"] == "supports_installed_only"
    assert result["scope"] == "installed"
    assert result["supports_latest"] is False


def test_compatibility_installed_equals_latest_without_prebump_is_installed_only():
    result = _compat(
        verified="0.135.0",
        installed="0.136.0",
        upstream="0.136.0",
        installed_newer_than_verified=True,
        upstream_newer_than_verified=True,
        fresh_evidence_source=None,
    )
    assert result["verdict"] == "supports_installed_only"
    assert result["scope"] == "installed"
    assert result["supports_installed"] is True
    assert result["supports_latest"] is False
    assert result["latest_real_session_evidence"] is False


def test_compatibility_records_missing_real_session_driver_for_latest_source():
    result = _compat(real_session_driver_configured=False)
    assert result["verdict"] == "supports_installed_only"
    assert result["supports_latest"] is False
    assert result["real_session_driver_configured"] is False
    assert "no_real_session_driver_configured" in result["blockers"]


def test_compatibility_records_missing_real_session_driver_when_latest_unknown():
    result = _compat(
        upstream=None,
        upstream_sources_configured=False,
        real_session_driver_configured=False,
    )
    assert result["verdict"] == "latest_unknown"
    assert "unknown_not_configured" in result["blockers"]
    assert "no_real_session_driver_configured" in result["blockers"]


def test_compatibility_records_failed_real_session_auth_attempt():
    result = _compat(
        failed_prebump_evidence={
            "source": "latest_failed_prebump_report",
            "failure_class": "auth_failed",
            "error": "claude_print_failed rc=1",
        }
    )
    assert result["latest_real_session_failure"]["failure_class"] == "auth_failed"
    assert "real_session_auth_failed" in result["blockers"]
    assert result["next_action"] == "restore agent auth, then rerun prebump"


def test_compatibility_latest_unknown_does_not_claim_latest_support():
    result = _compat(
        upstream=None,
        upstream_sources_configured=False,
    )
    assert result["verdict"] == "latest_unknown"
    assert result["scope"] == "installed"
    assert result["supports_latest"] is None
    assert "unknown_not_configured" in result["blockers"]


def test_compatibility_unresolved_cli_binary_blocks_latest_support():
    result = _compat(
        sample_freshness={"is_stale": False, "stale_reason": "cli_binary_unresolved"},
    )
    assert result["verdict"] == "blocked_no_fresh_evidence"
    assert result["supports_latest"] is False
    assert "cli_binary_unresolved" in result["blockers"]


def test_compatibility_monitoring_broken_clears_installed_support():
    result = _compat(probe_failed=True)
    assert result["verdict"] == "monitoring_broken"
    assert result["scope"] == "none"
    assert result["supports_installed"] is False


def test_cursor_fixture_baseline_is_available_for_prebump_diffing():
    repo = _Path(__file__).resolve().parents[2]
    matrix_obj = (repo / "docs" / "agent-support" / "agent-support-matrix.yml").read_text()
    evidence = []
    in_cursor = False
    in_evidence = False
    for raw in matrix_obj.splitlines():
        if raw.startswith("  cursor:"):
            in_cursor = True
            in_evidence = False
            continue
        if in_cursor and raw.startswith("  ") and not raw.startswith("    ") and not raw.startswith("  cursor:"):
            break
        if in_cursor and raw.strip() == "evidence_fixtures:":
            in_evidence = True
            continue
        if in_cursor and in_evidence and raw.strip().startswith("- "):
            evidence.append(raw.strip().removeprefix("- ").strip('"'))

    baseline = agent_watch._baseline_type_keys_for_agent("cursor", evidence)
    assert "user" in baseline
    assert "assistant" in baseline


def test_compatibility_schema_drift_beats_no_version_drift():
    result = _compat(
        upstream=None,
        upstream_sources_configured=False,
        schema_matches_baseline=False,
        schema_diff={
            "unknown_only_is_empty": False,
            "unknown_types": ["message.session_meta"],
            "unknown_keys": {"message.session_meta": ["role"]},
        },
    )
    assert result["verdict"] == "format_drift_detected"
    assert result["supports_installed"] is False
    assert "schema_unknowns_detected" in result["blockers"]


def test_compatibility_stale_changed_installed_blocks_support_claim():
    result = _compat(
        verified="0.76.0",
        installed="0.78.0",
        upstream=None,
        upstream_sources_configured=False,
        installed_newer_than_verified=True,
        sample_freshness={"is_stale": True, "stale_reason": "sample_older_than_cli"},
    )
    assert result["verdict"] == "blocked_stale_sample"
    assert result["scope"] == "none"
    assert result["supports_installed"] is False
    assert result["next_action"] == "run prebump validator for the affected agent"


def test_legacy_status_tracks_format_drift_blocker():
    result = _compat(
        schema_matches_baseline=False,
        schema_diff={
            "unknown_only_is_empty": False,
            "unknown_types": ["new_event"],
            "unknown_keys": {},
        },
    )
    severity, recommendation = agent_watch._apply_compatibility_to_legacy_status(
        severity="none",
        recommendation="ignore",
        compatibility=result,
    )
    assert severity == "high"
    assert recommendation == "prepare_hotfix"


def test_legacy_status_tracks_latest_unknown_blocker():
    result = _compat(upstream=None, upstream_sources_configured=False)
    severity, recommendation = agent_watch._apply_compatibility_to_legacy_status(
        severity="none",
        recommendation="ignore",
        compatibility=result,
    )
    assert severity == "low"
    assert recommendation == "monitor"


def test_weekly_report_schema_drift_not_silent(tmp_path, monkeypatch):
    sample_root = tmp_path / "sessions"
    sample_root.mkdir()
    sample = sample_root / "drift.jsonl"
    sample.write_text(_json.dumps({"type": "new_event", "foo": "bar"}) + "\n")

    report_root = tmp_path / "out"
    cfg = {
        "report_root": str(report_root),
        "agents": {
            "codex": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["codex", "--version"],
                "upstream": [],
                "risk_keywords": {"schema": [], "usage": []},
                "weekly": {
                    "local_schema": {
                        "kind": "jsonl_newest",
                        "roots": [str(sample_root)],
                        "glob": "*.jsonl",
                        "max_lines": 100,
                    }
                },
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))

    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["codex", "--version"], 0, "codex 0.135.0", "", "0.135.0"),
    )
    monkeypatch.setattr(
        agent_watch,
        "_resolve_cli_binary_mtime",
        lambda _argv: ("/tmp/fake-codex", None),
    )

    rc = agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)])
    assert rc == 0
    report_path = next(report_root.glob("*/report.json"))
    report = _json.loads(report_path.read_text())
    codex = report["results"]["codex"]
    assert codex["evidence"]["schema_matches_baseline"] is False
    assert codex["compatibility"]["verdict"] == "format_drift_detected"
    assert codex["severity"] == "high"
    assert codex["recommendation"] == "prepare_hotfix"


def test_weekly_report_uses_prebump_even_when_local_sample_is_fresh(tmp_path, monkeypatch):
    sample_root = tmp_path / "sessions"
    sample_root.mkdir()
    sample = sample_root / "rollout-fresh.jsonl"
    sample.write_text(_json.dumps({"type": "session_meta", "payload": {"id": "s1"}}) + "\n")

    report_root = tmp_path / "out"
    prebump_dir = report_root / "20260602-120000Z-prebump"
    prebump_dir.mkdir(parents=True)
    (prebump_dir / "report.json").write_text(_json.dumps({
        "mode": "prebump",
        "results": {
            "codex": {
                "ok": True,
                "session_path": str(sample),
                "evidence": {
                    "schema_matches_baseline": True,
                    "fresh_session_matches_baseline": True,
                    "fresh_evidence_available": True,
                    "schema_diff": {"unknown_only_is_empty": True},
                    "sample_freshness": {
                        "is_stale": False,
                        "stale_reason": None,
                        "sample_mtime_utc": "2026-06-02T12:00:00Z",
                        "cli_binary_mtime_utc": "2026-06-02T11:00:00Z",
                    },
                },
            }
        },
    }))

    cfg = {
        "report_root": str(report_root),
        "agents": {
            "codex": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["codex", "--version"],
                "upstream": [{"kind": "github_latest_release", "repo": "openai/codex"}],
                "risk_keywords": {"schema": [], "usage": []},
                "weekly": {
                    "local_schema": {
                        "kind": "jsonl_newest",
                        "roots": [str(sample_root)],
                        "glob": "*.jsonl",
                        "max_lines": 100,
                    }
                },
                "prebump": {"driver": "codex_exec"},
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))

    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["codex", "--version"], 0, "codex 0.136.0", "", "0.136.0"),
    )
    monkeypatch.setattr(
        agent_watch,
        "_resolve_cli_binary_mtime",
        lambda _argv: ("/tmp/fake-codex", 1_000.0),
    )
    monkeypatch.setattr(
        agent_watch,
        "_fetch_upstream",
        lambda _source, timeout: {"ok": True, "version": "0.136.0", "url": "https://example.test"},
    )

    rc = agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)])
    assert rc == 0
    report_path = sorted(p for p in report_root.glob("*/report.json") if "-prebump" not in str(p))[-1]
    report = _json.loads(report_path.read_text())
    codex = report["results"]["codex"]
    assert codex["evidence"]["fresh_evidence_source"] == "latest_prebump_report"
    assert codex["compatibility"]["latest_real_session_evidence"] is True
    assert codex["compatibility"]["verdict"] == "supports_latest"
    assert codex["compatibility"]["scope"] == "latest"


def test_weekly_report_uses_cached_upstream_after_rate_limit_without_hiding_error(tmp_path, monkeypatch):
    sample_root = tmp_path / "sessions"
    sample_root.mkdir()
    sample = sample_root / "rollout-fresh.jsonl"
    sample.write_text(_json.dumps({"type": "session_meta", "payload": {"id": "s1"}}) + "\n")

    report_root = tmp_path / "out"
    old_dir = report_root / "20260601-120000Z"
    old_dir.mkdir(parents=True)
    (old_dir / "report.json").write_text(_json.dumps({
        "timestamp_utc": "2026-06-01T12:00:00+00:00",
        "mode": "weekly",
        "results": {
            "codex": {
                "upstream": {
                    "parsed_version": "0.136.0",
                    "source_used": {
                        "ok": True,
                        "version": "0.136.0",
                        "url": "https://api.github.com/repos/openai/codex/releases/latest",
                    },
                },
            },
        },
    }))

    cfg = {
        "report_root": str(report_root),
        "agents": {
            "codex": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["codex", "--version"],
                "upstream": [{"kind": "github_latest_release", "repo": "openai/codex"}],
                "risk_keywords": {"schema": [], "usage": []},
                "weekly": {
                    "local_schema": {
                        "kind": "jsonl_newest",
                        "roots": [str(sample_root)],
                        "glob": "*.jsonl",
                        "max_lines": 100,
                    }
                },
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))

    rate_limited = {
        "ok": False,
        "error": "fetch_failed",
        "detail": "HTTP Error 429: too many requests",
        "url": "https://api.github.com/repos/openai/codex/releases/latest",
    }

    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["codex", "--version"], 0, "codex 0.136.0", "", "0.136.0"),
    )
    monkeypatch.setattr(
        agent_watch,
        "_resolve_cli_binary_mtime",
        lambda _argv: ("/tmp/fake-codex", None),
    )
    monkeypatch.setattr(agent_watch, "_fetch_upstream", lambda _source, timeout: rate_limited)

    rc = agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)])
    assert rc == 0
    report_path = sorted(p for p in report_root.glob("*/report.json") if p.parent != old_dir)[-1]
    report = _json.loads(report_path.read_text())
    codex = report["results"]["codex"]
    assert codex["upstream"]["parsed_version"] == "0.136.0"
    assert codex["upstream"]["source_status"] == "cached_prior_report"
    assert codex["upstream"]["source_used"]["kind"] == "cached_prior_report"
    assert codex["upstream"]["source_used"]["cached_source_used"]["ok"] is True
    assert codex["upstream"]["errors"] == [rate_limited]
    assert codex["risk"]["monitoring_failed"] is False
    assert codex["compatibility"]["latest_status"] == "cached_latest"
    assert "latest_source_degraded" in codex["compatibility"]["blockers"]
    assert codex["compatibility"]["verdict"] != "latest_unknown"


def test_daily_report_does_not_use_weekly_compatibility_blockers(tmp_path, monkeypatch, capsys):
    report_root = tmp_path / "out"
    cfg = {
        "report_root": str(report_root),
        "agents": {
            "codex": {
                "cadence": {"daily": True},
                "installed_version_cmd": ["codex", "--version"],
                "upstream": [],
                "risk_keywords": {"schema": [], "usage": []},
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))

    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["codex", "--version"], 0, "codex 0.135.0", "", "0.135.0"),
    )

    rc = agent_watch.main(["--mode", "daily", "--config", str(cfg_path)])
    assert rc == 0
    assert capsys.readouterr().out == ""
    report_path = next(report_root.glob("*/report.json"))
    report = _json.loads(report_path.read_text())
    codex = report["results"]["codex"]
    assert codex["severity"] == "none"
    assert codex["recommendation"] == "ignore"
    assert codex["compatibility"]["verdict"] == "not_evaluated_daily"
