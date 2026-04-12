# scripts/tests/test_prebump_driver_droid.py
import json
import os
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_droid_driver_runs_and_returns_session(tmp_path, monkeypatch):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        # F3: read env, not os.environ.
        assert env is not None
        assert env.get("HOME") == str(sb)
        home = Path(env["HOME"])
        sess = home / ".factory" / "sessions" / "01"
        sess.mkdir(parents=True, exist_ok=True)
        out = sess / "session-demo.jsonl"
        out.write_text('{"type":"message","role":"user","content":"hi"}\n{"type":"message","role":"assistant","content":"hello"}\n')

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="ok", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["droid_exec"]
        res = driver.run(sb, env, "Briefly describe this directory.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.suffix == ".jsonl"


def test_droid_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["droid"]["prebump"]
    assert pb["driver"] == "droid_exec"
    assert pb["sandbox"]["mode"] == "home_override"
