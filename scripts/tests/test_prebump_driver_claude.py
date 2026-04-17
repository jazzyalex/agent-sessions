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


def test_claude_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["claude"]["prebump"]
    assert pb["driver"] == "claude_print"
    assert pb["sandbox"]["mode"] == "home_override"
    assert "ANTHROPIC_API_KEY" in pb["env_vars"]
