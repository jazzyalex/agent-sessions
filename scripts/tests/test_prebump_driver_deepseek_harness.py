import json
import subprocess
import sys
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch
import agent_watch_prebump_drivers as drv_mod


def test_deepseek_harness_driver_requires_explicit_real_home(tmp_path) -> None:
    sandbox = tmp_path / "sandbox"
    sandbox.mkdir()

    result = drv_mod.DRIVERS["deepseek_harness_headless"].run(
        sandbox, {"HOME": str(sandbox)}, "Use the shell tool to run pwd.", 30
    )

    assert result.ok is False
    assert result.error == "sandbox_breach:dsh_requires_real_home"


def test_deepseek_harness_driver_returns_only_a_fresh_real_home_session(
    tmp_path,
) -> None:
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()

    def fake_run(argv, *, cwd=None, env=None, **kwargs):
        assert argv[:2] == ["dsh", "headless"]
        assert "shell tool" in argv[2]
        assert cwd == sandbox / "workspace"
        assert env is not None and env["HOME"] == str(real_home)
        project_key = drv_mod.DeepSeekHarnessHeadlessDriver._project_key(cwd.resolve())
        session = real_home / (
            f".dsh/sessions/{project_key}/session-fresh/session.v4.jsonl"
        )
        session.parent.mkdir(parents=True)
        session.write_text(
            '{"type":"session","version":4,"id":"fresh"}\n',
            encoding="utf-8",
        )
        return subprocess.CompletedProcess(argv, 0, stdout="done", stderr="")

    env = {
        "HOME": str(real_home),
        "AGENT_WATCH_SESSION_HOME": str(real_home),
    }
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["deepseek_harness_headless"].run(
            sandbox, env, "Use the shell tool to run pwd.", 30
        )

    assert result.ok is True
    assert result.session_path is not None
    assert result.session_path.name == "session.v4.jsonl"
    assert str(result.session_path).startswith(str(real_home / ".dsh/sessions"))


def test_deepseek_harness_prebump_config_requires_rich_v4_evidence() -> None:
    config = json.loads(
        (REPO / "docs/agent-support/agent-watch-config.json").read_text()
    )
    prebump = config["agents"]["deepseek_harness"]["prebump"]

    assert prebump["driver"] == "deepseek_harness_headless"
    assert prebump["real_home_session"] is True
    assert "shell tool" in prebump["prompt"]
    assert prebump["required_evidence_buckets"] == [
        "message", "tool", "usage", "relationship", "integrity"
    ]
    assert prebump["discover_session"]["roots"] == [".dsh/sessions"]
    assert prebump["discover_session"]["globs"] == [
        "**/session.v*.jsonl", "**/session.v*.jsonl.zstd"
    ]


def test_deepseek_harness_discovery_validation_does_not_enumerate_real_home(
    tmp_path, monkeypatch
) -> None:
    real_home = tmp_path / "real-home"
    session = (
        real_home
        / ".dsh/sessions/project/session-fresh/session.v4.jsonl"
    )
    session.parent.mkdir(parents=True)
    session.write_text(
        '\n'.join(
            [
                '{"type":"user/message"}',
                '{"type":"assistant/message"}',
                '{"type":"tool/call"}',
                '{"type":"tool/result"}',
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    config = json.loads(
        (REPO / "docs/agent-support/agent-watch-config.json").read_text()
    )
    contract = config["agents"]["deepseek_harness"]["prebump"][
        "discover_session"
    ]

    def reject_enumeration(*_args, **_kwargs):
        raise AssertionError("discovery validation must not enumerate the session tree")

    monkeypatch.setattr(Path, "glob", reject_enumeration)

    agent_watch._validate_session_discovery(session, contract, real_home)


def test_dsh_prebump_evidence_gate_rejects_a_text_only_session() -> None:
    fingerprint = {
        "generation": 4,
        "type_counts": {"session": 1, "user/message": 1, "assistant/message": 1},
        "type_keys": {
            "session": ["type", "version"],
            "user/message": ["data", "seq", "surfaceOp", "time", "type"],
            "assistant/message": ["data", "seq", "surfaceOp", "time", "type"],
        },
        "catalog_known_event_types": ["user/message", "assistant/message"],
        "accepted_unknown_ignorable_types": [],
        "unsupported_required_event_types": [],
        "evidence_buckets": {
            "message": True,
            "tool": False,
            "usage": False,
            "relationship": False,
            "integrity": True,
        },
        "parse_errors": 0,
        "parsed_lines": 3,
    }

    diff, matches = agent_watch._prebump_schema_check(
        fingerprint=fingerprint,
        baseline_type_keys=fingerprint["type_keys"],
        required_evidence_buckets=[
            "message", "tool", "usage", "relationship", "integrity"
        ],
        agent_name="deepseek_harness",
    )

    assert matches is False
    assert diff["missing_required_evidence_buckets"] == [
        "relationship", "tool", "usage"
    ]
