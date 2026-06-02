# scripts/tests/test_prebump_driver_claude.py
import json
import os
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_claude_driver_runs_and_returns_session(tmp_path, monkeypatch):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        # F3: read env explicitly, not os.environ.
        assert env is not None
        assert env.get("HOME") == str(sb)
        assert "--verbose" in argv
        home = Path(env["HOME"])
        proj = home / ".claude" / "projects" / "repo-hash"
        proj.mkdir(parents=True, exist_ok=True)
        sid = argv[argv.index("--session-id") + 1]
        out = proj / f"{sid}.jsonl"
        out.write_text('{"type":"user","content":"hi"}\n{"type":"assistant","content":"hello"}\n')

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="{}", stderr="")

    env = {"HOME": str(sb), "ANTHROPIC_API_KEY": "sk-ant-test"}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["claude_print"]
        res = driver.run(sb, env, "Say hi, then use the Bash tool to run pwd.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.suffix == ".jsonl"


def test_claude_driver_uses_model_and_real_session_home(tmp_path):
    sb = tmp_path / "sb"
    real_home = tmp_path / "realhome"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env["HOME"] == str(real_home)
        assert argv[argv.index("--model") + 1] == "sonnet"
        home = Path(env["AGENT_WATCH_SESSION_HOME"])
        proj = home / ".claude" / "projects" / "repo-hash"
        proj.mkdir(parents=True, exist_ok=True)
        sid = argv[argv.index("--session-id") + 1]
        out = proj / f"{sid}.jsonl"
        out.write_text('{"type":"user","content":"hi"}\n{"type":"assistant","content":"hello"}\n')

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="{}", stderr="")

    env = {
        "HOME": str(real_home),
        "AGENT_WATCH_SESSION_HOME": str(real_home),
        "AGENT_WATCH_MODEL": "sonnet",
    }
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["claude_print"]
        res = driver.run(sb, env, "Say hi.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert str(res.session_path).startswith(str(real_home / ".claude"))


def test_claude_driver_rejects_unrelated_newest_jsonl(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        home = Path(env["HOME"])
        proj = home / ".claude" / "projects" / "repo-hash"
        proj.mkdir(parents=True, exist_ok=True)
        unrelated = proj / "unrelated-session.jsonl"
        unrelated.write_text('{"type":"user","content":"hi"}\n{"type":"assistant","content":"hello"}\n')

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="{}", stderr="")

    env = {"HOME": str(sb), "ANTHROPIC_API_KEY": "sk-ant-test"}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["claude_print"]
        res = driver.run(sb, env, "Say hi.", timeout=30)

    assert res.ok is False
    assert res.error == "claude_no_run_session"


def test_claude_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["claude"]["prebump"]
    assert pb["driver"] == "claude_print"
    assert pb["sandbox"]["mode"] == "home_override"
    assert "ANTHROPIC_API_KEY" in pb["env_vars"]
    assert pb["model"] == "sonnet"
    assert pb["real_home_session"] is True
