# scripts/tests/test_prebump_driver_copilot.py
import json
import os
import sys
import time
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_copilot_driver_succeeds_without_leak(tmp_path, monkeypatch):
    real_home = tmp_path / "realhome"
    (real_home / ".copilot").mkdir(parents=True)
    (real_home / ".copilot" / "baseline.txt").write_text("keep")
    old = time.time() - 3600
    os.utime(real_home / ".copilot" / "baseline.txt", (old, old))
    monkeypatch.setenv("HOME", str(real_home))
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        sandbox_home = Path(env["HOME"])
        assert sandbox_home == sb
        sess = sandbox_home / ".copilot" / "session-state" / "uuid-1"
        sess.mkdir(parents=True, exist_ok=True)
        (sess / "events.jsonl").write_text('{"type":"session.start"}\n{"type":"session.shutdown"}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["copilot_prompt"]
        res = driver.run(sb, env, "Run ls.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name == "events.jsonl"


def test_copilot_driver_fails_on_real_home_leak(tmp_path, monkeypatch):
    real_home = tmp_path / "realhome"
    (real_home / ".copilot").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(real_home))
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        leaked = real_home / ".copilot" / "leaked.txt"
        leaked.write_text("oops")
        sb_home = Path(env["HOME"])
        sess = sb_home / ".copilot" / "session-state" / "uuid-2"
        sess.mkdir(parents=True, exist_ok=True)
        (sess / "events.jsonl").write_text('{"type":"session.start"}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["copilot_prompt"]
        res = driver.run(sb, env, "Run ls.", timeout=30)

    assert res.ok is False
    assert res.error is not None
    assert "sandbox_breach" in res.error


def test_copilot_driver_detects_deleted_file_as_leak(tmp_path, monkeypatch):
    """P2a: If copilot deletes a file from real ~/.copilot during the run,
    the deletion must be detected as a sandbox_breach."""
    real_home = tmp_path / "realhome"
    (real_home / ".copilot").mkdir(parents=True)
    victim = real_home / ".copilot" / "hosts.json"
    victim.write_text('{"token":"secret"}')
    old = time.time() - 3600
    os.utime(victim, (old, old))
    monkeypatch.setenv("HOME", str(real_home))
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        # Delete the file from real ~/.copilot during the run
        victim.unlink()
        sb_home = Path(env["HOME"])
        sess = sb_home / ".copilot" / "session-state" / "uuid-del"
        sess.mkdir(parents=True, exist_ok=True)
        (sess / "events.jsonl").write_text('{"type":"session.start"}\n')
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["copilot_prompt"]
        res = driver.run(sb, env, "Run ls.", timeout=30)

    assert res.ok is False
    assert res.error is not None
    assert "sandbox_breach" in res.error


def test_copilot_legacy_jsonl_passes_discovery(tmp_path, monkeypatch):
    """P2b: A legacy session at session-state/<id>/session-12345.jsonl
    (not events.jsonl) must pass the discovery contract after the glob
    is broadened to include **/*.jsonl."""
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    contract = cfg["agents"]["copilot"]["prebump"]["discover_session"]
    # Simulate a sandbox with a legacy session layout
    sb = tmp_path / "sb"
    root = sb / ".copilot" / "session-state"
    sess_dir = root / "uuid-legacy"
    sess_dir.mkdir(parents=True)
    sp = sess_dir / "session-12345.jsonl"
    sp.write_text('{"type":"session.start"}\n')

    import agent_watch
    # This should NOT raise _DiscoveryViolation with the broadened glob
    try:
        agent_watch._validate_session_discovery(sp, contract, sb)
        passed = True
    except agent_watch._DiscoveryViolation:
        passed = False

    assert passed, "Legacy session-12345.jsonl should pass discovery with broadened glob"


def test_allow_real_home_retries_with_real_home(tmp_path, monkeypatch):
    """P1: --allow-real-home + sandbox_breach should re-run the driver
    with real HOME and succeed (rc 0 or 2), not fail with rc 3."""
    import agent_watch
    import agent_watch_prebump_drivers as _drv

    real_home = tmp_path / "realhome"
    (real_home / ".copilot").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(real_home))

    call_count = 0

    class FakeCopilotDriver:
        name = "copilot_prompt"

        def run(self, sandbox, env, prompt, timeout):
            nonlocal call_count
            call_count += 1
            home = Path(env["HOME"])
            if home != real_home:
                # First call: sandbox HOME → simulate breach
                return _drv.DriverResult(
                    ok=False,
                    session_path=None,
                    stdout_file=sandbox / "out.txt",
                    stderr_file=sandbox / "err.txt",
                    exit_code=1,
                    error="sandbox_breach: real ~/.copilot was modified during the run: leaked.txt",
                )
            else:
                # Re-run with real HOME → write session under real_home
                sess_dir = real_home / ".copilot" / "session-state" / "uuid-retry"
                sess_dir.mkdir(parents=True, exist_ok=True)
                sp = sess_dir / "events.jsonl"
                sp.write_text('{"type":"session.start"}\n{"type":"session.shutdown"}\n')
                return _drv.DriverResult(
                    ok=True,
                    session_path=sp,
                    stdout_file=sandbox / "out.txt",
                    stderr_file=sandbox / "err.txt",
                    exit_code=0,
                    error=None,
                )

    monkeypatch.setitem(_drv.DRIVERS, "copilot_prompt", FakeCopilotDriver())

    cfg = {
        "report_root": str(tmp_path / "out"),
        "agents": {
            "copilot": {
                "installed_version_cmd": ["copilot", "--version"],
                "prebump": {
                    "driver": "copilot_prompt",
                    "sandbox": {"mode": "home_override", "subdir": "copilot_sandbox"},
                    "prompt": "Run ls.",
                    "timeout_seconds": 30,
                    "env_vars": [],
                    "credential_files": [],
                    "discover_session": {
                        "kind": "jsonl_newest",
                        "roots": [".copilot/session-state"],
                        "globs": ["**/events.jsonl", "**/*.jsonl"],
                        "required_types": [],
                    },
                },
            }
        },
    }
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)

    rc = agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--agent", "copilot",
        "--keep-sandbox",
        "--allow-real-home",
    ])

    assert call_count == 2, f"Driver should be called twice (sandbox + real HOME), got {call_count}"
    assert rc in (0, 2), f"Expected rc 0 or 2 (success), got {rc}"


def test_copilot_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["copilot"]["prebump"]
    assert pb["driver"] == "copilot_prompt"
    assert pb["sandbox"]["mode"] == "home_override"
