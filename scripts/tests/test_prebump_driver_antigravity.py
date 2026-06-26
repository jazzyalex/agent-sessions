# scripts/tests/test_prebump_driver_antigravity.py
import json
import sys
import time
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch_prebump_drivers as drv_mod


def test_antigravity_driver_runs_and_returns_transcript_artifact(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert argv[:2] == ["agy", "-p"]
        assert env is not None
        assert env.get("HOME") == str(sb)
        marker = next(part for part in argv[2].split() if part.startswith("AGENT_WATCH_PREBUMP_"))
        home = Path(env["HOME"])
        convo = home / ".gemini" / "antigravity-cli" / "brain" / "conv-abc"
        logs = convo / ".system_generated" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        out = logs / "transcript.jsonl"
        out.write_text(f'{{"type":"USER_INPUT","content":"hello {marker}"}}\n', encoding="utf-8")
        now = time.time() + 1
        os_utime = __import__("os").utime
        os_utime(out, (now, now))

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout="hello", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["antigravity_print"]
        res = driver.run(sb, env, "Say hello.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.name == "transcript.jsonl"
    assert ".gemini/antigravity-cli/brain" in str(res.session_path)


def test_antigravity_driver_classifies_stdout_without_brain_artifact(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        marker = next(part for part in argv[2].split() if part.startswith("AGENT_WATCH_PREBUMP_"))
        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout=f"hello {marker}", stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["antigravity_print"]
        res = driver.run(sb, env, "Say hello.", timeout=30)

    assert res.ok is False
    assert res.session_path is None
    assert res.error == "antigravity_no_transcript_artifact"


def test_antigravity_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["antigravity"]["prebump"]
    assert pb["driver"] == "antigravity_print"
    assert pb["real_home_session"] is True
    assert pb["discover_session"]["roots"] == [".gemini/antigravity-cli/brain"]
    assert pb["discover_session"]["globs"] == ["*/.system_generated/logs/transcript.jsonl"]
