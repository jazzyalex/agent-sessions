"""OpenCode 2.x monitoring: session_v2 + session_message fingerprinting.

OpenCode 2.x keeps the v1 session/message/part tables in opencode.db, frozen,
and writes new sessions only to session_v2/session_message. The weekly and
prebump fingerprints must sample the store being written, and the committed
sqlite_v2 fixture must describe it in the same buckets.
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

import agent_watch  # noqa: E402

FIXTURE_ROOT = REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "opencode" / "sqlite_v2"


def _write_db(
    path: Path,
    *,
    v1_updated: int,
    v2_updated: int | None,
    extra_assistant_key: str | None = None,
    mutate_assistant=None,
    rows_override: list | None = None,
    newer_archived_v2: bool = False,
) -> None:
    """A database with one v1 session and one v2 session.

    rows_override replaces the v2 session's rows; a row's data may be a raw
    string to store unparsed. newer_archived_v2 adds an archived v2 session
    newer than everything else, which must never be sampled.
    """
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
                title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER,
                time_archived INTEGER, summary_additions INTEGER, summary_deletions INTEGER,
                summary_files INTEGER, summary_diffs TEXT
            );
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE session_v2 (
                id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, title TEXT,
                version TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER
            );
            CREATE TABLE session_message (
                id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT
            );
            """
        )
        conn.execute(
            "INSERT INTO session VALUES ('ses_v1','p',NULL,'s','/tmp','t','1.19.3',1,?,NULL,NULL,NULL,NULL,NULL)",
            (v1_updated,),
        )
        conn.execute("INSERT INTO message VALUES ('msg_v1','ses_v1',1,'{\"role\":\"user\"}')")
        conn.execute(
            "INSERT INTO session_v2 VALUES ('ses_v2','p',NULL,'s','/tmp','t','2.1.1','{\"id\":\"m\"}',1,?,NULL)",
            (v2_updated,),
        )
        assistant = {
            "time": {"created": 1, "completed": 2},
            "agent": "build",
            "model": {"id": "m", "providerID": "p"},
            "content": [
                {"type": "text", "text": "hi"},
                {"type": "tool", "id": "c1", "name": "shell",
                 "state": {"status": "completed", "input": {"command": "pwd"},
                           "content": [{"type": "text", "text": "/tmp"}]},
                 "time": {"created": 1, "completed": 2}},
            ],
            "finish": "stop",
            "tokens": {"input": 1, "output": 1, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        }
        if extra_assistant_key:
            assistant[extra_assistant_key] = True
        if mutate_assistant:
            mutate_assistant(assistant)
        rows = [
            ("msg_u", "user", 0, {"time": {"created": 1}, "text": "pwd please", "files": [], "agents": []}),
            ("msg_a", "assistant", 1, assistant),
            ("msg_i", "idle", 2, {"time": {"created": 3}, "outcome": "succeeded"}),
        ]
        if rows_override is not None:
            rows = rows_override
        for row_id, row_type, seq, data in rows:
            conn.execute(
                "INSERT INTO session_message VALUES (?, 'ses_v2', ?, ?, 1, 1, ?)",
                (row_id, row_type, seq, data if isinstance(data, str) else json.dumps(data)),
            )
        if newer_archived_v2:
            conn.execute(
                "INSERT INTO session_v2 VALUES ('ses_arch','p',NULL,'s','/tmp','t','2.1.1',NULL,1,999999,999999)"
            )
            conn.execute(
                "INSERT INTO session_message VALUES ('msg_arch', 'ses_arch', 'archived-only-kind', 0, 1, 1, '{}')"
            )
        conn.commit()
    finally:
        conn.close()


def test_v2_store_is_sampled_when_it_holds_the_newest_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)

    fp = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert fp["store"] == "session_v2"
    assert fp["session_version"] == "2.1.1"
    assert fp["message_rows_parsed"] == 3
    keys = fp["type_keys"]
    assert "session_message.assistant" in keys
    assert keys["session_message.assistant.content.tool"] == ["id", "name", "state", "time", "type"]
    assert keys["session_message.assistant.tool_state.completed"] == ["content", "input", "status"]
    assert keys["session_message.assistant.tokens"] == ["cache", "input", "output", "reasoning"]
    assert "session_message.idle" in keys
    assert not any(k.startswith("message.") or k.startswith("part.") for k in keys), "v1 rows must not be mixed in"


def test_v1_store_is_sampled_when_a_1x_build_wrote_the_newest_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=300, v2_updated=200)

    fp = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert "store" not in fp
    assert "session" in fp["type_keys"]
    assert "message.user" in fp["type_keys"]


def test_committed_v2_fixture_matches_a_clean_v2_sample(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fixtures = sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json"))
    assert len(fixtures) == 8

    baseline = agent_watch._baseline_type_keys_for_agent("opencode", fixtures)
    sample = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    for bucket, keys in sample["type_keys"].items():
        if bucket == "session_v2":
            continue  # the synthetic test table has fewer columns than the real one
        assert bucket in baseline, bucket
        assert set(keys) <= set(baseline[bucket]), (bucket, set(keys) - set(baseline[bucket]))


def test_new_assistant_key_in_v2_rows_is_reported_against_the_fixture(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, extra_assistant_key="brandNewField")
    fixtures = sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json"))

    baseline = agent_watch._baseline_type_keys_for_agent("opencode", fixtures)
    sample = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)

    assert "brandNewField" in sample["type_keys"]["session_message.assistant"]
    assert "brandNewField" not in baseline["session_message.assistant"]


def _fingerprint(db: Path) -> dict:
    return agent_watch._opencode_sqlite_latest_session_schema_fingerprint(db, max_messages=250, max_parts=2500)


def _baseline() -> dict:
    return agent_watch._baseline_type_keys_for_agent("opencode", sorted(str(p) for p in FIXTURE_ROOT.rglob("*.json")))


PREBUMP_REQUIRED = [
    "session_message.user",
    "session_message.assistant",
    "session_message.assistant.tool_state.completed",
]


LEGACY_REQUIRED = ["message.user", "message.assistant", "part.tool"]


def _opencode_prebump_cfg() -> dict:
    cfg = json.loads((REPO / "docs" / "agent-support" / "agent-watch-config.json").read_text())
    return cfg["agents"]["opencode"]["prebump"]


def test_configured_prebump_requires_buckets_per_store():
    pb = _opencode_prebump_cfg()
    assert "required_schema_buckets" not in pb, "a single list cannot serve both 1.x and 2.x"
    assert pb["required_schema_buckets_by_store"] == {"session_v2": PREBUMP_REQUIRED, "legacy": LEGACY_REQUIRED}


def _write_v1_only_db(path: Path) -> None:
    """A 1.x database: no 2.x tables, one tool-using session in message/part."""
    conn = sqlite3.connect(path)
    try:
        conn.executescript(
            """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
                title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER,
                time_archived INTEGER, summary_additions INTEGER, summary_deletions INTEGER,
                summary_files INTEGER, summary_diffs TEXT
            );
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_1','p',NULL,'s','/tmp','t','1.19.3',1,2,NULL,NULL,NULL,NULL,NULL);
            INSERT INTO message VALUES ('msg_u','ses_1',1,'{"role":"user","time":{"created":1}}');
            INSERT INTO message VALUES ('msg_a','ses_1',2,'{"role":"assistant","time":{"created":2},"modelID":"m","providerID":"p"}');
            INSERT INTO part VALUES ('prt_t','msg_a','ses_1',2,'{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed"}}');
            """
        )
        conn.commit()
    finally:
        conn.close()


def _matrix_baseline() -> dict:
    """The baseline the prebump really uses: every OpenCode evidence fixture in the matrix."""
    text = (REPO / "docs" / "agent-support" / "agent-support-matrix.yml").read_text()
    block = text.split("\n  opencode:\n", 1)[1].split("\n  hermes:\n", 1)[0]
    paths = [str(REPO / p) for p in re.findall(r'- "(Resources/Fixtures/stage0/agents/opencode/[^"]+)"', block)]
    assert len(paths) > 7, "the matrix lists both the 1.x and the 2.x fixtures"
    return agent_watch._baseline_type_keys_for_agent("opencode", paths)


def test_valid_1x_session_passes_the_prebump_gate_with_legacy_buckets(tmp_path):
    db = tmp_path / "opencode.db"
    _write_v1_only_db(db)
    fp = _fingerprint(db)
    required = agent_watch._required_schema_buckets_for(_opencode_prebump_cfg(), fp)

    _, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_matrix_baseline(), required_schema_buckets=required
    )

    assert "store" not in fp
    assert required == LEGACY_REQUIRED
    assert matches is True
    # The 2.x list would have rejected this valid 1.x session outright.
    _, with_v2_list = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_matrix_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )
    assert with_v2_list is False


def test_2x_session_gets_the_2x_bucket_list(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    assert agent_watch._required_schema_buckets_for(_opencode_prebump_cfg(), _fingerprint(db)) == PREBUMP_REQUIRED


def test_unmapped_store_fails_the_prebump_gate_closed(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fp = dict(_fingerprint(db), store="session_v3")
    required = agent_watch._required_schema_buckets_for(_opencode_prebump_cfg(), fp)

    schema_diff, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=required
    )

    assert required == ["<unmapped store: session_v3>"]
    assert matches is False
    assert schema_diff["missing_required_schema_buckets"] == ["<unmapped store: session_v3>"]


def test_wrong_typed_content_and_files_are_violations_not_crashes(tmp_path):
    for bad in (1, True, "text", {"type": "text"}):
        assert "assistant.content" in agent_watch._opencode_v2_required_field_violations(
            "assistant", {"model": {"id": "m"}, "content": bad,
                          "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}}
        ), bad
        buckets = dict(agent_watch._opencode_v2_message_buckets("assistant", {"content": bad}))
        assert f"content:{agent_watch._json_type_name(bad)}" in buckets["session_message.assistant.shape"]
        agent_watch._opencode_v2_message_buckets("user", {"text": "", "files": bad})

    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, mutate_assistant=lambda a: a.__setitem__("content", 1))
    fp = _fingerprint(db)
    assert fp["required_field_violations"] == {"assistant.content": 1}
    assert _weekly(fp)[1] is False


def test_agents_without_a_store_map_keep_their_single_list():
    assert agent_watch._required_schema_buckets_for({"required_schema_buckets": ["a"]}, {"store": "x"}) == ["a"]
    assert agent_watch._required_schema_buckets_for({}, {}) is None


def test_header_only_v2_session_fails_the_prebump_gate(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, rows_override=[])

    fp = _fingerprint(db)
    _, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert fp["store"] == "session_v2"
    assert agent_watch._observed_event_count(fp) == 0, "a session header is not an observed record"
    assert matches is False


def test_session_without_a_completed_tool_fails_the_prebump_gate(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a.__setitem__("content", [{"type": "text", "text": "hi"}]))

    schema_diff, matches = agent_watch._prebump_schema_check(
        fingerprint=_fingerprint(db), baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert matches is False
    assert schema_diff["missing_required_schema_buckets"] == ["session_message.assistant.tool_state.completed"]


def test_rich_v2_session_passes_the_prebump_gate_and_counts_physical_rows(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)

    fp = _fingerprint(db)
    _, matches = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )

    assert matches is True
    assert agent_watch._observed_event_count(fp) == 3, "three rows, not the sum of their nested buckets"


def test_non_object_and_invalid_rows_are_parse_errors_that_fail_both_gates(tmp_path):
    db = tmp_path / "opencode.db"
    good = [
        ("msg_u", "user", 0, {"time": {"created": 1}, "text": "hi", "files": [], "agents": []}),
    ]
    for bad_data in ("[]", "null", "42", "{not json"):
        path = tmp_path / f"db_{abs(hash(bad_data))}.db"
        _write_db(path, v1_updated=100, v2_updated=200,
                  rows_override=good + [("msg_bad", "assistant", 1, bad_data)])
        fp = _fingerprint(path)
        assert fp["parse_errors"] == 1, bad_data

        _, prebump_ok = agent_watch._prebump_schema_check(fingerprint=fp, baseline_type_keys=_baseline())
        assert prebump_ok is False, bad_data

        schema_diff = agent_watch._schema_diff(
            observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
            observed_event_count=agent_watch._observed_event_count(fp),
        )
        assert schema_diff["unknown_only_is_empty"], "the readable rows alone look clean"
        assert agent_watch._weekly_schema_matches(schema_diff, fp) is False, bad_data
        assert schema_diff["parse_errors"] == 1


def test_weekly_gate_still_passes_a_clean_sample(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert agent_watch._weekly_schema_matches(schema_diff, fp) is True


def test_equal_timestamps_sample_the_original_v1_rows(tmp_path):
    # An untouched migrated copy has the v1 row's time_updated and may have
    # lost assistant steps; the v1 rows are the faithful sample.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=200, v2_updated=200)
    fp = _fingerprint(db)
    assert "store" not in fp
    assert "message.user" in fp["type_keys"]


def test_null_v2_timestamp_does_not_beat_a_v1_session(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=None)
    assert "store" not in _fingerprint(db)


def test_archived_v2_session_is_never_sampled(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, newer_archived_v2=True)
    fp = _fingerprint(db)
    assert fp["store"] == "session_v2"
    assert "session_message.archived-only-kind" not in fp["type_keys"]
    assert "session_message.assistant" in fp["type_keys"]


def test_nested_cache_token_rename_is_drift(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a["tokens"].__setitem__("cache", {"hit": 0, "write": 0}))
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert schema_diff["unknown_keys"]["session_message.assistant.tokens.cache"] == ["hit"]
    assert fp["required_field_violations"] == {"assistant.tokens.cache.read": 1}
    assert agent_watch._weekly_schema_matches(schema_diff, fp) is False


def _weekly(fp: dict) -> tuple[dict, bool]:
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    return schema_diff, agent_watch._weekly_schema_matches(schema_diff, fp)


def test_model_structure_change_is_drift(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a.__setitem__("model", {"ref": "p/m"}))
    fp = _fingerprint(db)
    schema_diff, matches = _weekly(fp)
    assert schema_diff["unknown_keys"]["session_message.assistant.model"] == ["ref"]
    assert fp["required_field_violations"] == {"assistant.model.id": 1}
    assert matches is False


def test_model_turning_into_a_string_is_drift_not_missing_coverage(tmp_path):
    # The nested model bucket disappears; the shape bucket records the new type.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a.__setitem__("model", "opencode/m"))
    fp = _fingerprint(db)
    schema_diff, matches = _weekly(fp)
    assert "session_message.assistant.model" not in fp["type_keys"]
    assert schema_diff["unknown_keys"]["session_message.assistant.shape"] == ["model:string"]
    assert matches is False


def test_cache_turning_into_an_array_is_drift(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a["tokens"].__setitem__("cache", [0, 0]))
    schema_diff, matches = _weekly(_fingerprint(db))
    assert schema_diff["unknown_keys"]["session_message.assistant.tokens.shape"] == ["cache:array"]
    assert matches is False


def test_removed_required_field_without_replacement_fails_the_gates(tmp_path):
    # Only key *removals*: no unknown key appears, so the schema diff alone is clean.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: (a["model"].pop("id"), a["tokens"].pop("output")))
    fp = _fingerprint(db)
    schema_diff, matches = _weekly(fp)
    assert schema_diff["unknown_only_is_empty"] is True
    assert fp["required_field_violations"] == {"assistant.model.id": 1, "assistant.tokens.output": 1}
    assert fp["parse_errors"] == 1
    assert matches is False
    _, prebump_ok = agent_watch._prebump_schema_check(
        fingerprint=fp, baseline_type_keys=_baseline(), required_schema_buckets=PREBUMP_REQUIRED
    )
    assert prebump_ok is False


def test_tool_item_without_status_fails_the_gates(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              mutate_assistant=lambda a: a["content"][1]["state"].pop("status"))
    fp = _fingerprint(db)
    assert fp["required_field_violations"] == {"assistant.tool.state.status": 1}
    assert _weekly(fp)[1] is False


def test_clean_sample_has_no_required_field_violations(tmp_path):
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200)
    fp = _fingerprint(db)
    assert fp["required_field_violations"] == {}
    assert fp["parse_errors"] == 0


def test_weekly_parse_errors_block_a_clean_prebump_substitution(tmp_path):
    # An earlier clean prebump must not replace a failing weekly verdict whose
    # own sample has unreadable records.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              rows_override=[("msg_u", "user", 0, {"text": "hi"}), ("msg_bad", "assistant", 1, "[]")])
    weekly_diff, weekly_ok = _weekly(_fingerprint(db))
    assert weekly_ok is False
    assert agent_watch._prebump_may_replace_weekly_verdict(weekly_diff) is False

    clean = tmp_path / "clean.db"
    _write_db(clean, v1_updated=100, v2_updated=200)
    clean_diff, clean_ok = _weekly(_fingerprint(clean))
    assert clean_ok is True
    assert agent_watch._prebump_may_replace_weekly_verdict(clean_diff) is True
    assert agent_watch._prebump_may_replace_weekly_verdict(None) is True


def _assess(**overrides):
    args = dict(
        verified="2.1.1", installed="2.1.1", upstream="2.1.1", upstream_sources_configured=True,
        upstream_errors=[], installed_newer_than_verified=False, upstream_newer_than_verified=False,
        monitoring_failed=False, schema_matches_baseline=False,
        schema_diff={"unknown_only_is_empty": True, "parse_errors": 3, "coverage_ratio": 1.0,
                     "observed_event_count": 100},
        sample_freshness={"is_stale": False}, fresh_evidence_source="latest_prebump_report",
        probe_failed=False, real_session_driver_configured=True,
    )
    args.update(overrides)
    return agent_watch._build_compatibility_assessment(**args)


def test_unreadable_weekly_sample_blocks_supports_latest_even_with_a_clean_prebump():
    # The reviewer's reproduction: steady state, clean prebump report on disk,
    # current weekly sample has 3 unreadable records and no unknown keys.
    weekly = {"unknown_only_is_empty": True, "parse_errors": 3, "coverage_ratio": 1.0, "observed_event_count": 100}
    result = _assess(weekly_schema_diff=weekly)

    assert result["verdict"] == "format_drift_detected"
    assert "sample_unreadable_records" in result["blockers"]
    assert result["supports_latest"] is False
    assert result["supports_installed"] is False
    assert "unreadable records" in result["next_action"]


def test_unreadable_sample_without_a_prebump_names_its_cause():
    result = _assess(fresh_evidence_source=None, installed_newer_than_verified=True, verified="2.1.0")
    assert result["verdict"] == "format_drift_detected"
    assert "sample_unreadable_records" in result["blockers"]


def test_readable_sample_with_a_clean_prebump_still_supports_latest():
    clean = {"unknown_only_is_empty": True, "parse_errors": 0, "coverage_ratio": 1.0, "observed_event_count": 100}
    result = _assess(schema_matches_baseline=True, schema_diff=clean, weekly_schema_diff=clean)
    assert result["verdict"] == "supports_latest"
    assert "sample_unreadable_records" not in result["blockers"]


def _qwen_glued_fixture() -> Path:
    return REPO / "Resources" / "Fixtures" / "stage0" / "agents" / "qwen" / "019f0000-0000-7000-8000-000000000005.jsonl"


def test_qwen_glued_objects_are_tolerated_like_the_app_parser(tmp_path):
    fp = agent_watch._schema_fingerprint_for_agent("qwen", _qwen_glued_fixture(), 5000)
    assert fp["parse_errors"] == 0
    assert fp["tolerated_glued_lines"] == 1
    assert sum(fp["type_counts"].values()) == 2, "both glued objects are fingerprinted"

    schema_diff = {"unknown_only_is_empty": True}
    assert agent_watch._weekly_schema_matches(schema_diff, fp) is True


def test_glued_line_with_junk_stays_a_parse_error(tmp_path):
    line = _qwen_glued_fixture().read_text(encoding="utf-8").strip()
    first, second = (json.dumps(o) for o in agent_watch._glued_json_objects(line))
    for bad in (f"junk{line}", f"{line}junk", f"{first}junk{second}", f"{first} [1]"):
        path = tmp_path / f"{abs(hash(bad))}.jsonl"
        path.write_text(bad + "\n", encoding="utf-8")
        fp = agent_watch._schema_fingerprint_for_agent("qwen", path, 5000)
        assert fp["parse_errors"] == 1, bad
        assert fp["tolerated_glued_lines"] == 0, bad


def test_glued_lines_are_parse_errors_for_agents_whose_parser_does_not_recover_them(tmp_path):
    path = tmp_path / "rollout.jsonl"
    path.write_text('{"type":"a"}{"type":"b"}\n', encoding="utf-8")
    fp = agent_watch._schema_fingerprint_for_agent("claude", path, 5000)
    assert fp["parse_errors"] == 1
    assert fp["tolerated_glued_lines"] == 0


def test_parse_errors_in_a_later_sampled_session_reach_the_merged_fingerprint():
    first = {"file": "/s/newest.jsonl", "parse_errors": 0, "type_keys": {}}
    second = {"file": "/s/older.jsonl", "parse_errors": 2, "type_keys": {}}
    merged = dict(first)

    agent_watch._merge_sampled_parse_errors(merged, [first, second])

    assert merged["parse_errors"] == 2
    assert merged["parse_errors_by_file"] == {"/s/older.jsonl": 2}
    assert agent_watch._weekly_schema_matches({"unknown_only_is_empty": True}, merged) is False


def test_dsh_merge_sums_parse_errors_across_samples():
    fps = [
        {"file": "/d/a.jsonl.zstd", "parse_errors": 0, "type_keys": {}, "type_counts": {}},
        {"file": "/d/b.jsonl.zstd", "parse_errors": 1, "type_keys": {}, "type_counts": {}},
    ]
    merged = agent_watch._dsh_merge_fingerprints(fps)
    assert merged["parse_errors"] == 1


def test_capture_export_keeps_malformed_rows_instead_of_dropping_the_export(tmp_path):
    import capture_latest_agent_sessions as capture

    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200,
              rows_override=[("msg_u", "user", 0, {"text": "hi"}), ("msg_bad", "assistant", 1, "{not json")])

    export = capture._export_latest_opencode_sqlite_session(db)

    assert export["store"] == "session_v2"
    assert export["parse_errors"] == 1
    bad = export["messages"][1]
    assert bad["raw_data"] == "{not json" and "parse_error" in bad and "data" not in bad
    assert export["messages"][0]["data"] == {"text": "hi"}


def test_capture_export_flags_valid_json_that_is_not_an_object(tmp_path):
    import capture_latest_agent_sessions as capture

    for raw in ("[]", "null", "42"):
        db = tmp_path / f"{abs(hash(raw))}.db"
        _write_db(db, v1_updated=100, v2_updated=200,
                  rows_override=[("msg_u", "user", 0, {"text": "hi"}), ("msg_bad", "assistant", 1, raw)])
        export = capture._export_latest_opencode_sqlite_session(db)
        bad = export["messages"][1]
        assert export["parse_errors"] == 1, raw
        assert bad["raw_data"] == raw and "not an object" in bad["parse_error"] and "data" not in bad


def test_capture_export_uses_v1_rows_on_equal_timestamps(tmp_path):
    import capture_latest_agent_sessions as capture

    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=200, v2_updated=200)
    export = capture._export_latest_opencode_sqlite_session(db)
    assert "store" not in export
    assert export["session"]["id"] == "ses_v1"


# The only string values the sqlite_v2 fixture may contain. Anything else is
# real data that escaped redaction. Every list is exact: a fixture rebuild that
# brings a new value or key must update it here on purpose.
_FIXTURE_PLACEHOLDERS = {"redacted", "fixture.png", "fixture", "/tmp/fixture", "ses_fixture_v2", "proj_fixture", "2.1.1", ""}
# Schema discriminators are the schema itself and survive redaction, but only
# with these exact values.
_FIXTURE_DISCRIMINATOR_VALUES = {
    "type": {
        "assistant", "compaction", "direct", "idle", "inline", "provider.error", "reasoning",
        "shell", "synthetic", "system", "text", "tool", "tool.execution", "user",
    },
    "status": {"completed", "error", "exited"},
    "reason": {"auto"},
    "outcome": {"succeeded"},
    "finish": {"stop"},
    "name": {"todowrite", "fixture.png"},
}
# Every object key that may appear. Keys come from OpenCode's schema; an
# unexpected one may be a map keyed by real data (a path, an ID, a secret).
_FIXTURE_KEYS = {
    "agent", "agents", "anthropic", "cache", "caller", "completed", "content", "cost", "created", "data",
    "directory", "end", "error", "executed", "files", "finish", "id", "idle_outcome", "input", "itemId",
    "mention", "message", "metadata", "mime", "model", "name", "native", "openai", "outcome", "output",
    "parent_id", "path", "phase", "project_id", "providerID", "ran", "rawFinish", "read", "reason",
    "reasoning", "reasoningEncryptedContent", "reasoningField", "redactedData", "resume_attempts",
    "signature", "slug", "snapshot", "source", "start", "state", "status", "streamed", "summary",
    "summary_additions", "summary_deletions", "summary_files", "text", "time", "time_created", "time_idle",
    "time_updated", "time_viewed", "title", "tokens", "tokens_cache_read", "tokens_cache_write",
    "tokens_input", "tokens_output", "tokens_reasoning", "type", "variant", "version", "write", "xai",
    # shell rows
    "command", "cursor", "exit", "shellID", "size", "truncated",
    # session_v2 columns that are NULL on the owner's disk but exist in the schema
    "fork_boundary", "fork_session_id", "permission", "revert", "share_url", "summary_diffs",
    "time_compacting", "time_suspended", "workspace_id",
}


def test_shell_row_and_schema_only_session_columns_are_not_drift(tmp_path):
    # The app renders shell rows and these columns exist upstream; neither had
    # appeared on the owner's disk when the fixture was built.
    db = tmp_path / "opencode.db"
    _write_db(db, v1_updated=100, v2_updated=200, rows_override=[
        ("msg_u", "user", 0, {"time": {"created": 1}, "text": "hi", "files": [], "agents": []}),
        ("msg_sh", "shell", 1, {"time": {"created": 2, "completed": 3}, "shellID": "sh_1", "command": "ls",
                                "status": "exited", "exit": 0,
                                "output": {"output": "a.txt", "cursor": 5, "size": 5, "truncated": False}}),
    ])
    fp = _fingerprint(db)
    schema_diff = agent_watch._schema_diff(
        observed_type_keys=fp["type_keys"], baseline_type_keys=_baseline(),
        observed_event_count=agent_watch._observed_event_count(fp),
    )
    assert "session_message.shell" in fp["type_keys"]
    assert schema_diff["unknown_types"] == [] and schema_diff["unknown_keys"] == {}

    baseline = _baseline()
    for column in ("fork_session_id", "fork_boundary", "share_url", "revert", "workspace_id", "time_suspended"):
        assert column in baseline["session_v2"], column


def _fixture_string_violations(value, key=None, path="$"):
    if isinstance(value, dict):
        for k, v in value.items():
            if k not in _FIXTURE_KEYS:
                yield f"{path}: unexpected key {k!r}"
            yield from _fixture_string_violations(v, k, f"{path}.{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from _fixture_string_violations(v, key, f"{path}[{i}]")
    elif isinstance(value, str):
        if value in _FIXTURE_PLACEHOLDERS:
            return
        if value in _FIXTURE_DISCRIMINATOR_VALUES.get(key, set()):
            return
        yield f"{path}={value!r}"
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        if value != 0:
            yield f"{path}={value!r} (numbers are redacted to 0)"


def test_v2_fixture_values_follow_the_redaction_policy():
    files = sorted(FIXTURE_ROOT.rglob("*.json"))
    assert len(files) == 8
    violations = []
    for path in files:
        obj = json.loads(path.read_text(encoding="utf-8"))
        # session_message files wrap the row: {"type": <row type>, "data": {...}}
        violations += [f"{path.name}: {v}" for v in _fixture_string_violations(obj)]
    assert violations == []


def test_redaction_policy_catches_a_leaked_prompt_path_and_secret():
    leaked = {
        "data": {
            "text": "please fix my billing code",
            "files": [{"name": "/home/someone/notes.txt"}],
            "tokens": {"input": 1234},
            "auth": "sk-live-abc",
        }
    }
    found = list(_fixture_string_violations(leaked))
    # text, name, the non-zero count, plus "auth" as an unexpected key and its value.
    assert len(found) == 5, found


def test_redaction_policy_catches_secrets_in_discriminators_and_keys():
    leaked = {
        "type": "sk-live-abc",  # short, no spaces: the old length rule let it through
        "status": "completed",
        "time": {"/Users/someone/project": 0},  # a map keyed by real data
    }
    found = list(_fixture_string_violations(leaked))
    assert any("sk-live-abc" in item for item in found), found
    assert any("/Users/someone/project" in item for item in found), found
    assert not any("completed" in item for item in found), found
