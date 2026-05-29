# scripts/tests/test_prebump_driver_pi.py
import json
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch
import agent_watch_prebump_drivers as drv_mod


def test_pi_driver_runs_and_returns_session(tmp_path):
    sb = tmp_path / "sb"
    sb.mkdir()

    def fake_run(argv, *, env=None, **kwargs):
        assert env is not None
        assert env.get("HOME") == str(sb)
        pi_home = Path(env["PI_CODING_AGENT_DIR"])
        sessions_root = Path(env["PI_CODING_AGENT_SESSION_DIR"])
        assert pi_home == sb / ".pi" / "agent"
        assert sessions_root == pi_home / "sessions"
        assert "--print" in argv
        assert "--mode" in argv and "json" in argv
        assert "--session-dir" in argv and str(sessions_root) in argv
        assert "--session-id" in argv
        assert "--no-tools" in argv

        sess_dir = sessions_root / "--tmp-project--"
        sess_dir.mkdir(parents=True, exist_ok=True)
        out = sess_dir / "2026-05-28T22-00-00-000Z_fake.jsonl"
        out.write_text(
            '{"type":"session","version":3,"id":"fake","timestamp":"2026-05-28T22:00:00.000Z","cwd":"/tmp/project"}\n'
            '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-05-28T22:00:00.001Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}\n'
            '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-05-28T22:00:00.002Z","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}\n'
        )

        import subprocess as _sp
        return _sp.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    env = {"HOME": str(sb)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver = drv_mod.DRIVERS["pi_prompt"]
        res = driver.run(sb, env, "Say hello in one sentence.", timeout=30)

    assert res.ok is True
    assert res.session_path is not None
    assert res.session_path.exists()
    assert res.session_path.suffix == ".jsonl"


def test_pi_config_has_prebump_block():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    pb = cfg["agents"]["pi"]["prebump"]
    assert pb["driver"] == "pi_prompt"
    assert pb["sandbox"]["mode"] == "home_override"
    assert "~/.pi/agent/auth.json" in pb["credential_files"]
    assert "~/.pi/agent/settings.json" in pb["support_files"]
    assert pb["discover_session"]["roots"] == [".pi/agent/sessions"]
    assert pb["discover_session"]["globs"] == ["**/*.jsonl"]
    assert pb["discover_session"]["required_types"] == ["session", "message"]


def test_pi_discovery_contract_accepts_sandbox_session(tmp_path):
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    contract = cfg["agents"]["pi"]["prebump"]["discover_session"]
    sb = tmp_path / "sb"
    session_path = sb / ".pi" / "agent" / "sessions" / "--tmp-project--" / "session.jsonl"
    session_path.parent.mkdir(parents=True)
    session_path.write_text(
        '{"type":"session","version":3,"id":"fake"}\n'
        '{"type":"message","id":"u1","message":{"role":"user","content":[]}}\n'
    )

    agent_watch._validate_session_discovery(session_path, contract, sb)
