"""`steward_check` hands a non-maintainer two things: a verdict and a sample.

Both have a way of going wrong quietly. A verdict that exits 0 on an
uncheckable machine tells a steward "all good" when nothing was checked, and a
sample that keeps one real path turns a helpful bug report into a privacy leak
in a public issue. Each test here pins one of those.
"""
import json

import agent_watch
import steward_check


# Fake PII planted in the synthetic sessions below. Every one of these must be
# gone from anything the tool offers a steward to attach to an issue.
SECRETS = [
    "steward@example.com",
    "/Users/steward",
    "sk-ABCDEFGH12345678901234",
    "019f6851-7ec4-7ef0-97d3-03f3eee38755",
    "192.168.1.44",
]


def _grok_session(tmp_path, extra_key=True):
    """A grok session directory with PII in every value-bearing position."""
    d = tmp_path / "sessions" / "%2FUsers%2Fsteward%2Fsecret" / SECRETS[3]
    d.mkdir(parents=True)
    records = [
        {"type": "user", "prompt_index": 0,
         "content": [{"type": "text", "text": "mail steward@example.com from 192.168.1.44"}]},
        {"type": "assistant", "content": "ok",
         "tool_calls": [{"id": "call-1", "name": "read_file",
                         "arguments": '{"target_file":"/Users/steward/secret/a.py"}'}]},
        {"type": "tool_result", "content": "sk-ABCDEFGH12345678901234", "tool_call_id": "call-1"},
    ]
    if extra_key:
        records.append({"type": "brand_new_record",
                        "payload": {"who": "steward@example.com", "path": "/Users/steward/secret"}})
    (d / "chat_history.jsonl").write_text(
        "".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
    (d / "summary.json").write_text(json.dumps({
        "info": {"id": SECRETS[3], "cwd": "/Users/steward/secret"},
        "generated_title": "work for steward@example.com",
        "created_at": "2026-07-31T10:13:27.574131Z",
        "current_model_id": "grok-4.5",
        "num_chat_messages": 4,
        "brand_new_summary_key": "/Users/steward/secret",
    }), encoding="utf-8")
    return d / "chat_history.jsonl"


def _fx_session(tmp_path, model="demo/model"):
    """An fx checkpoint plus the sibling session sidecar the monitor fingerprints."""
    d = tmp_path / "fx" / "session-1"
    d.mkdir(parents=True)
    (d / "checkpoint.json").write_text(json.dumps({
        "schema_version": 3,
        "session_id": "019f6851-7ec4-7ef0-97d3-03f3eee38755",
        "state": {"history": []},
    }), encoding="utf-8")
    (d / "session.json").write_text(json.dumps({
        "schema_version": 3,
        "storage_format": "event_log_v1",
        "workspace_root": "/Users/steward/secret",
        "log_generation": "generation",
        "last_event_seq": 7,
        "event_log_bytes": 4096,
        "event_log_stat_fingerprint": "fingerprint",
        "generation_base_seq": 1,
        "generation_base_bytes": 512,
        "checkpoint_seq": 7,
        "checkpoint_sha256": "checkpoint-hash",
        "preferences": {"model": model},
    }), encoding="utf-8")
    return d / "checkpoint.json"


# --------------------------------------------------------------------------
# Redaction
# --------------------------------------------------------------------------


def test_leak_scanner_actually_fires():
    # Positive control. Without this, an empty leak list proves nothing: a
    # scanner that matches nothing would pass every other test in this file.
    for secret in SECRETS:
        assert steward_check._redaction_leaks(f'{{"k":"{secret}"}}'), secret


def test_harvested_sample_keeps_no_real_values(tmp_path):
    transcript = _grok_session(tmp_path)
    wanted = {("brand_new_record", "payload"), ("summary", "brand_new_summary_key")}
    records = steward_check._collect_drifting_records(
        "grok", [transcript], wanted, {"brand_new_record"}, max_records=20)
    assert records, "the drifting record must be harvested at all"

    sidecar_obj, _err = agent_watch._read_json_object(transcript.parent / "summary.json")
    sidecar = steward_check._redact_records("grok", [sidecar_obj])[0]

    out = tmp_path / "sample"
    path, leaks = steward_check._write_redacted_sample("grok", records, sidecar, out)
    assert leaks == []
    assert path is not None

    written = "".join(p.read_text(encoding="utf-8") for p in sorted(out.iterdir()))
    for secret in SECRETS:
        assert secret not in written, f"{secret} survived redaction"
    assert steward_check._redaction_leaks(written) == []
    # Structure survives -- an all-placeholder file still has to be useful.
    assert "brand_new_record" in written
    assert "brand_new_summary_key" in written


def test_fx_sidecar_drift_writes_redacted_session_json(tmp_path, capsys):
    checkpoint = _fx_session(tmp_path)
    result = _result(
        verified_version="0.0.5",
        installed={"argv": ["fx", "--version"], "parsed_version": "0.0.7", "stderr": ""},
        weekly={"local_schema": {"file": str(checkpoint), "sampled_files": [str(checkpoint)]}},
        evidence={
            "schema_matches_baseline": False,
            "schema_diff": {"unknown_types": [],
                            "unknown_keys": {"session": ["checkpoint_seq"]},
                            "missing_types": []},
        },
    )

    code = steward_check._report("fx", result, tmp_path / "out")

    assert code == steward_check.EXIT_DRIFT
    sample = tmp_path / "out" / "redacted-sample" / "session.json"
    assert sample.exists()
    written = sample.read_text(encoding="utf-8")
    assert "checkpoint_seq" in written
    assert "demo/model" in written
    assert "/Users/steward" not in written
    assert steward_check._redaction_leaks(written) == []
    assert "A redacted sample was written" in capsys.readouterr().out
    issue = (tmp_path / "out" / "issue.md").read_text(encoding="utf-8")
    assert str(sample) not in issue
    assert "/Users/steward" not in issue
    assert "session.json" in issue
    assert "structural discriminators (`type`, `role`, `subtype`, `model`) remain" in issue


def test_fx_v007_sidecar_keys_are_covered_by_the_committed_baseline(tmp_path):
    checkpoint = _fx_session(tmp_path)
    observed = agent_watch._fx_checkpoint_schema_fingerprint(checkpoint)
    baseline = agent_watch._fx_checkpoint_schema_fingerprint(
        steward_check.REPO / "Resources/Fixtures/stage0/agents/fx/small/checkpoint.json"
    )

    diff = agent_watch._schema_diff(
        observed_type_keys=observed["type_keys"],
        baseline_type_keys=baseline["type_keys"],
        observed_event_count=sum(observed["type_counts"].values()),
    )

    assert diff["unknown_types"] == []
    assert diff["unknown_keys"] == {}


def test_fx_sidecar_sample_is_withheld_when_structural_value_contains_pii(tmp_path, capsys):
    checkpoint = _fx_session(tmp_path, model="steward@example.com")
    result = _result(
        installed={"argv": ["fx", "--version"], "parsed_version": "0.0.7", "stderr": ""},
        weekly={"local_schema": {"file": str(checkpoint), "sampled_files": [str(checkpoint)]}},
        evidence={
            "schema_matches_baseline": False,
            "schema_diff": {"unknown_types": [],
                            "unknown_keys": {"session": ["checkpoint_seq"]},
                            "missing_types": []},
        },
    )

    code = steward_check._report("fx", result, tmp_path / "out")

    assert code == steward_check.EXIT_DRIFT
    sample_dir = tmp_path / "out" / "redacted-sample"
    assert not sample_dir.exists() or not list(sample_dir.iterdir())
    assert "sample was NOT written" in capsys.readouterr().out


def test_sample_is_withheld_when_something_survives(tmp_path):
    # Redaction is not the only defence: if a future agent's shape defeats it,
    # the tool must hand over nothing rather than something almost-clean.
    out = tmp_path / "sample"
    path, leaks = steward_check._write_redacted_sample(
        "grok", [{"type": "x", "model": "who@example.com"}], None, out)
    assert path is None
    assert leaks == ["an email address"]
    assert not out.exists() or not list(out.iterdir())


# --------------------------------------------------------------------------
# Verdicts and exit codes
# --------------------------------------------------------------------------


def _result(**over):
    base = {
        "verified_version": "1.0.4",
        "installed": {"argv": ["grok", "--version"], "parsed_version": "1.0.4", "stderr": ""},
        "upstream": {"parsed_version": "1.0.4"},
        "weekly": {"local_schema": {"file": "/x/chat_history.jsonl",
                                    "sampled_files": ["/x/chat_history.jsonl"] * 5}},
        "evidence": {
            "schema_matches_baseline": True,
            "schema_diff": {},
            "sample_freshness": {"is_stale": False},
        },
    }
    base.update(over)
    return base


def test_clean_run_says_all_good_and_exits_zero(tmp_path, capsys):
    code = steward_check._report("grok", _result(), tmp_path)
    out = capsys.readouterr().out
    assert code == steward_check.EXIT_OK == 0
    assert "All good: grok format matches the baseline (5 sessions sampled)" in out
    assert "1.0.4" in out


def test_clean_run_on_a_newer_cli_suggests_a_version_bump(tmp_path, capsys):
    result = _result(installed={"argv": ["grok", "--version"], "parsed_version": "1.1.0", "stderr": ""})
    code = steward_check._report("grok", result, tmp_path)
    out = capsys.readouterr().out
    assert code == 0
    assert "newer than the verified" in out
    assert "matrix entry can be bumped" in out


def test_clean_but_stale_run_on_a_newer_cli_holds_verified_version(tmp_path, capsys):
    result = _result(
        verified_version="0.0.5",
        installed={"argv": ["fx", "--version"], "parsed_version": "0.0.7", "stderr": ""},
        evidence={
            "schema_matches_baseline": True,
            "schema_diff": {},
            "sample_freshness": {"is_stale": True, "stale_reason": "sample_predates_cli"},
        },
    )

    code = steward_check._report("fx", result, tmp_path)
    out = capsys.readouterr().out

    assert code == 0
    assert "newer than the verified" in out
    assert "Keep the verified version unchanged" in out
    assert "matrix entry can be bumped" not in out


def test_drift_exits_one_and_writes_a_pasteable_issue(tmp_path, capsys):
    result = _result(evidence={
        "schema_matches_baseline": False,
        "schema_diff": {"unknown_types": ["brand_new_record"],
                        "unknown_keys": {"assistant": ["brand_new_key"]},
                        "missing_types": []},
    })
    code = steward_check._report("grok", result, tmp_path, write_sample=False)
    out = capsys.readouterr().out
    assert code == steward_check.EXIT_DRIFT == 1
    assert "A kind of record we have never seen before: brand_new_record" in out
    assert "New field(s) inside assistant: brand_new_key" in out
    issue = (tmp_path / "issue.md").read_text(encoding="utf-8")
    assert issue.startswith("Title: grok: session format drift")
    assert steward_check.STEWARD_DOC in issue


def test_missing_cli_exits_two_with_guidance(tmp_path, capsys):
    result = _result(installed={"argv": ["grok", "--version"], "parsed_version": None, "stderr": "no such file"})
    code = steward_check._report("grok", result, tmp_path)
    out = capsys.readouterr().out
    assert code == steward_check.EXIT_CANNOT_CHECK == 2
    assert "Could not find the grok CLI" in out
    assert "grok --version" in out


def test_no_sessions_exits_two_with_guidance(tmp_path, capsys):
    result = _result(weekly={"local_schema": {"error": "no_files_found", "roots": ["~/.grok/sessions"]}})
    code = steward_check._report("grok", result, tmp_path)
    out = capsys.readouterr().out
    assert code == 2
    assert "No grok sessions were found" in out
    assert "~/.grok/sessions" in out


def test_no_baseline_exits_two_rather_than_claiming_health(tmp_path, capsys):
    result = _result(evidence={"schema_matches_baseline": None, "schema_diff": None})
    code = steward_check._report("grok", result, tmp_path)
    out = capsys.readouterr().out
    assert code == 2
    assert "could not compare" in out


# --------------------------------------------------------------------------


def test_agent_list_comes_from_the_shared_matrix_map():
    # The map is imported from agent_watch, never re-declared. Two private
    # copies of it have drifted before, each time producing an empty baseline
    # and a report that the entire format had changed.
    agents = steward_check._known_agents()
    assert "grok" in agents
    assert set(agents) <= set(agent_watch.MATRIX_KEY_FOR_AGENT)


def test_public_agent_names_resolve_too():
    # STEWARDS.md calls them "Grok CLI" and "Claude Code", so those spellings --
    # which are the matrix keys -- have to work as well as the internal key.
    known = steward_check._known_agents()
    assert steward_check._resolve_agent("grok", known) == "grok"
    assert steward_check._resolve_agent("Grok-CLI", known) == "grok"
    assert steward_check._resolve_agent("claude_code", known) == "claude"
    assert steward_check._resolve_agent("not-an-agent", known) is None


def test_plain_language_output_carries_no_emoji(tmp_path, capsys):
    steward_check._report("grok", _result(), tmp_path)
    out = capsys.readouterr().out
    assert all(ord(ch) < 0x2190 for ch in out), "steward output must stay plain ASCII-ish"
