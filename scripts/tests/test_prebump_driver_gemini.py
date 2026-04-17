# scripts/tests/test_prebump_driver_gemini.py
import json
import os
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_gemini_driver_runs_and_returns_session(tmp_path, monkeypatch):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env.get("HOME") == str(sb)
        home = Path(env["HOME"])
        proj = home / ".gemini" / "tmp" / "abc123" / "chats"
        proj.mkdir(parents=True, exist_ok=True)
        out = proj / "session-demo.json"
        out.write_text(json.dumps({"messages": [{"type": "user", "text": "hi"}, {"type": "gemini", "text": "hello"}]}))

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    env = {"HOME": str(sb), "GEMINI_API_KEY": "g-test"}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["gemini_prompt"]
        res = driver.run(sb, env, "Say hello and list files.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name.startswith("session-")


def test_gemini_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["gemini"]["prebump"]
    assert pb["driver"] == "gemini_prompt"
    assert "GEMINI_API_KEY" in pb["env_vars"]
    assert "~/.gemini/settings.json" in pb["support_files"]
    assert pb["discover_session"]["globs"][0].endswith(".json")
