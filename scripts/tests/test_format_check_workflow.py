"""Workflow gates: no sessions during preflight, no secrets in its report."""
import ast
import json
import subprocess
from pathlib import Path

import pytest

import agent_watch as watch
import agent_watch_prebump_drivers as drivers

REPO = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("protected", ["GH_TOKEN", "GITHUB_TOKEN"])
def test_workflow_subprocess_strips_github_token_and_keeps_normal_environment(monkeypatch, protected):
    import sys
    import agent_watch_workflow as flow
    monkeypatch.setenv(protected, "synthetic-do-not-output")
    monkeypatch.setenv("FORMAT_CHECK_TEST_MARKER", "present")
    rc, out, err = flow._capture([sys.executable, "-c",
        "import os; print(int(any(k in os.environ for k in ('GH_TOKEN','GITHUB_TOKEN'))), "
        "int('FORMAT_CHECK_TEST_MARKER' in os.environ))"], 2)
    assert (rc, out, err) == (0, "0 1\n", "")


def test_copilot_price_coverage_reads_usage_model_and_excludes_tool_input(tmp_path):
    import agent_watch_workflow as flow
    (tmp_path / "events.jsonl").write_text(json.dumps({"type": "session.usage_record", "data": {
        "usage": {"model": "unpriced-new-route", "inputTokens": 1},
        "input": {"usage": {"model": "private-tool-input"}}}}) + "\n")
    report = flow.price_coverage("copilot", {"roots": [str(tmp_path)], "glob": "*.jsonl"}, {"models": {}})
    assert report["observed_slugs"] == report["unpriced_slugs"] == ["unpriced-new-route"]
    assert report["read_errors"] == 0


def test_preflight_collects_expiry_and_model_actions_without_printing_secrets(tmp_path, monkeypatch):
    import agent_watch_workflow as flow
    secret = "DO-NOT-PRINT-THIS-CREDENTIAL"
    cred = tmp_path / "auth.json"
    cred.write_text(json.dumps({"token": secret, "expires_at": "2000-01-01T00:00:00Z"}))
    cfg = {"agents": {
        "grok": {"installed_version_cmd": ["grok", "--version"],
                 "preflight": {"credential_files": [str(cred)]}},
        "cline": {"installed_version_cmd": ["cline", "--version"],
                  "prebump": {"model": "ended-model"},
                  "preflight": {"models_argv": ["cline", "models"], "models_format": "lines"}},
    }}
    monkeypatch.setattr(flow.shutil, "which", lambda cmd: "/bin/" + cmd)
    def run(argv, **kwargs):
        assert argv in (["grok", "--version"], ["cline", "--version"], ["cline", "models"])
        return subprocess.CompletedProcess(argv, 0, "available-model\n" if "models" in argv else "1.2.3", "")
    monkeypatch.setattr(flow.subprocess, "run", run)
    report = flow.preflight(cfg, timeout=1)
    assert secret not in json.dumps(report)
    assert report["results"]["grok"]["credential_status"] == "credential present"
    assert {row["agent"] for row in report["owner_actions"]} == {"grok", "cline"}


def test_update_reprobes_path_and_rejects_ineffective_update(monkeypatch):
    import agent_watch_workflow as flow
    monkeypatch.setattr(flow.shutil, "which", lambda cmd: "/bin/" + cmd)
    calls = []
    def run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "1.0.0", "")
    monkeypatch.setattr(flow.subprocess, "run", run)
    row = flow.update_agent({"installed_version_cmd": ["grok", "--version"],
                             "install": {"argv": ["grok", "update"], "version_probe": ["grok", "--version"]}},
                            target="1.0.1", timeout=1)
    assert row["error"] == "update_not_effective"
    assert calls[-1] == ["grok", "--version"]


def test_update_effective_and_no_update_for_current(monkeypatch):
    import agent_watch_workflow as flow
    outputs = iter(["1.0.0", "updated", "1.0.1"])
    calls = []
    def run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, next(outputs), "")
    monkeypatch.setattr(flow.subprocess, "run", run)
    config = {"installed_version_cmd": ["cli", "--version"], "install": {"argv": ["cli", "update", "{version}"]}}
    assert flow.update_agent(config, target="1.0.1")["ok"]
    assert calls[1] == ["cli", "update", "1.0.1"]
    outputs = iter(["1.0.1"])
    calls.clear()
    assert flow.update_agent(config, target="1.0.1")["ok"]
    assert calls == [["cli", "--version"]]


def test_version_probe_matches_normal_monitor_cursor_build_identity(monkeypatch):
    import agent_watch_workflow as flow
    monkeypatch.setattr(flow.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 0, "2026.10.22-27dcf5f", ""))
    assert flow._version(["cursor-agent", "--version"], 1) == "2026.10.22"


def test_update_never_installs_a_new_prerelease(monkeypatch):
    import agent_watch_workflow as flow
    calls = []
    def run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "0.2.1-rc.5", "")
    monkeypatch.setattr(flow.subprocess, "run", run)
    agent = {"installed_version_cmd": ["dsh", "--version"],
             "install": {"argv": ["npm", "install", "-g", "@deepseek-ai/dsh@{version}"]}}
    assert flow.update_agent(agent, target="0.2.1-rc.6")["error"] == "prerelease_not_authorized"
    assert calls == [["dsh", "--version"]]
    calls.clear()
    assert flow.update_agent(agent, target="0.2.1-rc.5")["ok"]
    assert calls == [["dsh", "--version"]]


def test_summary_uses_report_including_holds():
    import agent_watch_workflow as flow
    table = flow.summary({"results": {"openclaw": {"tier": "Best-effort", "verified_version": "1.0.0", "old_version": "1.0.0",
        "installed": {"parsed_version": "1.0.1"}, "weekly": {"schema_diff": {"unknown_types": ["x"]}},
        "hold": {"version": "1.0.1", "reason": "turn failed", "since": "2026-11-02"},
        "compatibility": {"verdict": "blocked_no_fresh_evidence", "next_action": "retry turn"}}}})
    assert "1.0.0 -> 1.0.1" in table
    assert "turn failed" in table and "retry turn" in table and "Best-effort" in table


def test_summary_routes_absent_stewards_to_verification_not_local_drivers():
    import agent_watch_workflow as flow
    report = {"results": {name: {"tier": "Steward-verified", "installed": {"parsed_version": None},
        "compatibility": {"verdict": "blocked_no_fresh_evidence", "next_action": "install CLI and add driver"}}
        for name in ("devin", "fx")}}
    table = flow.summary(report)
    assert "install CLI and add driver" not in table
    assert "steward verification" in table
    assert "#83" in table


def test_auth_drops_declared_environment_before_env_first_return(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENCODE_DB", "/real/store.db")
    monkeypatch.setenv("OPENCODE_OTHER", "x")
    monkeypatch.setenv("LEAK_HOME", "/real")
    monkeypatch.setenv("SAFE_KEY", "secret")
    env, _ = drivers.prepare_auth(prebump_cfg={"drop_env": ["LEAK_HOME"],
        "drop_env_prefixes": ["OPENCODE_"], "env_vars": ["SAFE_KEY"]}, sandbox=tmp_path, real_home=tmp_path)
    assert "LEAK_HOME" not in set(env)
    assert not any(key.startswith("OPENCODE_") for key in env)
    assert env["SAFE_KEY"] == "secret"


def test_every_driver_subprocess_declares_workspace_cwd():
    tree = ast.parse((REPO / "scripts/agent_watch_prebump_drivers.py").read_text())
    missing = []
    for cls in (node for node in tree.body if isinstance(node, ast.ClassDef) and node.name.endswith("Driver")):
        for node in ast.walk(cls):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "run":
                if isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess":
                    if not any(kw.arg == "cwd" for kw in node.keywords):
                        missing.append(cls.name)
    assert missing == []


def test_repo_write_fails_guard_and_existing_changes_are_allowed(tmp_path, monkeypatch):
    import agent_watch_workflow as flow
    statuses = iter([" M existing\n", " M existing\n?? probe.txt\n"])
    monkeypatch.setattr(flow, "repo_status", lambda root: next(statuses))
    result = drivers.DriverResult(True, None, tmp_path / "out", tmp_path / "err", 0, None)
    assert flow.guarded_driver_run(tmp_path, lambda: result).error == "sandbox_breach:repository_changed"
    monkeypatch.setattr(flow, "repo_status", lambda root: " M existing\n")
    assert flow.guarded_driver_run(tmp_path, lambda: result).ok


def test_real_driver_repo_write_is_a_sandbox_breach(tmp_path):
    import agent_watch_workflow as flow
    # Disposable, unborn repository: no commit or branch ref is created.
    subprocess.run(["git", "init", "--quiet", str(tmp_path)], check=True)
    assert subprocess.run(["git", "for-each-ref"], cwd=tmp_path, capture_output=True, text=True, check=True).stdout == ""
    def driver():
        (tmp_path / "probe.txt").write_text("agent-watch test probe\n")
        return drivers.DriverResult(True, None, tmp_path / "out", tmp_path / "err", 0, None)
    result = flow.guarded_driver_run(tmp_path, driver)
    assert not result.ok
    assert result.error == "sandbox_breach:repository_changed"


def test_guard_detects_rewrite_inside_existing_untracked_directory(tmp_path):
    import agent_watch_workflow as flow
    subprocess.run(["git", "init", "--quiet", str(tmp_path)], check=True)
    directory = tmp_path / "existing"
    directory.mkdir()
    file = directory / "file.txt"
    file.write_text("before")
    result = drivers.DriverResult(True, None, tmp_path / "out", tmp_path / "err", 0, None)
    assert flow.guarded_driver_run(tmp_path, lambda: result).ok
    def driver():
        file.write_text("after")
        return result
    assert flow.guarded_driver_run(tmp_path, driver).error == "sandbox_breach:repository_changed"


def test_guard_checks_changes_when_driver_raises(tmp_path):
    import agent_watch_workflow as flow
    subprocess.run(["git", "init", "--quiet", str(tmp_path)], check=True)
    def driver():
        (tmp_path / "probe.txt").write_text("changed")
        raise ValueError("driver failed")
    with pytest.raises(RuntimeError, match="sandbox_breach"):
        flow.guarded_driver_run(tmp_path, driver)


def test_breach_diagnostic_never_triggers_model_fallback(tmp_path):
    import agent_watch_workflow as flow
    out, err = tmp_path / "out", tmp_path / "err"
    out.write_text("unknown model")
    err.write_text("")
    calls = []
    def run(model):
        calls.append(model)
        return drivers.DriverResult(False, None, out, err, 1, "sandbox_breach:repository_changed")
    _, attempts = flow.run_with_fallback(run, "first", ["second"], watch._classify_prebump_failure)
    assert calls == ["first"]
    assert attempts[0]["failure_class"] == "sandbox_breach"


@pytest.mark.parametrize("error,category", [("auth_failed", "auth_failed"),
    ("timeout", "timeout"), ("config_gate:denied", "config_error"),
    ("discovery_contract:failed", "discovery_contract_failed")])
def test_structured_failure_outranks_unknown_model_text(tmp_path, error, category):
    out = tmp_path / "out"
    out.write_text("unknown model")
    assert watch._classify_prebump_failure({"error": error, "stdout_file": str(out)}) == category


@pytest.mark.parametrize("detail,expected", [
    ("HTTP 429: account limit; unknown model", "quota_failed"),
    ("HTTP429: model is no longer available", "quota_failed"),
    ("unknown model; previous token count 429", "model_unavailable"),
])
def test_quota_diagnostic_prevents_fallback_without_matching_token_counts(tmp_path, detail, expected):
    out = tmp_path / "out"
    out.write_text(detail)
    assert watch._classify_prebump_failure({"error": "driver failed", "stdout_file": str(out)}) == expected


def test_summary_uses_observed_update_versions_and_labels_weekly_ceiling():
    import agent_watch_workflow as flow
    update = flow.summary({"mode": "update", "results": {"agent": {
        "old_version": "1.0.0", "new_version": "1.1.0", "ok": True}}})
    assert "1.0.0 -> 1.1.0" in update
    assert "not tracked" in update
    weekly = flow.summary({"mode": "weekly", "results": {"agent": {
        "verified_version": "0.9.0", "installed": {"parsed_version": "1.0.0"}}}})
    assert "ceiling 0.9.0; installed 1.0.0" in weekly
    assert "0.9.0 -> 1.0.0" not in weekly


def test_fx_price_coverage_uses_valid_sessions_and_schema4_sidecar(tmp_path):
    import agent_watch_workflow as flow
    for name, data in {
        "old": {"checkpoint.json": {"schemaVersion": 3, "model": "old-model"}, "session.json": {}},
        "new": {"events.jsonl": {"type": "message", "model": "event-model"},
                "session.json": {"schemaVersion": 4, "model": "sidecar-model"}},
        "v2": {"checkpoint.json": {"model": "reserved-model"}, "session.json": {}},
        "authority-only": {"session.json": {"schemaVersion": 4, "model": "authority-model"},
                           "authority.json": {}, "events.jsonl": {"model": "infrastructure-model"}},
        "no-sidecar": {"checkpoint.json": {"model": "no-sidecar-model"}},
    }.items():
        directory = tmp_path / name
        directory.mkdir()
        for file, value in data.items():
            (directory / file).write_text(json.dumps(value) + "\n")
    report = flow.price_coverage("fx", {"roots": [str(tmp_path)], "glob": "*/{checkpoint.json,events.jsonl}"}, {"models": {}})
    assert report["observed_slugs"] == ["event-model", "old-model", "sidecar-model"]


def test_guard_detects_rewrite_of_already_dirty_tracked_file(tmp_path):
    import agent_watch_workflow as flow
    subprocess.run(["git", "init", "--quiet", str(tmp_path)], check=True)
    file = tmp_path / "tracked.txt"
    file.write_text("staged")
    subprocess.run(["git", "add", "tracked.txt"], cwd=tmp_path, check=True)
    file.write_text("already dirty")
    def driver():
        file.write_text("rewritten dirty")
        return drivers.DriverResult(True, None, tmp_path / "out", tmp_path / "err", 0, None)
    assert flow.guarded_driver_run(tmp_path, driver).error == "sandbox_breach:repository_changed"


@pytest.mark.parametrize("stall", [True, False])
def test_replay_watchdog_terminates_stalled_parent_only(stall):
    import sys
    program = '''
import subprocess,sys,time
child = subprocess.Popen([sys.executable, sys.argv[1], "--seconds", "0.3"], stdin=subprocess.PIPE)
if sys.argv[2] == "stall":
    time.sleep(10)
else:
    child.stdin.close()
    assert child.wait(timeout=2) == 0
'''
    result = subprocess.run([sys.executable, "-c", program, str(REPO / "scripts/replay_watchdog.py"),
                             "stall" if stall else "fast"], capture_output=True, timeout=3)
    assert result.returncode == (-9 if stall else 0)
    assert result.stdout == result.stderr == b""


def test_claude_sandbox_cwd_still_marks_prebump(tmp_path):
    path = tmp_path / "session.jsonl"
    path.write_text(json.dumps({"type": "user", "cwd": "/tmp/agent-watch-prebump-claude-abc",
                                "message": {"content": "use tools"}}) + "\n")
    assert watch._is_prebump_session_file(path)


@pytest.mark.parametrize("line,expected", [
    ("Grok: Not signed in", "auth_failed"),
    ("Claude: Your session has expired", "auth_failed"),
    ("Cline: model is no longer available", "model_unavailable"),
    ("Pi: Unknown model: removed", "model_unavailable"),
    ("OpenCode: ModelNotFoundError", "model_unavailable"),
    ("request timeout", "timeout"),
    ("model successfully selected", "driver_failed"),
    ("tool file not found", "cli_missing"),
])
def test_failure_classification(line, expected):
    assert watch._classify_prebump_failure({"error": line}) == expected


def test_fallback_only_on_model_unavailable(tmp_path, monkeypatch):
    import agent_watch_workflow as flow
    calls = []
    def run(model):
        calls.append(model)
        err = "model is no longer available" if model == "ended" else None
        return drivers.DriverResult(err is None, None, tmp_path / "out", tmp_path / "err", 0, err)
    result, attempts = flow.run_with_fallback(run, "ended", ["working"], watch._classify_prebump_failure)
    assert result.ok and calls == ["ended", "working"]
    calls.clear()
    def denied(model):
        calls.append(model)
        return drivers.DriverResult(False, None, tmp_path / "out", tmp_path / "err", 1, "not signed in")
    result, attempts = flow.run_with_fallback(denied, "ended", ["working"], watch._classify_prebump_failure)
    assert not result.ok and calls == ["ended"]


def test_sampling_contract_reports_true_store_and_sample_counts(tmp_path):
    import agent_watch_workflow as flow
    for n in range(6):
        (tmp_path / f"s{n}.jsonl").write_text('{"type":"user"}\n')
    fp = {"sampled_files": [str(tmp_path / f"s{n}.jsonl") for n in range(5)],
          "sampled_total_parsed_lines": 40, "type_counts": {"user": 40}}
    flow.add_sampling_contract("claude", {"roots": [str(tmp_path)], "glob": "*.jsonl"}, fp)
    assert fp["store_sessions"] == 6
    assert fp["sampled_sessions"] == 5
    assert fp["sampled_events"] == 40
    assert fp["sampled_versions"] == []  # never infer writer version from the installed binary


@pytest.mark.parametrize("agent,record", [
    ("codex", {"type": "session_meta", "payload": {"cli_version": "0.166.0"}}),
    ("claude", {"type": "user", "version": "2.1.316"}),
])
def test_sampling_versions_come_from_the_sample_not_path(tmp_path, agent, record):
    import agent_watch_workflow as flow
    path = tmp_path / "session.jsonl"
    path.write_text(json.dumps(record) + "\n")
    fp = {"file": str(path), "type_counts": {"user": 1}}
    flow.add_sampling_contract(agent, {"roots": [str(tmp_path)], "glob": "*.jsonl"}, fp)
    assert fp["sampled_versions"] == ["0.166.0" if agent == "codex" else "2.1.316"]


def test_every_agent_rejects_a_single_session_sampler_without_declared_reason(monkeypatch):
    import agent_watch_workflow as flow
    monkeypatch.setattr(flow, "_store_count", lambda *args: 31)
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    for name, agent in cfg["agents"].items():
        local = agent["weekly"]["local_schema"]
        fp = {"sampled_sessions": 1, "type_counts": {"event": 3}}
        flow.add_sampling_contract(name, local, fp)
        assert bool(fp.get("sampling_contract_error")) == (not bool(local.get("single_session_reason"))), name


def test_writer_version_inventory_ignores_non_metadata_payload(tmp_path):
    import agent_watch_workflow as flow
    path = tmp_path / "session.jsonl"
    path.write_text('{"type":"event_msg","payload":"text"}\n')
    fp = {"file": str(path), "type_counts": {"event_msg": 1}}
    flow.add_sampling_contract("codex", {"roots": [str(tmp_path)], "glob": "*.jsonl"}, fp)
    assert fp["sampled_versions"] == []


def test_price_prefix_normalization_and_unpriced_negative():
    import agent_watch_workflow as flow
    table = {"models": {"gpt-6": {}, "gpt-6.1-terra": {}, "kimi-k2.7-code": {}}}
    assert flow.price_key("openai/gpt-6.1-terra-20261102", table) == "gpt-6.1-terra"
    assert flow.price_key("gpt-6.1-terra-preview", table) is None
    assert flow.price_key("moonshot-ai/kimi-k2.7-code", table) == "kimi-k2.7-code"
    assert flow.price_key("unknown-new-model", table) is None
    assert flow.price_key("<synthetic>", table) == "<synthetic>"


def test_recent_model_coverage_excludes_old_and_tool_input(tmp_path):
    import agent_watch_workflow as flow
    import os
    import time
    (tmp_path / "new.jsonl").write_text(json.dumps({"type": "assistant", "message": {"model": "gpt-6.1-terra"},
                                                 "input": {"model": "not-a-provider-model"}}) + "\n")
    old = tmp_path / "old.jsonl"
    old.write_text('{"model":"old-unpriced"}\n')
    os.utime(old, (time.time() - 40*86400,) * 2)
    report = flow.price_coverage("claude", {"roots": [str(tmp_path)], "glob": "*.jsonl"},
                                 {"models": {"gpt-6.1-terra": {}}})
    assert report["observed_slugs"] == ["gpt-6.1-terra"]
    assert report["unpriced_slugs"] == []


def test_recent_model_coverage_sqlite_is_read_only_and_tracks_unknown(tmp_path):
    import agent_watch_workflow as flow
    import sqlite3
    import time
    db = tmp_path / "opencode.db"
    with sqlite3.connect(db) as conn:
        conn.executescript("CREATE TABLE session_message(type TEXT, data TEXT, time_created INTEGER);")
        conn.execute("INSERT INTO session_message VALUES ('assistant', ?, ?)",
                     (json.dumps({"model": {"id": "brand-new", "providerID": "openai"}}), int(time.time()*1000)))
    report = flow.price_coverage("opencode", {"db_roots": [str(db)]}, {"models": {}})
    assert report["unpriced_slugs"] == ["brand-new"]


def test_synthetic_exemption_requires_zero_usage(tmp_path):
    import agent_watch_workflow as flow
    path = tmp_path / "session.jsonl"
    path.write_text('{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":0}}}\n')
    cfg = {"roots": [str(tmp_path)], "glob": "*.jsonl"}
    assert flow.price_coverage("claude", cfg, {"models": {}})["synthetic_positive_usage"] == 1
    path.write_text('{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}\n')
    assert flow.price_coverage("claude", cfg, {"models": {}})["synthetic_positive_usage"] == 0


def test_price_coverage_reads_canonical_dsh_generation(tmp_path):
    import agent_watch_workflow as flow
    folder = tmp_path / "project" / "session"
    folder.mkdir(parents=True)
    (folder / "session.v1.jsonl").write_text('{"model":"superseded"}\n')
    (folder / "session.v2.jsonl").write_text('{"payload":{"model":"current"}}\n')
    cfg = {"kind": "deepseek_harness_sessions", "default_root": str(tmp_path), "glob": "placeholder"}
    report = flow.price_coverage("deepseek_harness", cfg, {"models": {}})
    assert report["observed_slugs"] == ["current"]


def test_price_coverage_reads_openclaw_sqlite(tmp_path):
    import agent_watch_workflow as flow
    import sqlite3
    import time
    folder = tmp_path / "agents" / "main" / "agent"
    folder.mkdir(parents=True)
    db = folder / "openclaw-agent.sqlite"
    with sqlite3.connect(db) as conn:
        conn.execute("CREATE TABLE transcript_events(event_json TEXT,event_zstd BLOB,event_utf8_bytes INTEGER,created_at INTEGER)")
        conn.execute("INSERT INTO transcript_events VALUES (?,NULL,NULL,?)", ('{"model":"current"}', int(time.time()*1000)))
    cfg = {"roots": [str(tmp_path)], "db_globs": ["agents/*/agent/openclaw-agent.sqlite"]}
    assert flow.price_coverage("openclaw", cfg, {"models": {}})["observed_slugs"] == ["current"]


def test_tracker_rows_parse_with_required_fields():
    rows = (REPO / "docs/agent-support/agent-format-tracker.jsonl").read_text().splitlines()
    for index, line in enumerate(rows, 1):
        row = json.loads(line)
        assert {"agent", "bucket", "confidence", "event", "evidence", "finding_id", "record_id", "schema_version", "ts"} <= row.keys(), index


def test_skill_split_keeps_every_original_section():
    folder = REPO / "skills/agent-session-format-check"
    assert len((folder / "SKILL.md").read_text().splitlines()) < 200
    mapping = json.loads((folder / "references/section-map.json").read_text())
    # df9c05e7 is the last commit before the split; HEAD already holds the short runbook.
    original = subprocess.run(["git", "show", "df9c05e7:skills/agent-session-format-check/SKILL.md"],
                              capture_output=True, text=True, check=True).stdout
    headings = [line for line in original.splitlines() if line.startswith("## ")]
    assert set(mapping) == set(headings)
    for heading, destination in mapping.items():
        assert heading in (folder / "references" / destination).read_text()


def test_upstream_reuses_existing_gh_auth_without_exposing_it(monkeypatch):
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    calls = []
    def run(argv, timeout):
        calls.append(argv)
        return 0, "fake-local-gh-credential\n", ""
    monkeypatch.setattr(watch, "_run_cmd", run)
    assert watch._github_token() == "fake-local-gh-credential"
    assert calls == [["gh", "auth", "token"]]


@pytest.mark.parametrize("changes,valid", [
    ({}, True),
    ({"finish": "stop"}, False),
    ({"error": {"type": "provider.error"}}, False),
    ({"content": [{"type": "text", "text": "partial"}]}, False),
    ({"tokens": None}, False),
])
def test_checker_matches_production_empty_aborted_rule(changes, valid):
    data = {"model": {"id": "model"}, "finish": "error", "error": {"type": "aborted"}, "content": []}
    data.update(changes)
    problems = watch._opencode_v2_required_field_violations("assistant", data)
    assert (not problems) == valid


def test_sampling_summary_names_store_size():
    import agent_watch_workflow as flow
    assert flow.sampling_summary({"sampled_sessions": 5, "store_sessions": 162}) == " sampled 5 of 162"


def test_pi_uses_the_provider_refreshed_by_the_owner():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text())
    assert cfg["agents"]["pi"]["prebump"]["model"] == "openai/gpt-6-luna"


def test_failure_classifier_sees_oauth_refresh_error_at_end(tmp_path):
    out = tmp_path / "stdout.txt"
    out.write_text("initialization\n" * 500 + "OAuth token refresh failed: refresh_token_reused (401)\n")
    assert watch._classify_prebump_failure({"error": "pi_tool_turn_missing", "stdout_file": str(out)}) == "auth_failed"


def test_opencode_version_helper_uses_sandbox_cwd(tmp_path, monkeypatch):
    def run(argv, **kwargs):
        assert kwargs.get("cwd") == str(tmp_path)
        return subprocess.CompletedProcess(argv, 0, "2.2.5", "")
    monkeypatch.setattr(drivers.subprocess, "run", run)
    assert drivers._opencode_major_version({"HOME": str(tmp_path)}) == 2


def test_stable_wrapper_uses_relative_derived_data():
    script = (REPO / "scripts/xcode_test_stable.sh").read_text()
    assert 'DERIVED_DATA_PATH=".deriveddata-tests"' in script


def test_stable_wrapper_forwards_replay_opt_in_to_xctest_host():
    script = (REPO / "scripts/xcode_test_stable.sh").read_text()
    assert 'TEST_RUNNER_AS_REAL_SESSION_REPLAY="${AS_REAL_SESSION_REPLAY:-0}"' in script


def test_hermes_weekly_unions_five_real_sessions(tmp_path):
    from scripts.tests.test_prebump_session_exclusion import _hermes_db
    import sqlite3
    db = _hermes_db(tmp_path / "state.db")
    with sqlite3.connect(db) as conn:
        for n in range(6):
            conn.execute("INSERT INTO sessions(id, source, started_at, message_count) VALUES (?, 'cli', ?, 1)", (f"real{n}", 300 + n))
            conn.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES (?, 'assistant', 'hello', ?)", (f"real{n}", 300+n))
    fp = watch._hermes_weekly_schema_fingerprint(db, max_messages=100)
    assert fp["sampled_sessions"] == 5
    assert fp["parsed_messages"] == 5
    assert fp["type_counts"]["message.assistant"] == 5
