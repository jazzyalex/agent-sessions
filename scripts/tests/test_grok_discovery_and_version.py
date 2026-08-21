"""Grok's two silent-failure modes: a missing sidecar, and an unused CLI version.

Both were false-clean bugs — the weekly run reported "compatible, no drift" while
(1) every Grok session had disappeared from the app because its `summary.json`
sidecar was gone, and (2) compatibility was being decided against a Homebrew cask
version the config itself documented as lagging.
"""

import json as _json
from pathlib import Path as _Path

import agent_watch


# ---------------------------------------------------------------------------
# _read_json_object: the error CODE is the product, not the object
# ---------------------------------------------------------------------------


def test_read_json_object_distinguishes_every_failure_mode(tmp_path):
    good = tmp_path / "good.json"
    good.write_text('{"a": 1}')
    assert agent_watch._read_json_object(good) == ({"a": 1}, None)

    assert agent_watch._read_json_object(tmp_path / "nope.json") == (None, "missing")

    corrupt = tmp_path / "corrupt.json"
    corrupt.write_text('{"a": 1')
    assert agent_watch._read_json_object(corrupt) == (None, "invalid_json")

    array = tmp_path / "array.json"
    array.write_text("[1, 2, 3]")
    assert agent_watch._read_json_object(array) == (None, "not_json_object")

    # A directory where a file is expected raises IsADirectoryError (an OSError),
    # which is the portable stand-in for "present but unreadable" — chmod 000 is a
    # no-op for root and would make this test pass vacuously in a container.
    unreadable = tmp_path / "unreadable.json"
    unreadable.mkdir()
    assert agent_watch._read_json_object(unreadable) == (None, "unreadable")


# ---------------------------------------------------------------------------
# required_companion_files
# ---------------------------------------------------------------------------


GROK_PATTERN = r"/\.grok/sessions/[^/]+/[^/]+/chat_history\.jsonl$"
GROK_COMPANIONS = [{"path": "summary.json", "must_parse": "json_object"}]


def _grok_session(tmp_path, *, summary_text="{}", write_summary=True):
    session = tmp_path / ".grok" / "sessions" / "proj" / "sess-1"
    session.mkdir(parents=True)
    transcript = session / "chat_history.jsonl"
    transcript.write_text('{"type":"user","content":[]}\n')
    if write_summary:
        (session / "summary.json").write_text(summary_text)
    return transcript


def _contract(transcript, companions=GROK_COMPANIONS):
    return agent_watch._check_discovery_path_contract(
        str(transcript),
        {
            "description": "grok layout",
            "patterns": [GROK_PATTERN],
            "required_companion_files": companions,
        },
    )


def test_contract_passes_when_sidecar_is_present_and_parses(tmp_path):
    result = _contract(_grok_session(tmp_path, summary_text='{"info": {"id": "x"}}'))
    assert result["ok"] is True
    assert result["required_companion_files"][0]["ok"] is True
    assert "error" not in result["required_companion_files"][0]


def test_contract_fails_when_sidecar_is_missing(tmp_path):
    """The app-fatal case: no summary.json means the session does not exist to AS."""
    result = _contract(_grok_session(tmp_path, write_summary=False))
    assert result["ok"] is False
    # The path itself is still perfectly valid — only the companion broke, which is
    # exactly why the path-pattern check alone could never catch this.
    assert result["matched_pattern"] == GROK_PATTERN
    assert result["required_companion_files"][0]["error"] == "missing"


def test_contract_fails_when_sidecar_is_corrupt(tmp_path):
    result = _contract(_grok_session(tmp_path, summary_text='{"info": '))
    assert result["ok"] is False
    assert result["required_companion_files"][0]["error"] == "invalid_json"


def test_contract_fails_when_sidecar_is_not_an_object(tmp_path):
    result = _contract(_grok_session(tmp_path, summary_text="[]"))
    assert result["ok"] is False
    assert result["required_companion_files"][0]["error"] == "not_json_object"


def test_contract_fails_when_sidecar_is_unreadable(tmp_path):
    transcript = _grok_session(tmp_path, write_summary=False)
    (transcript.parent / "summary.json").mkdir()
    result = _contract(transcript)
    assert result["ok"] is False
    assert result["required_companion_files"][0]["error"] == "unreadable"


def test_bare_string_companion_requires_existence_only(tmp_path):
    transcript = _grok_session(tmp_path, summary_text="[]")
    # A list is not a JSON object, but existence-only never claimed to care.
    assert _contract(transcript, companions=["summary.json"])["ok"] is True
    assert _contract(transcript, companions=["absent.json"])["ok"] is False


def test_unknown_must_parse_rule_fails_loudly(tmp_path):
    """A config typo must not silently degrade into 'no requirement'."""
    transcript = _grok_session(tmp_path)
    result = _contract(transcript, companions=[{"path": "summary.json", "must_parse": "yaml"}])
    assert result["ok"] is False
    assert result["required_companion_files"][0]["error"] == "unsupported_must_parse"


def test_path_pattern_still_fails_independently_of_companions(tmp_path):
    """Companion checks are additive; a moved store still fails on the pattern."""
    moved = tmp_path / ".grok" / "sessions" / "proj" / "sess-1" / "extra" / "chat_history.jsonl"
    moved.parent.mkdir(parents=True)
    moved.write_text("{}\n")
    (moved.parent / "summary.json").write_text("{}")
    result = _contract(moved)
    assert result["ok"] is False
    assert result["matched_pattern"] is None
    assert result["required_companion_files"][0]["ok"] is True


def test_contract_without_companions_configured_is_unchanged(tmp_path):
    """Every other agent's contract must behave exactly as before."""
    transcript = _grok_session(tmp_path)
    result = agent_watch._check_discovery_path_contract(
        str(transcript), {"description": "d", "patterns": [GROK_PATTERN]}
    )
    assert result["ok"] is True
    assert "required_companion_files" not in result


def test_real_grok_config_declares_the_sidecar_contract():
    cfg = _json.loads(
        (_Path(__file__).resolve().parents[2] / "docs/agent-support/agent-watch-config.json").read_text()
    )
    contract = cfg["agents"]["grok"]["weekly"]["discovery_path_contract"]
    companions = contract["required_companion_files"]
    assert [c["path"] for c in companions] == ["summary.json"]
    assert companions[0]["must_parse"] == "json_object"


# ---------------------------------------------------------------------------
# The fingerprint itself stays honest about a sidecar it could not read
# ---------------------------------------------------------------------------


def test_grok_fingerprint_records_why_the_sidecar_contributed_nothing(tmp_path):
    transcript = _grok_session(tmp_path, summary_text='{"info": {"id": "x"}, "chat_format_version": 1}')
    fp = agent_watch._grok_session_schema_fingerprint(transcript, max_lines=100)
    assert fp["summary_error"] is None
    assert "summary" in fp["type_keys"]

    (transcript.parent / "summary.json").unlink()
    broken = agent_watch._grok_session_schema_fingerprint(transcript, max_lines=100)
    assert broken["summary_error"] == "missing"
    assert broken["summary_file"] is None
    # The regression in one line: losing the sidecar removes keys and NOTHING else,
    # and a schema diff that ignores missing keys therefore still reads clean.
    assert "summary" not in broken["type_keys"]

    (transcript.parent / "summary.json").write_text("{oops")
    assert agent_watch._grok_session_schema_fingerprint(transcript, max_lines=100)["summary_error"] == "invalid_json"


def test_missing_sidecar_does_not_show_up_as_schema_drift(tmp_path):
    """Pins the mechanism: the schema diff is BLIND here, so the contract must not be."""
    transcript = _grok_session(tmp_path, summary_text='{"info": {"id": "x"}}')
    baseline = agent_watch._grok_session_schema_fingerprint(transcript, max_lines=100)
    (transcript.parent / "summary.json").unlink()
    observed = agent_watch._grok_session_schema_fingerprint(transcript, max_lines=100)

    diff = agent_watch._schema_diff(
        observed_type_keys=observed["type_keys"],
        baseline_type_keys=baseline["type_keys"],
        observed_event_count=agent_watch._observed_event_count(observed),
    )
    assert diff["unknown_types"] == []
    assert diff["unknown_keys"] == {}
    assert diff["unknown_only_is_empty"] is True  # i.e. "no drift" — the false clean
    assert "summary" in diff["missing_types"]  # ignored by design


# ---------------------------------------------------------------------------
# _reconcile_latest_version_from_probes
# ---------------------------------------------------------------------------


def _probe(latest_version, *, ok=True, label="grok_update_check"):
    parsed = None
    if latest_version is not None:
        parsed = {"currentVersion": "1.0.3", "latestVersion": latest_version, "updateAvailable": True}
    return {
        "label": label,
        "ok": ok,
        "parse": "grok_update_json",
        "parsed": parsed,
        "latest_version_key": "latestVersion",
    }


def test_cli_wins_when_the_cask_lags():
    got = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[_probe("1.0.5")]
    )
    assert got["chosen_version"] == "1.0.5"
    assert got["provenance"] == "cli_probe"
    assert got["sources_disagree"] is True
    assert got["upstream_source_version"] == "1.0.3"


def test_cask_wins_when_the_cli_channel_reports_lower():
    """Max, not replace: a pinned/stale CLI channel must not hide a newer release."""
    got = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.7", probe_results=[_probe("1.0.5")]
    )
    assert got["chosen_version"] == "1.0.7"
    assert got["provenance"] == "upstream_source"
    # Still not silent — a CLI that thinks it is current while a newer build exists
    # is its own finding.
    assert got["sources_disagree"] is True


def test_agreement_is_recorded_without_disagreement():
    got = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[_probe("1.0.3")]
    )
    assert got["chosen_version"] == "1.0.3"
    assert got["provenance"] == "both_agree"
    assert got["sources_disagree"] is False


def test_failed_probe_gets_no_vote_on_the_version():
    got = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[_probe("9.9.9", ok=False)]
    )
    assert got["chosen_version"] == "1.0.3"
    assert got["probe_error"] == "probe_failed"
    assert got["probe_version"] is None
    assert got["sources_disagree"] is False


def test_probe_without_a_usable_version_is_reported_not_guessed():
    missing_key = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[_probe(None)]
    )
    assert missing_key["probe_error"] == "missing_version_key"
    assert missing_key["chosen_version"] == "1.0.3"

    garbage = agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[_probe("nightly")]
    )
    assert garbage["probe_error"] == "unparseable_version"
    assert garbage["chosen_version"] == "1.0.3"


def test_probe_supplies_the_version_when_the_registry_source_gave_none():
    got = agent_watch._reconcile_latest_version_from_probes(
        upstream=None, probe_results=[_probe("1.0.5")]
    )
    assert got["chosen_version"] == "1.0.5"
    assert got["provenance"] == "cli_probe"
    assert got["sources_disagree"] is False


def test_probes_that_declare_no_version_key_are_ignored():
    plain = {"label": "claude_status", "ok": True, "parsed": {"latestVersion": "9.9.9"}}
    assert agent_watch._reconcile_latest_version_from_probes(
        upstream="1.0.3", probe_results=[plain]
    ) is None
    assert agent_watch._reconcile_latest_version_from_probes(upstream="1.0.3", probe_results=[]) is None


def test_summary_line_prints_a_disagreement_token():
    line = agent_watch._format_summary_line(
        agent_name="grok",
        severity="low",
        verified="1.0.3",
        installed="1.0.3",
        upstream="1.0.5",
        recommendation="monitor",
        sample_freshness=None,
        upstream_reconciliation={
            "probe_version": "1.0.5",
            "upstream_source_version": "1.0.3",
            "chosen_version": "1.0.5",
            "sources_disagree": True,
        },
    )
    assert "latest_disagree=probe:1.0.5/source:1.0.3/used:1.0.5" in line


def test_summary_line_stays_quiet_when_sources_agree():
    line = agent_watch._format_summary_line(
        agent_name="grok",
        severity="none",
        verified="1.0.3",
        installed="1.0.3",
        upstream="1.0.3",
        recommendation="ignore",
        sample_freshness=None,
        upstream_reconciliation={"sources_disagree": False, "provenance": "both_agree"},
    )
    assert "latest_disagree" not in line


# ---------------------------------------------------------------------------
# End-to-end weekly runs
# ---------------------------------------------------------------------------


# Keys drawn from Resources/Fixtures/stage0/agents/grok/*, so the synthetic sample
# diffs clean against the real fixture baseline and only the deliberate defect moves.
_TRANSCRIPT_LINES = [
    {"type": "user", "content": [{"type": "text", "text": "hi"}], "prompt_index": 0},
    {
        "type": "assistant",
        "content": "hello",
        "model_id": "grok-4.5",
        "model_fingerprint": "fp_0",
        "reasoning_effort": "high",
    },
]
_SUMMARY = {
    "info": {"id": "sess-1", "cwd": "/tmp/p"},
    "session_summary": "hi",
    "created_at": "2026-08-01T00:00:00.000000Z",
    "updated_at": "2026-08-01T00:01:00.000000Z",
    "current_model_id": "grok-4.5",
    "chat_format_version": 1,
    "generated_title": "hi",
}


def _grok_weekly_config(tmp_path, report_root, *, write_summary=True, summary_text=None):
    session = tmp_path / ".grok" / "sessions" / "proj" / "sess-1"
    session.mkdir(parents=True)
    (session / "chat_history.jsonl").write_text(
        "".join(_json.dumps(o) + "\n" for o in _TRANSCRIPT_LINES)
    )
    if write_summary:
        (session / "summary.json").write_text(summary_text or _json.dumps(_SUMMARY))

    cfg = {
        "report_root": str(report_root),
        "agents": {
            "grok": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["grok", "--version"],
                "upstream": [
                    {
                        "kind": "url_regex_semver_max",
                        "url": "https://formulae.brew.sh/api/cask/grok-build.json",
                        "pattern": "grok-(\\d+\\.\\d+\\.\\d+)-macos",
                    }
                ],
                "risk_keywords": {"schema": [], "usage": []},
                "weekly": {
                    "local_schema": {
                        "kind": "jsonl_newest",
                        "roots": [str(tmp_path / ".grok" / "sessions")],
                        "glob": "*/*/chat_history.jsonl",
                        "required_types": ["user", "assistant"],
                        "max_lines": 100,
                    },
                    "freshness_window_days": 30,
                    "discovery_path_contract": {
                        "description": "grok layout",
                        "patterns": [GROK_PATTERN],
                        "required_companion_files": [
                            {"path": "summary.json", "must_parse": "json_object"}
                        ],
                    },
                    "probes": [
                        {
                            "kind": "script",
                            "label": "grok_update_check",
                            "argv": ["grok", "update", "--check", "--json"],
                            "timeout_seconds": 30,
                            "parse": "grok_update_json",
                            "latest_version_key": "latestVersion",
                        }
                    ],
                },
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))
    return cfg_path


def _run_weekly(tmp_path, monkeypatch, cfg_path, report_root, *, cask="1.0.3", cli_latest="1.0.3"):
    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["grok", "--version"], 0, "grok 1.0.3 (abc)", "", "1.0.3"),
    )
    monkeypatch.setattr(agent_watch, "_resolve_cli_binary_mtime", lambda _argv: ("/tmp/fake-grok", None))
    # Pin the verified version instead of reading the live matrix. agent_watch reads
    # docs/agent-support/agent-support-matrix.yml from a hardcoded path, so without this
    # every real grok bump silently rewrites these tests' inputs: bumping grok_cli to
    # 1.0.5 on 2026-08-21 made `upstream_newer_than_verified` False and failed the
    # cask-lag test, which simulates upstream 1.0.5 against a verified 1.0.3.
    # Keyed by MATRIX key (grok_cli), not the config agent name — agent_watch maps
    # agent -> matrix key when it builds verified_map.
    monkeypatch.setattr(agent_watch, "_read_verified_versions_from_matrix", lambda _path: {"grok_cli": "1.0.3"})
    monkeypatch.setattr(
        agent_watch,
        "_fetch_upstream",
        lambda _source, timeout: {"ok": True, "version": cask, "url": "https://example.invalid"},
    )
    monkeypatch.setattr(
        agent_watch,
        "_run_cmd",
        lambda argv, timeout: (
            0,
            _json.dumps(
                {
                    "currentVersion": "1.0.3",
                    "latestVersion": cli_latest,
                    "updateAvailable": cli_latest != "1.0.3",
                    "channel": "stable",
                    "error": None,
                }
            ),
            "",
        ),
    )
    assert agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)]) == 0
    report_path = next(report_root.glob("*/report.json"))
    return _json.loads(report_path.read_text())["results"]["grok"]


def test_weekly_run_is_clean_when_the_sidecar_is_intact(tmp_path, monkeypatch):
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root)
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root)

    contract = grok["weekly"]["discovery_path_contract"]
    assert contract["ok"] is True
    assert contract["required_companion_files"][0]["ok"] is True
    assert grok["severity"] != "high"
    assert grok["compatibility"]["verdict"] != "monitoring_broken"
    assert "probe_or_discovery_failed" not in grok["compatibility"]["blockers"]


def test_weekly_run_with_a_missing_sidecar_is_not_reported_clean(tmp_path, monkeypatch, capsys):
    """The P1 regression: total Grok discovery outage that reported as no drift."""
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root, write_summary=False)
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root)

    contract = grok["weekly"]["discovery_path_contract"]
    assert contract["ok"] is False
    assert contract["required_companion_files"][0]["error"] == "missing"
    assert grok["severity"] == "high"
    assert grok["recommendation"] == "prepare_hotfix"
    assert grok["compatibility"]["verdict"] == "monitoring_broken"
    assert "probe_or_discovery_failed" in grok["compatibility"]["blockers"]
    assert grok["compatibility"]["supports_installed"] is False
    assert grok["compatibility"]["supports_latest"] is False
    # And the fingerprint says why, rather than leaving a silently thinner sample.
    assert grok["weekly"]["local_schema"]["summary_error"] == "missing"
    assert "severity=high" in capsys.readouterr().out


def test_weekly_run_with_a_corrupt_sidecar_is_not_reported_clean(tmp_path, monkeypatch):
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root, summary_text='{"info":')
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root)

    assert grok["weekly"]["discovery_path_contract"]["required_companion_files"][0]["error"] == "invalid_json"
    assert grok["severity"] == "high"
    assert grok["compatibility"]["verdict"] == "monitoring_broken"


def test_weekly_run_with_a_non_object_sidecar_is_not_reported_clean(tmp_path, monkeypatch):
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root, summary_text="[]")
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root)

    assert grok["weekly"]["discovery_path_contract"]["required_companion_files"][0]["error"] == "not_json_object"
    assert grok["severity"] == "high"
    assert grok["compatibility"]["verdict"] == "monitoring_broken"


def test_weekly_run_uses_the_cli_version_when_the_cask_lags(tmp_path, monkeypatch, capsys):
    """The P2 regression: compatibility decided against a version known to be stale."""
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root)
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root, cask="1.0.3", cli_latest="1.0.5")

    assert grok["upstream"]["parsed_version"] == "1.0.5"
    assert grok["upstream"]["parsed_version_provenance"] == "cli_probe"
    reconciliation = grok["upstream"]["reconciliation"]
    assert reconciliation["upstream_source_version"] == "1.0.3"
    assert reconciliation["probe_version"] == "1.0.5"
    assert reconciliation["sources_disagree"] is True
    # verified is 1.0.3 in the matrix; against the stale cask this comparison was
    # False, and the newer build went unnoticed.
    assert grok["diff"]["upstream_newer_than_verified"] is True
    assert grok["compatibility"]["latest_available_version"] == "1.0.5"
    assert grok["compatibility"]["supports_latest"] is not True
    assert "latest_disagree=probe:1.0.5/source:1.0.3/used:1.0.5" in capsys.readouterr().out


def test_weekly_run_keeps_the_cask_version_when_the_cli_reports_lower(tmp_path, monkeypatch, capsys):
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root)
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root, cask="1.0.7", cli_latest="1.0.5")

    assert grok["upstream"]["parsed_version"] == "1.0.7"
    assert grok["upstream"]["parsed_version_provenance"] == "upstream_source"
    assert grok["upstream"]["reconciliation"]["sources_disagree"] is True
    assert grok["diff"]["upstream_newer_than_verified"] is True
    assert "latest_disagree=probe:1.0.5/source:1.0.7/used:1.0.7" in capsys.readouterr().out


def test_weekly_run_records_provenance_when_sources_agree(tmp_path, monkeypatch):
    report_root = tmp_path / "out"
    cfg_path = _grok_weekly_config(tmp_path, report_root)
    grok = _run_weekly(tmp_path, monkeypatch, cfg_path, report_root, cask="1.0.3", cli_latest="1.0.3")

    assert grok["upstream"]["parsed_version"] == "1.0.3"
    assert grok["upstream"]["parsed_version_provenance"] == "both_agree"
    assert grok["upstream"]["reconciliation"]["sources_disagree"] is False


def test_agents_without_a_declaring_probe_report_source_provenance(tmp_path, monkeypatch):
    """Provenance must be filled in for every agent, not just the reconciled one."""
    report_root = tmp_path / "out"
    cfg = {
        "report_root": str(report_root),
        "agents": {
            "codex": {
                "cadence": {"weekly": True},
                "installed_version_cmd": ["codex", "--version"],
                "upstream": [{"kind": "github_latest_release", "repo": "openai/codex"}],
                "risk_keywords": {"schema": [], "usage": []},
                "weekly": {},
            }
        },
    }
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(_json.dumps(cfg))

    monkeypatch.chdir(_Path(__file__).resolve().parents[2])
    monkeypatch.setattr(
        agent_watch,
        "_run_installed_version_cmds",
        lambda _cfg: (["codex", "--version"], 0, "codex 0.147.0", "", "0.147.0"),
    )
    monkeypatch.setattr(agent_watch, "_resolve_cli_binary_mtime", lambda _argv: ("/tmp/fake", None))
    monkeypatch.setattr(
        agent_watch,
        "_fetch_upstream",
        lambda _source, timeout: {"ok": True, "version": "0.147.0", "url": "https://example.invalid"},
    )

    assert agent_watch.main(["--mode", "weekly", "--config", str(cfg_path)]) == 0
    report = _json.loads(next(report_root.glob("*/report.json")).read_text())
    codex = report["results"]["codex"]
    assert codex["upstream"]["parsed_version_provenance"] == "upstream_source"
    assert codex["upstream"]["reconciliation"] is None
