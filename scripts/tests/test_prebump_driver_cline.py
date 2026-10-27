"""Cline prebump driver: real-home gate, session selection, tool-turn proof, config."""
import json
import os
import subprocess
import sys
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch
import agent_watch_prebump_drivers as drv_mod

PROMPT = "Use your tools to list the files in the current directory, then read a.txt."


def _write_session(sessions_root: Path, session_id: str, cwd: Path, *, tool_turn: bool) -> Path:
    session_dir = sessions_root / session_id
    session_dir.mkdir(parents=True)
    manifest = session_dir / f"{session_id}.json"
    manifest.write_text(json.dumps({
        "version": 1,
        "session_id": session_id,
        "source": "cli",
        "cwd": str(cwd),
        "metadata": {"sessionHistoryOrigin": {"version": "3.0.73"}},
    }))
    messages = [
        {"role": "user", "content": [{"type": "text", "text": "hi"}]},
    ]
    if tool_turn:
        messages += [
            {"role": "assistant", "content": [
                {"type": "text", "text": "listing"},
                {"type": "tool_use", "id": "t1", "name": "run_commands", "input": {}},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "t1", "name": "run_commands", "content": "a.txt"},
            ]},
        ]
    messages.append({"role": "assistant", "content": [{"type": "text", "text": "done"}]})
    (session_dir / f"{session_id}.messages.json").write_text(json.dumps({
        "version": 1, "sessionId": session_id, "messages": messages,
    }))
    return manifest


def _real_home_env(real_home: Path) -> dict[str, str]:
    return {"HOME": str(real_home), "AGENT_WATCH_SESSION_HOME": str(real_home)}


def test_cline_driver_requires_explicit_real_home(tmp_path):
    sandbox = tmp_path / "sandbox"
    sandbox.mkdir()

    with mock.patch.object(drv_mod.subprocess, "run") as run:
        result = drv_mod.DRIVERS["cline_headless"].run(
            sandbox, {"HOME": str(sandbox)}, PROMPT, 30
        )

    run.assert_not_called()
    assert result.ok is False
    assert result.exit_code == 4
    assert result.error == "sandbox_breach:cline_requires_real_home"


def test_cline_driver_returns_fresh_manifest_with_tool_turn(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()
    sessions_root = real_home / ".cline" / "data" / "sessions"
    seen = {}

    def fake_run(argv, *, cwd=None, env=None, **kwargs):
        assert argv[0] == "cline"
        assert "--json" in argv
        assert argv[argv.index("-c") + 1] == str(sandbox / "workspace")
        assert argv[-1] == PROMPT
        assert 30 <= int(argv[argv.index("-t") + 1]) < 240
        assert cwd == sandbox / "workspace"
        assert (cwd / "a.txt").read_text().strip()
        assert env["HOME"] == str(real_home)
        seen["manifest"] = _write_session(sessions_root, "1_fresh", cwd, tool_turn=True)
        return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["cline_headless"].run(
            sandbox, _real_home_env(real_home), PROMPT, 240
        )

    assert result.ok is True
    assert result.session_path == seen["manifest"]
    assert result.session_path.name == "1_fresh.json"


def test_cline_driver_rejects_text_only_session(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()

    def fake_run(argv, *, cwd=None, **kwargs):
        _write_session(real_home / ".cline/data/sessions", "1_text", cwd, tool_turn=False)
        return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["cline_headless"].run(
            sandbox, _real_home_env(real_home), PROMPT, 240
        )

    assert result.ok is False
    assert result.error == "cline_tool_turn_missing"


def test_cline_driver_ignores_other_directories_and_stale_sessions(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()
    sessions_root = real_home / ".cline" / "data" / "sessions"
    stale = _write_session(sessions_root, "1_stale", sandbox / "workspace", tool_turn=True)
    old = stale.stat().st_mtime - 3600
    os.utime(stale, (old, old))

    def fake_run(argv, **kwargs):
        # A concurrent Cline run in an unrelated directory must not be picked up.
        _write_session(sessions_root, "2_other", tmp_path / "elsewhere", tool_turn=True)
        return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["cline_headless"].run(
            sandbox, _real_home_env(real_home), PROMPT, 240
        )

    assert result.ok is False
    assert result.session_path is None
    assert result.error == "cline_no_fresh_session"


def test_cline_driver_honors_cline_data_dir(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    data_dir = tmp_path / "custom-data"
    sandbox.mkdir()

    def fake_run(argv, *, cwd=None, **kwargs):
        _write_session(data_dir / "sessions", "1_custom", cwd, tool_turn=True)
        return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")

    env = _real_home_env(real_home) | {"CLINE_DATA_DIR": str(data_dir)}
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["cline_headless"].run(sandbox, env, PROMPT, 240)

    assert result.ok is True
    assert str(result.session_path).startswith(str(data_dir / "sessions"))


def test_cline_driver_flags_authentication_failures(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()

    def fake_run(argv, **kwargs):
        return subprocess.CompletedProcess(
            argv, 1, stdout="", stderr="Error: not authenticated. Run cline auth."
        )

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        result = drv_mod.DRIVERS["cline_headless"].run(
            sandbox, _real_home_env(real_home), PROMPT, 240
        )

    assert result.ok is False
    assert result.error == "cline_headless_failed rc=1 authentication_failed"


def test_cline_driver_maps_timeout_and_missing_binary(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()
    env = _real_home_env(real_home)
    driver = drv_mod.DRIVERS["cline_headless"]

    with mock.patch.object(
        drv_mod.subprocess, "run", side_effect=subprocess.TimeoutExpired("cline", 5)
    ):
        assert driver.run(sandbox, env, PROMPT, 5).error == "timeout:5"
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=FileNotFoundError("cline")):
        assert driver.run(sandbox, env, PROMPT, 5).error == "cline_not_found"


def test_cline_driver_passes_configured_model(tmp_path):
    sandbox = tmp_path / "sandbox"
    real_home = tmp_path / "real-home"
    sandbox.mkdir()
    seen = {}

    def fake_run(argv, **kwargs):
        seen["argv"] = argv
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

    driver = drv_mod.DRIVERS["cline_headless"]
    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver.run(sandbox, {**_real_home_env(real_home), "AGENT_WATCH_MODEL": "cline-free/x"}, PROMPT, 240)
    assert seen["argv"][seen["argv"].index("-m") + 1] == "cline-free/x"
    assert seen["argv"][-1] == PROMPT

    with mock.patch.object(drv_mod.subprocess, "run", side_effect=fake_run):
        driver.run(sandbox, _real_home_env(real_home), PROMPT, 240)
    assert "-m" not in seen["argv"]


def _prebump_config() -> dict:
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    return cfg["agents"]["cline"]["prebump"]


def test_cline_config_declares_real_home_tool_using_prebump():
    pb = _prebump_config()
    assert pb["driver"] == "cline_headless"
    assert pb["model"].startswith("cline-free/")
    assert pb["real_home_session"] is True
    assert pb["credential_files"] == [] and pb["env_vars"] == []
    assert "Use your tools" in pb["prompt"] and "a.txt" in pb["prompt"]
    assert pb["discover_session"]["roots"] == [".cline/data/sessions"]
    assert pb["discover_session"]["globs"] == ["*/*.json"]
    assert {"content.tool_use", "content.tool_result"} <= set(pb["required_schema_buckets"])
    assert agent_watch.MATRIX_KEY_FOR_AGENT["cline"] == "cline"
    assert pb["driver"] in drv_mod.DRIVERS


def test_cline_discovery_contract_accepts_real_store_manifest_only(tmp_path):
    contract = _prebump_config()["discover_session"]
    real_home = tmp_path / "real-home"
    manifest = _write_session(
        real_home / ".cline/data/sessions", "1_ok", tmp_path / "w", tool_turn=True
    )

    agent_watch._validate_session_discovery(manifest, contract, real_home)

    outside = tmp_path / "other" / "1_ok" / "1_ok.json"
    outside.parent.mkdir(parents=True)
    outside.write_text("{}")
    try:
        agent_watch._validate_session_discovery(outside, contract, real_home)
    except agent_watch._DiscoveryViolation:
        pass
    else:
        raise AssertionError("a manifest outside the declared root must be rejected")


def test_cline_prebump_schema_check_compares_against_a_real_baseline(tmp_path):
    """A tool-using fresh session passes against the committed fixtures; a text-only one cannot."""
    pb = _prebump_config()
    fixtures = REPO / "Resources/Fixtures/stage0/agents/cline"
    baseline = agent_watch._baseline_type_keys_for_agent(
        "cline",
        [
            str(fixtures / "cli_tool/cline-cli-tool.json"),
            str(fixtures / "desktop_continued/cline-desktop-continued.json"),
        ],
    )
    assert baseline, "baseline must be non-empty or the diff compares nothing"

    tool_manifest = _write_session(tmp_path / "a", "1_tool", tmp_path / "w", tool_turn=True)
    fingerprint = agent_watch._cline_session_schema_fingerprint(tool_manifest)
    _diff, matches = agent_watch._prebump_schema_check(
        fingerprint=fingerprint,
        baseline_type_keys=baseline,
        required_schema_buckets=pb["required_schema_buckets"],
        agent_name="cline",
    )
    assert _diff["missing_required_schema_buckets"] == []

    text_manifest = _write_session(tmp_path / "b", "1_text", tmp_path / "w", tool_turn=False)
    text_diff, text_matches = agent_watch._prebump_schema_check(
        fingerprint=agent_watch._cline_session_schema_fingerprint(text_manifest),
        baseline_type_keys=baseline,
        required_schema_buckets=pb["required_schema_buckets"],
        agent_name="cline",
    )
    assert text_matches is False
    assert "content.tool_use" in text_diff["missing_required_schema_buckets"]


def test_cline_prebump_end_to_end_fingerprints_manifest_and_transcript(tmp_path, monkeypatch):
    """Regression: the prebump path once fell back to the JSONL fingerprint for Cline,
    read zero events from pretty JSON, and reported a full baseline as missing."""
    real_home = tmp_path / "home"
    fixtures = REPO / "Resources/Fixtures/stage0/agents/cline/cli_tool"
    real_cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    cfg = {
        "report_root": str(tmp_path / "out"),
        "agents": {"cline": {
            "installed_version_cmd": ["cline", "--version"],
            "prebump": dict(real_cfg["agents"]["cline"]["prebump"], driver="fake_cline"),
        }},
    }
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))

    class _FixtureDriver:
        name = "fake_cline"

        def run(self, sandbox, env, prompt, timeout):
            session = real_home / ".cline/data/sessions/1_e2e"
            session.mkdir(parents=True)
            manifest = session / "1_e2e.json"
            manifest.write_text((fixtures / "cline-cli-tool.json").read_text())
            (session / "1_e2e.messages.json").write_text(
                (fixtures / "cline-cli-tool.messages.json").read_text()
            )
            return drv_mod.DriverResult(
                True, manifest, sandbox / "o.txt", sandbox / "e.txt", 0, None
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake_cline", _FixtureDriver())
    monkeypatch.setenv("HOME", str(real_home))
    monkeypatch.chdir(REPO)

    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "cline", "--allow-real-home",
    ])

    report = json.loads(next((tmp_path / "out").glob("*-prebump/report.json")).read_text())
    evidence = report["results"]["cline"]["evidence"]
    diff = evidence["schema_diff"]
    assert diff["baseline_type_count"] > 0
    assert diff["observation_nonempty"] is True
    assert diff["missing_required_schema_buckets"] == []
    assert evidence["fresh_session_matches_baseline"] is True
    assert rc == 0
