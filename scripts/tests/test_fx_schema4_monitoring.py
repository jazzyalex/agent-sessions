"""fx schema-4 monitoring: fingerprint, mixed-store selection, contract, steward check.

fx 0.0.8 stopped writing `checkpoint.json`. A session directory now holds a
schema-4 `session.json` and an `events.jsonl` whose lines are conversation
frames (`{schema_version, seq, timestamp_ms, event: {<kind>: payload}}`,
upstream `session_event.zig` at v0.0.14). The weekly scan and
`steward_check.py fx` globbed `*/checkpoint.json`, so on a schema-4 machine they
reported "no fx sessions found" (issue #83). Each test here pins one piece of
the repair against a synthetic tree; nothing reads a real `~/.fx`.
"""
import json
import os
import shutil
from pathlib import Path

import agent_watch
import steward_check

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "Resources/Fixtures/stage0/agents/fx/schema4"
LEGACY_FIXTURE = REPO / "Resources/Fixtures/stage0/agents/fx/small"


def _fx_config() -> dict:
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text(encoding="utf-8"))
    return cfg["agents"]["fx"]


def _copy_schema4(dest: Path, *, mtime: float | None = None) -> Path:
    shutil.copytree(FIXTURE, dest)
    events = dest / "events.jsonl"
    if mtime is not None:
        for p in [events, dest / "session.json"]:
            os.utime(p, (mtime, mtime))
    return events


def _copy_legacy(dest: Path, *, mtime: float | None = None) -> Path:
    shutil.copytree(LEGACY_FIXTURE, dest)
    checkpoint = dest / "checkpoint.json"
    if mtime is not None:
        os.utime(checkpoint, (mtime, mtime))
    return checkpoint


# --------------------------------------------------------------------------
# Fingerprint
# --------------------------------------------------------------------------


def test_schema4_fingerprint_buckets_frames_by_kind_and_reads_both_sidecars():
    fp = agent_watch._fx_events_schema_fingerprint(FIXTURE / "events.jsonl")
    tk = fp["type_keys"]

    assert fp["parse_errors"] == 0
    assert set(tk["event"]) == {"schema_version", "seq", "timestamp_ms", "event"}
    for kind in ("user", "assistant", "tool_call", "tool_result", "steering",
                 "turn_completed", "interrupted", "context_checkpoint"):
        assert f"event.{kind}" in tk, kind
    # fx writes null optionals explicitly; a null-valued key is still schema.
    assert "tool_image_handle" in tk["event.tool_result"]
    assert "provider_replay" in tk["event.assistant"]
    # The nested records that carry user-visible facts are watched too.
    assert {"path", "media_type", "snapshot_path"} <= set(tk["event.user.image"])
    assert {"source", "parts_json"} <= set(tk["event.assistant.provider_replay"])
    assert {"path", "lines", "content_handle"} <= set(tk["event.tool_result.committed_file_presentation"])
    assert {"path", "tool_call_id", "action"} <= set(tk["event.turn_completed.file"])
    assert "token_progress" in tk["event.turn_completed.turn_summary"]
    # The schema-4 manifest and the recovery sidecar.
    assert {"provider", "model", "effort", "title", "subagent_child"} <= set(tk["session"])
    assert set(tk["recovery"]) == {"conversation_seq", "checkpoint"}
    assert {"user", "assistant_source", "execution", "cause"} <= set(tk["recovery.checkpoint"])
    assert fp["type_counts"]["event.tool_call"] == 4


def test_fingerprint_dispatch_routes_each_layout():
    v4 = agent_watch._schema_fingerprint_for_agent("fx", FIXTURE / "events.jsonl", max_lines=5000)
    v3 = agent_watch._schema_fingerprint_for_agent("fx", LEGACY_FIXTURE / "checkpoint.json", max_lines=5000)
    assert "event.user" in v4["type_keys"]
    assert "turn.assistant" in v3["type_keys"]


def test_a_single_probed_frame_yields_its_own_bucket(tmp_path):
    # steward_check harvests drift by fingerprinting one redacted record at a
    # time through `_schema_fingerprint_for_agent`; the probe has no siblings.
    probe = tmp_path / "probe.jsonl"
    probe.write_text(json.dumps({"schema_version": 3, "seq": 1, "timestamp_ms": 1,
                                 "event": {"tool_result": {"call_id": "", "new_key": 0}}}) + "\n")
    buckets = agent_watch._schema_fingerprint_for_agent("fx", probe, max_lines=5)["type_keys"]
    assert buckets["event.tool_result"] == ["call_id", "new_key"]
    assert "session" not in buckets


def test_old_infrastructure_log_lines_are_not_frames(tmp_path):
    log = tmp_path / "events.jsonl"
    log.write_text(json.dumps({"schema_version": 1, "seq": 1, "kind": "session_started", "payload": {}}) + "\n")
    fp = agent_watch._fx_events_schema_fingerprint(log)
    assert not any(b.startswith("event.") for b in fp["type_keys"])
    assert fp["type_keys"].get("<not-a-frame>") == ["kind", "payload", "schema_version", "seq"]


def test_committed_baseline_covers_both_layouts():
    paths = [
        "Resources/Fixtures/stage0/agents/fx/small/checkpoint.json (+ session.json, display.json)",
        "Resources/Fixtures/stage0/agents/fx/schema4/events.jsonl (+ session.json, recovery.json, tool-results/)",
    ]
    cwd = os.getcwd()
    try:
        os.chdir(REPO)
        baseline = agent_watch._baseline_type_keys_for_agent("fx", paths)
    finally:
        os.chdir(cwd)
    assert "turn.assistant" in baseline
    assert "event.tool_result" in baseline
    observed = agent_watch._fx_events_schema_fingerprint(FIXTURE / "events.jsonl")["type_keys"]
    for bucket, keys in observed.items():
        assert set(keys) <= set(baseline[bucket]), bucket


def test_matrix_lists_the_schema4_fixture_as_evidence():
    matrix = (REPO / "docs/agent-support/agent-support-matrix.yml").read_text(encoding="utf-8")
    assert "Resources/Fixtures/stage0/agents/fx/schema4/events.jsonl" in matrix


# --------------------------------------------------------------------------
# Selection and discovery contract
# --------------------------------------------------------------------------


def test_mixed_store_selects_newest_schema4_and_skips_stubs_and_v2(tmp_path):
    root = tmp_path / ".fx" / "sessions"
    root.mkdir(parents=True)
    old = _copy_legacy(root / "1787261000000-1787261000000000000-0000000000000001", mtime=1_000)
    new = _copy_schema4(root / "Fx4FixtureS1", mtime=3_000)
    # A schema-3 directory whose checkpoint never materialized: its
    # events.jsonl is the old infrastructure log and must not be sampled.
    stub = root / "1787262000000-1787262000000000000-0000000000000002"
    stub.mkdir()
    (stub / "session.json").write_text(json.dumps({"schema_version": 3, "storage_format": "event_log_v1"}))
    (stub / "authority.json").write_text("{}")
    (stub / "events.jsonl").write_text(json.dumps({"kind": "session_started"}) + "\n")
    os.utime(stub / "events.jsonl", (9_000, 9_000))
    # The opt-in sessions-v2 root and the CLI's `latest` pointer.
    for reserved in ("v2", "latest"):
        _copy_schema4(root / reserved, mtime=9_500)

    picked = agent_watch._fx_newest_session_files([str(root)], 5)
    assert picked == [new, old]


def test_baseline_rebuild_sweeps_both_layouts(tmp_path):
    import rebuild_stage0_baseline as rebuild

    root = tmp_path / "sessions"
    root.mkdir()
    old = _copy_legacy(root / "legacy-session", mtime=1_000)
    new = _copy_schema4(root / "Fx4FixtureS1", mtime=2_000)
    cfg = {"weekly": {"local_schema": {"roots": [str(root)], "glob": "*/checkpoint.json"}}}
    assert rebuild._all_sessions("fx", cfg, None) == [new, old]


def test_discovery_contract_accepts_both_layouts_and_requires_the_manifest(tmp_path):
    contract = _fx_config()["weekly"]["discovery_path_contract"]
    sessions = tmp_path / ".fx" / "sessions"
    events = _copy_schema4(sessions / "Fx4FixtureS1")
    checkpoint = _copy_legacy(sessions / "1787261000000-1787261000000000000-0000000000000001")

    assert agent_watch._check_discovery_path_contract(str(events), contract)["ok"] is True
    assert agent_watch._check_discovery_path_contract(str(checkpoint), contract)["ok"] is True

    (events.parent / "session.json").unlink()
    broken = agent_watch._check_discovery_path_contract(str(events), contract)
    assert broken["ok"] is False
    assert broken["required_companion_files"][0]["ok"] is False


# --------------------------------------------------------------------------
# steward_check end to end on a schema-4 tree
# --------------------------------------------------------------------------


def _run_steward(tmp_path, monkeypatch, sessions_root: Path) -> tuple[int, dict]:
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json").read_text(encoding="utf-8"))
    fx = cfg["agents"]["fx"]
    fx["upstream"] = []
    fx["weekly"]["local_schema"]["roots"] = [str(sessions_root)]
    cfg["agents"] = {"fx": fx}
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(json.dumps(cfg))

    monkeypatch.setattr(steward_check, "CONFIG", cfg_path)
    monkeypatch.setattr(
        agent_watch, "_run_installed_version_cmds",
        lambda _cfg: (["fx", "--version"], 0, "0.0.14", "", "0.0.14"),
    )
    monkeypatch.setattr(agent_watch, "_resolve_cli_binary_mtime", lambda _argv: ("/tmp/fake-fx", None))

    out_dir = tmp_path / "out"
    result = steward_check._scan("fx", out_dir, timeout=5, verbose=False)
    code = steward_check._report("fx", result, out_dir)
    return code, result


def test_steward_check_finds_a_schema4_session(tmp_path, monkeypatch, capsys):
    sessions = tmp_path / ".fx" / "sessions"
    _copy_schema4(sessions / "Fx4FixtureS1")

    code, result = _run_steward(tmp_path, monkeypatch, sessions)
    out = capsys.readouterr().out

    local = result["weekly"]["local_schema"]
    assert local["file"].endswith("Fx4FixtureS1/events.jsonl")
    assert result["evidence"]["schema_matches_baseline"] is True
    assert result["weekly"]["discovery_path_contract"]["ok"] is True
    assert "No fx sessions were found" not in out
    assert code != steward_check.EXIT_DRIFT


def test_steward_check_reports_schema4_drift_with_a_redacted_sample(tmp_path, monkeypatch, capsys):
    sessions = tmp_path / ".fx" / "sessions"
    events = _copy_schema4(sessions / "Fx4FixtureS1")
    frames = [json.loads(line) for line in events.read_text(encoding="utf-8").splitlines()]
    for frame in frames:
        result = frame["event"].get("tool_result")
        if result is not None:
            result["brand_new_field"] = "/Users/steward/secret/output.txt"
            break
    events.write_text("".join(json.dumps(f, separators=(",", ":")) + "\n" for f in frames), encoding="utf-8")

    code, _result = _run_steward(tmp_path, monkeypatch, sessions)
    out = capsys.readouterr().out

    assert code == steward_check.EXIT_DRIFT
    assert "New field(s) inside event.tool_result: brand_new_field" in out
    sample = tmp_path / "out" / "redacted-sample" / "fx-drift-sample.jsonl"
    text = sample.read_text(encoding="utf-8")
    assert "brand_new_field" in text
    assert "/Users/steward" not in text
    assert steward_check._redaction_leaks(text) == []
