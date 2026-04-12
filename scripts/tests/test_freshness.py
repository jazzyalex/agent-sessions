# scripts/tests/test_freshness.py
import json as _json
import os
from pathlib import Path as _Path
from unittest import mock

import agent_watch
from agent_watch import _resolve_cli_binary_mtime  # added in Task 1.2


def test_freshness_module_under_test_is_importable():
    # Sanity: agent_watch is on sys.path and the freshness helper that
    # Phase 1 builds out is now reachable from this test module.
    assert callable(_resolve_cli_binary_mtime)
    assert hasattr(agent_watch, "main")


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
    cold = {"gemini", "droid", "opencode", "openclaw"}
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
