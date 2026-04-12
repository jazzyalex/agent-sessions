# scripts/tests/test_prebump_driver_codex.py
import json
import os
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_codex_driver_runs_and_returns_session(tmp_path, monkeypatch):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        # F3: read the env that was actually passed into subprocess.run,
        # NOT os.environ — drivers pass env explicitly.
        assert env is not None, "driver must pass env=... to subprocess.run"
        assert env.get("HOME") == str(sb)
        codex_home = Path(env["CODEX_HOME"])
        assert str(codex_home).startswith(str(sb))
        sess_dir = codex_home / "sessions" / "2026" / "04" / "11"
        sess_dir.mkdir(parents=True, exist_ok=True)
        out = sess_dir / "rollout-fake.jsonl"
        out.write_text('{"type":"session_meta","id":"x"}\n{"type":"token_count","total":1}\n')

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="ok", stderr="")

    env = {"HOME": str(sb), "CODEX_HOME": str(sb / ".codex"), "OPENAI_API_KEY": "sk-test"}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["codex_exec"]
        res = driver.run(sb, env, "List files.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.exists()
    assert res.session_path.name.startswith("rollout-")


def test_codex_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["codex"]["prebump"]
    assert pb["driver"] == "codex_exec"
    assert pb["sandbox"]["mode"] == "home_override"
    assert isinstance(pb["prompt"], str) and pb["prompt"].strip()
    assert pb["discover_session"]["globs"][0].endswith(".jsonl")
    assert pb["discover_session"]["roots"] == [".codex/sessions"]
    assert "session_meta" in pb["discover_session"]["required_types"]
