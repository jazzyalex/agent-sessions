# scripts/tests/test_prebump_framework.py
import json
import os
import stat
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch


def test_prebump_mode_argparse_accepts_new_flags(tmp_path, monkeypatch, capsys):
    cfg = {
        "report_root": str(tmp_path / "out"),
        "agents": {},
    }
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)  # agent_watch reads matrix yml via relative path
    rc = agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--keep-sandbox",
        "--timeout-seconds", "30",
        "--allow-real-home",
    ])
    # No agents configured for prebump and no --agent restriction → exit 0.
    assert rc == 0


def test_prebump_mode_unknown_agent_exits_4(tmp_path, monkeypatch, capsys):
    cfg = {
        "report_root": str(tmp_path / "out"),
        "agents": {},  # nothing has a prebump block
    }
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--agent", "codex",  # not in configured_prebump_agents
    ])
    assert rc == 4
    err = capsys.readouterr().err
    assert "codex" in err
    assert "prebump" in err.lower()


def test_driver_protocol_and_result_dataclass():
    from agent_watch_prebump_drivers import PrebumpDriver, DriverResult, DRIVERS
    assert hasattr(PrebumpDriver, "run")
    res = DriverResult(
        ok=True,
        session_path=Path("/tmp/x"),
        stdout_file=Path("/tmp/o"),
        stderr_file=Path("/tmp/e"),
        exit_code=0,
        error=None,
    )
    assert res.ok is True
    assert "codex_exec" in DRIVERS  # filled in by Task 3.1+


def test_sandbox_creates_temp_home_and_teardown(tmp_path):
    from agent_watch_prebump_drivers import make_sandbox, teardown_sandbox
    sb = make_sandbox(parent=tmp_path, label="codex")
    assert sb.exists()
    assert sb.is_dir()
    assert "codex" in sb.name
    teardown_sandbox(sb, keep=False)
    assert not sb.exists()


def test_sandbox_keep_preserves_dir(tmp_path):
    from agent_watch_prebump_drivers import make_sandbox, teardown_sandbox
    sb = make_sandbox(parent=tmp_path, label="claude")
    (sb / "marker.txt").write_text("x")
    teardown_sandbox(sb, keep=True)
    assert sb.exists()
    assert (sb / "marker.txt").read_text() == "x"


def _make_cred(tmp_path, name, content="secret", mode=0o600, age_days=0):
    p = tmp_path / name
    p.write_text(content)
    os.chmod(p, mode)
    if age_days:
        ts = time.time() - age_days * 86400
        os.utime(p, (ts, ts))
    return p


def test_credential_hygiene_accepts_small_mode0600_recent(tmp_path):
    from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
    p = _make_cred(tmp_path, "auth.json", mode=0o600)
    warnings = check_credential_hygiene(p)
    assert warnings == []


def test_credential_hygiene_rejects_oversize(tmp_path):
    from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
    p = tmp_path / "huge.json"
    p.write_text("x" * (65 * 1024))
    os.chmod(p, 0o600)
    try:
        check_credential_hygiene(p)
    except HygieneError as e:
        assert "64" in str(e) or "size" in str(e).lower()
    else:
        raise AssertionError("expected HygieneError for oversize file")


def test_credential_hygiene_rejects_world_readable(tmp_path):
    from agent_watch_prebump_drivers import check_credential_hygiene, HygieneError
    p = _make_cred(tmp_path, "auth.json", mode=0o644)
    try:
        check_credential_hygiene(p)
    except HygieneError as e:
        assert "0600" in str(e)
    else:
        raise AssertionError("expected HygieneError for 0644")


def test_credential_hygiene_warns_on_old_mtime(tmp_path):
    from agent_watch_prebump_drivers import check_credential_hygiene
    p = _make_cred(tmp_path, "auth.json", mode=0o600, age_days=120)
    warnings = check_credential_hygiene(p)
    assert any("90" in w or "old" in w.lower() for w in warnings)


def test_prepare_auth_uses_env_var_when_set(tmp_path, monkeypatch):
    from agent_watch_prebump_drivers import prepare_auth
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-xyz")
    sb = tmp_path / "sb"
    sb.mkdir()
    pb_cfg = {
        "env_vars": ["OPENAI_API_KEY"],
        "credential_files": [str(tmp_path / "auth.json")],  # must NOT be read
    }
    env, warnings = prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=tmp_path)
    assert env["OPENAI_API_KEY"] == "sk-test-xyz"
    assert env["HOME"] == str(sb)
    assert warnings == []


def test_prepare_auth_copies_credential_when_env_missing(tmp_path, monkeypatch):
    from agent_watch_prebump_drivers import prepare_auth
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    real_home = tmp_path / "realhome"
    real_home.mkdir()
    cred = real_home / ".codex" / "auth.json"
    cred.parent.mkdir()
    cred.write_text('{"token":"abc"}')
    os.chmod(cred, 0o600)

    sb = tmp_path / "sb"
    sb.mkdir()
    pb_cfg = {
        "env_vars": ["OPENAI_API_KEY"],
        "credential_files": [str(cred)],
    }
    env, warnings = prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=real_home)
    copied = sb / ".codex" / "auth.json"
    assert copied.exists()
    assert copied.read_text() == '{"token":"abc"}'
    assert "OPENAI_API_KEY" not in env
    assert env["HOME"] == str(sb)


def test_prepare_auth_copies_support_files_without_strict_mode(tmp_path, monkeypatch):
    from agent_watch_prebump_drivers import prepare_auth
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    real_home = tmp_path / "realhome"
    (real_home / ".gemini").mkdir(parents=True)
    settings = real_home / ".gemini" / "settings.json"
    settings.write_text('{"security":{"auth":{"selectedType":"oauth-personal"}}}')
    os.chmod(settings, 0o644)

    sb = tmp_path / "sb"
    sb.mkdir()
    pb_cfg = {
        "env_vars": ["GEMINI_API_KEY"],
        "credential_files": [],
        "support_files": [str(settings)],
    }
    env, warnings = prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=real_home)
    copied = sb / ".gemini" / "settings.json"
    assert copied.exists()
    assert copied.read_text() == settings.read_text()
    assert oct(copied.stat().st_mode & 0o777) == "0o600"
    assert env["HOME"] == str(sb)
    assert warnings == []


def test_prepare_auth_raises_on_hygiene_failure(tmp_path, monkeypatch):
    from agent_watch_prebump_drivers import prepare_auth, HygieneError
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    real_home = tmp_path / "realhome"
    (real_home / ".codex").mkdir(parents=True)
    cred = real_home / ".codex" / "auth.json"
    cred.write_text("x" * 16)
    os.chmod(cred, 0o644)  # world-readable → hard fail
    sb = tmp_path / "sb"
    sb.mkdir()
    pb_cfg = {"env_vars": ["OPENAI_API_KEY"], "credential_files": [str(cred)]}
    try:
        prepare_auth(prebump_cfg=pb_cfg, sandbox=sb, real_home=real_home)
    except HygieneError:
        pass
    else:
        raise AssertionError("expected HygieneError")


def test_build_prebump_report_shape(tmp_path):
    from agent_watch import _build_prebump_report_entry
    entry = _build_prebump_report_entry(
        agent_name="codex",
        driver_name="codex_exec",
        ok=True,
        session_path=tmp_path / "session.jsonl",
        stdout_file=tmp_path / "stdout.txt",
        stderr_file=tmp_path / "stderr.txt",
        error=None,
        schema_diff={"is_empty": True, "unknown_types": [], "missing_types": [], "unknown_keys": {}, "missing_keys": {}, "unknown_only_is_empty": True},
        fresh_session_matches_baseline=True,
        sample_freshness={"is_stale": False, "stale_reason": "forced_fresh", "mode_context": "normal", "sample_mtime_utc": None, "cli_binary_mtime_utc": None, "cli_binary_path": None, "freshness_window_seconds": 1209600, "sample_older_than_cli": None, "sample_older_than_window": None},
    )
    assert entry["driver"] == "codex_exec"
    assert entry["ok"] is True
    ev = entry["evidence"]
    assert ev["fresh_session_matches_baseline"] is True
    # Spec §3.1: fresh_evidence_available is true ONLY when prebump
    # produced fresh evidence AND it matched baseline.
    assert ev["fresh_evidence_available"] is True
    assert ev["schema_matches_baseline"] is True
    assert ev["sample_freshness"]["stale_reason"] == "forced_fresh"


def test_exit_code_for_prebump_results():
    from agent_watch import _exit_code_for_prebump
    assert _exit_code_for_prebump([{"ok": True, "evidence": {"fresh_session_matches_baseline": True}}]) == 0
    assert _exit_code_for_prebump([{"ok": True, "evidence": {"fresh_session_matches_baseline": False}}]) == 2
    assert _exit_code_for_prebump([{"ok": False, "error": "cli_failed"}]) == 3
    assert _exit_code_for_prebump([{"ok": False, "error": "hygiene_failed", "fatal": "config"}]) == 4
    # worst wins: any 4 beats 3 beats 2 beats 0
    assert _exit_code_for_prebump([
        {"ok": True, "evidence": {"fresh_session_matches_baseline": True}},
        {"ok": False, "error": "cli_failed"},
        {"ok": False, "error": "hygiene_failed", "fatal": "config"},
    ]) == 4


def _make_codex_cfg(tmp_path, *, timeout_cfg=10, required_types=("session_meta",)):
    return {
        "report_root": str(tmp_path / "out"),
        "agents": {
            "codex": {
                "installed_version_cmd": ["codex", "--version"],
                "prebump": {
                    "driver": "fake",
                    "sandbox": {"mode": "home_override", "subdir": "codex_sandbox"},
                    "prompt": "hi",
                    "timeout_seconds": timeout_cfg,
                    "env_vars": [],
                    "credential_files": [],
                    "discover_session": {
                        "kind": "jsonl_newest",
                        "roots": [".codex/sessions"],
                        "globs": ["**/*.jsonl"],
                        "required_types": list(required_types),
                    },
                },
            }
        },
    }


class _FakeGoodDriver:
    name = "fake"

    def __init__(self):
        self.last_env = None
        self.last_timeout = None

    def run(self, sandbox, env, prompt, timeout):
        import agent_watch_prebump_drivers as drv_mod
        self.last_env = dict(env)
        self.last_timeout = timeout
        # Write a session under the configured discovery root so
        # _validate_session_discovery passes.
        sp_dir = sandbox / ".codex" / "sessions"
        sp_dir.mkdir(parents=True, exist_ok=True)
        sp = sp_dir / "rollout-fake.jsonl"
        sp.write_text('{"type":"session_meta","id":"x"}\n')
        return drv_mod.DriverResult(
            ok=True,
            session_path=sp,
            stdout_file=sandbox / "out.txt",
            stderr_file=sandbox / "err.txt",
            exit_code=0,
            error=None,
        )


def test_run_prebump_uses_registered_driver_and_writes_report(tmp_path, monkeypatch):
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    fake = _FakeGoodDriver()
    monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)

    cfg = _make_codex_cfg(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--agent", "codex",
        "--keep-sandbox",
    ])
    assert rc in (0, 2)  # driver ran cleanly; baseline diff may vary
    reports = list((tmp_path / "out").glob("*-prebump/report.json"))
    assert len(reports) == 1
    report = json.loads(reports[0].read_text())
    assert report["mode"] == "prebump"
    codex_entry = report["results"]["codex"]
    assert codex_entry["driver"] == "fake"
    assert codex_entry["ok"] is True
    # F2: env was constructed by prepare_auth and passed in.
    assert "HOME" in fake.last_env
    assert fake.last_env["HOME"] != os.environ.get("HOME", "")


def test_run_prebump_timeout_cli_overrides_config(tmp_path, monkeypatch):
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    fake = _FakeGoodDriver()
    monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)

    cfg = _make_codex_cfg(tmp_path, timeout_cfg=180)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--agent", "codex",
        "--timeout-seconds", "30",
        "--keep-sandbox",
    ])
    # CLI flag (30) wins over per-agent config (180).
    assert fake.last_timeout == 30


def test_run_prebump_timeout_falls_back_to_config_when_cli_absent(tmp_path, monkeypatch):
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    fake = _FakeGoodDriver()
    monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)
    cfg = _make_codex_cfg(tmp_path, timeout_cfg=77)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    agent_watch.main([
        "--mode", "prebump",
        "--config", str(cfg_path),
        "--agent", "codex",
        "--keep-sandbox",
    ])
    assert fake.last_timeout == 77


def test_run_prebump_discovery_violation_maps_to_exit_3(tmp_path, monkeypatch):
    """F4: a driver that returns a session outside the declared roots
    or missing required_types is a driver-failed result (exit 3)."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    class _BadRootDriver:
        name = "fake"

        def run(self, sandbox, env, prompt, timeout):
            # Write outside .codex/sessions → root violation
            bad = sandbox / "elsewhere" / "rollout.jsonl"
            bad.parent.mkdir(parents=True, exist_ok=True)
            bad.write_text('{"type":"session_meta"}\n')
            return drv_mod.DriverResult(
                ok=True, session_path=bad,
                stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                exit_code=0, error=None,
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _BadRootDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 3


def test_run_prebump_discovery_nested_glob_pattern_matches(tmp_path, monkeypatch):
    """B: the **/ rewrite must match a file two directories below root."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    class _NestedDriver:
        name = "fake"

        def run(self, sandbox, env, prompt, timeout):
            # Two levels below .codex/sessions: .codex/sessions/2026/04/11/
            deep = sandbox / ".codex" / "sessions" / "2026" / "04" / "11"
            deep.mkdir(parents=True, exist_ok=True)
            sp = deep / "rollout-nested.jsonl"
            sp.write_text('{"type":"session_meta","id":"x"}\n')
            return drv_mod.DriverResult(
                ok=True, session_path=sp,
                stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                exit_code=0, error=None,
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _NestedDriver())
    cfg = _make_codex_cfg(tmp_path)
    # Pattern with ** must match a nested file under the root.
    cfg["agents"]["codex"]["prebump"]["discover_session"]["globs"] = ["**/rollout-*.jsonl"]
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc in (0, 2)


def test_run_prebump_config_gate_missing_discover_session(tmp_path, monkeypatch):
    """A: selected agent with no prebump.discover_session exits 4."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg["agents"]["codex"]["prebump"].pop("discover_session", None)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 4


def test_run_prebump_config_gate_empty_roots(tmp_path, monkeypatch, capsys):
    """A: roots: [] exits 4 with a stderr message naming the agent."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg["agents"]["codex"]["prebump"]["discover_session"]["roots"] = []
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 4
    err = capsys.readouterr().err
    assert "codex" in err
    assert "roots" in err


def test_run_prebump_config_gate_allows_empty_required_types(tmp_path, monkeypatch):
    """A: valid contract with required_types: [] passes the gate
    (Copilot case — must not regress)."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _FakeGoodDriver())
    cfg = _make_codex_cfg(tmp_path, required_types=())
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc in (0, 2)


def test_run_prebump_discovery_missing_required_type_maps_to_exit_3(tmp_path, monkeypatch):
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    class _NoTypesDriver:
        name = "fake"

        def run(self, sandbox, env, prompt, timeout):
            sp_dir = sandbox / ".codex" / "sessions"
            sp_dir.mkdir(parents=True, exist_ok=True)
            sp = sp_dir / "rollout.jsonl"
            # Has 'token_count' but no 'session_meta' → required_types fail
            sp.write_text('{"type":"token_count","total":1}\n')
            return drv_mod.DriverResult(
                ok=True, session_path=sp,
                stdout_file=sandbox / "o", stderr_file=sandbox / "e",
                exit_code=0, error=None,
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _NoTypesDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 3


def test_run_prebump_driver_claims_ok_but_no_session_exits_3(tmp_path, monkeypatch):
    """P1: a driver that returns ok=True with session_path=None is a
    silently-broken driver and must not pass the gate."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    class _NoSessionDriver:
        name = "fake"

        def run(self, sandbox, env, prompt, timeout):
            return drv_mod.DriverResult(
                ok=True,
                session_path=None,
                stdout_file=sandbox / "o",
                stderr_file=sandbox / "e",
                exit_code=0,
                error=None,
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _NoSessionDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 3
    reports = list((tmp_path / "out").glob("*-prebump/report.json"))
    entry = json.loads(reports[0].read_text())["results"]["codex"]
    assert entry["ok"] is False
    assert entry["error"] == "no_session_produced"


def test_run_prebump_driver_claims_ok_but_session_missing_exits_3(tmp_path, monkeypatch):
    """P1: a driver that returns ok=True with a session_path that does
    not exist is also a silently-broken driver."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    class _GhostSessionDriver:
        name = "fake"

        def run(self, sandbox, env, prompt, timeout):
            ghost = sandbox / ".codex" / "sessions" / "does-not-exist.jsonl"
            return drv_mod.DriverResult(
                ok=True,
                session_path=ghost,  # never written
                stdout_file=sandbox / "o",
                stderr_file=sandbox / "e",
                exit_code=0,
                error=None,
            )

    monkeypatch.setitem(drv_mod.DRIVERS, "fake", _GhostSessionDriver())
    cfg = _make_codex_cfg(tmp_path)
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc == 3
    reports = list((tmp_path / "out").glob("*-prebump/report.json"))
    entry = json.loads(reports[0].read_text())["results"]["codex"]
    assert entry["ok"] is False
    assert entry["error"] == "no_session_produced"


def test_run_prebump_surfaces_stale_credential_warning(tmp_path, monkeypatch, capsys):
    """P2: prepare_auth warnings (stale credential) must land in stderr
    AND in the report entry's evidence.auth_warnings list."""
    import agent_watch
    import agent_watch_prebump_drivers as drv_mod

    # Real credential file, passes size+mode hygiene but is old.
    real_home = tmp_path / "realhome"
    cred = real_home / ".codex" / "auth.json"
    cred.parent.mkdir(parents=True)
    cred.write_text('{"token":"abc"}')
    os.chmod(cred, 0o600)
    old_ts = time.time() - 120 * 86400
    os.utime(cred, (old_ts, old_ts))
    monkeypatch.setenv("HOME", str(real_home))
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    fake = _FakeGoodDriver()
    monkeypatch.setitem(drv_mod.DRIVERS, "fake", fake)

    cfg = _make_codex_cfg(tmp_path)
    cfg["agents"]["codex"]["prebump"]["env_vars"] = ["OPENAI_API_KEY"]
    cfg["agents"]["codex"]["prebump"]["credential_files"] = [str(cred)]
    cfg_path = tmp_path / "cfg.json"
    cfg_path.write_text(json.dumps(cfg))
    monkeypatch.chdir(REPO)
    rc = agent_watch.main([
        "--mode", "prebump", "--config", str(cfg_path),
        "--agent", "codex", "--keep-sandbox",
    ])
    assert rc in (0, 2)
    err = capsys.readouterr().err
    assert "codex" in err
    assert ("90" in err) or ("old" in err.lower())
    reports = list((tmp_path / "out").glob("*-prebump/report.json"))
    entry = json.loads(reports[0].read_text())["results"]["codex"]
    warnings = entry["evidence"]["auth_warnings"]
    assert any("90" in w or "old" in w.lower() for w in warnings)
