# scripts/tests/test_nested_schema_fingerprint.py
"""
Codex/Copilot/Claude fingerprint their payload interiors, not just the envelope.
Each test here pins a rule that was added because its absence produced a real,
silent wrong answer during the 2026-08-03 format check.
"""
import json
import os
from pathlib import Path

import agent_watch

REPO = Path(__file__).resolve().parents[2]


def _write(tmp_path, rows, name="s.jsonl"):
    p = tmp_path / name
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    return p


def test_flat_fingerprint_sees_only_the_envelope(tmp_path):
    # The bug this whole feature exists for: codex lines are {payload,timestamp,type},
    # so the flat fingerprint reports a clean bill of health no matter what drifts.
    p = _write(tmp_path, [{"type": "turn_context", "timestamp": "t",
                           "payload": {"model": "m", "brand_new_key": 1}}])
    flat = agent_watch._jsonl_schema_fingerprint(p, max_lines=100)
    assert flat["type_keys"]["turn_context"] == ["payload", "timestamp", "type"]
    assert "turn_context.payload" not in flat["type_keys"]

    nested = agent_watch._nested_jsonl_schema_fingerprint(p, max_lines=100)
    assert "brand_new_key" in nested["type_keys"]["turn_context.payload"]


def test_payload_type_discriminates_only_at_the_wrapper(tmp_path):
    # `type` names the real event at depth 0->1 (event_msg.payload:token_count), but
    # deeper it tags config variants. Splitting on those made an ordinary
    # sandbox_policy change look like a brand-new schema bucket.
    p = _write(tmp_path, [
        {"type": "event_msg", "timestamp": "t",
         "payload": {"type": "token_count", "info": {"input_tokens": 1}}},
        {"type": "turn_context", "timestamp": "t",
         "payload": {"sandbox_policy": {"type": "read-only"}}},
        {"type": "turn_context", "timestamp": "t",
         "payload": {"sandbox_policy": {"type": "danger-full-access"}}},
    ])
    keys = agent_watch._nested_jsonl_schema_fingerprint(p, max_lines=100)["type_keys"]
    assert "event_msg.payload:token_count" in keys
    assert "event_msg.payload:token_count.info" in keys
    # Both policy variants collapse into ONE bucket.
    assert "turn_context.payload.sandbox_policy" in keys
    assert not [k for k in keys if k.startswith("turn_context.payload.sandbox_policy:")]


def test_opaque_keys_are_recorded_but_never_walked(tmp_path):
    # codex's patch_apply_end.changes is keyed by ABSOLUTE FILE PATH: walking it
    # invented a bucket per edited file AND wrote real user paths into the report.
    p = _write(tmp_path, [{"type": "event_msg", "timestamp": "t", "payload": {
        "type": "patch_apply_end",
        "changes": {"/Users/someone/secret/a.txt": {"unified_diff": "x"}},
    }}])
    keys = agent_watch._schema_fingerprint_for_agent("codex", p, max_lines=100)["type_keys"]
    assert "changes" in keys["event_msg.payload:patch_apply_end"]
    assert not [k for k in keys if "/Users/" in k]


def test_qwen_function_args_is_named_but_never_walked(tmp_path):
    # systemPayload.uiEvent.function_args is the telemetry ECHO of a tool's own
    # parameter object, so its keys are whatever tool ran. Walking it made every new
    # tool parameter read as Qwen schema drift on the 2026-08-17 first monitored run.
    p = _write(tmp_path, [{"type": "system", "subtype": "ui_telemetry", "systemPayload": {
        "uiEvent": {
            "function_name": "Read",
            "function_args": {"file_path": "/Users/someone/secret/a.txt", "limit": 20},
        },
    }}])
    keys = agent_watch._schema_fingerprint_for_agent("qwen", p, max_lines=100)["type_keys"]
    assert "function_args" in keys["system.systemPayload.uiEvent"]
    assert "system.systemPayload.uiEvent.function_args" not in keys
    assert not [k for k in keys if "/Users/" in k]


def test_pi_detects_nested_content_type_and_usage_key_without_values(tmp_path):
    baseline = _write(tmp_path, [{
        "type": "message",
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": "baseline-private-value"}],
            "usage": {"input": 1, "output": 2},
        },
    }], name="pi-baseline.jsonl")
    observed = _write(tmp_path, [{
        "type": "message",
        "message": {
            "role": "assistant",
            "content": [{
                "type": "futureBlock",
                "futureSchemaKey": "pi-private-value-sentinel",
            }],
            "usage": {
                "input": 1,
                "output": 2,
                "futureUsageKey": "pi-private-usage-sentinel",
            },
        },
    }], name="pi-observed.jsonl")

    baseline_fp = agent_watch._schema_fingerprint_for_agent("pi", baseline, max_lines=100)
    observed_fp = agent_watch._schema_fingerprint_for_agent("pi", observed, max_lines=100)
    diff = agent_watch._schema_diff(
        observed_type_keys=observed_fp["type_keys"],
        baseline_type_keys=baseline_fp["type_keys"],
    )

    assert "message.message.content:futureBlock" in diff["unknown_types"]
    assert diff["unknown_keys"]["message.message.usage"] == ["futureUsageKey"]
    assert "pi-private-value-sentinel" not in repr(observed_fp)
    assert "pi-private-usage-sentinel" not in repr(observed_fp)


def test_openclaw_detects_nested_content_type_but_hides_tool_arguments(tmp_path):
    baseline = _write(tmp_path, [{
        "type": "message",
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": "baseline-private-value"}],
        },
    }], name="openclaw-baseline.jsonl")
    observed = _write(tmp_path, [{
        "type": "message",
        "message": {
            "role": "assistant",
            "content": [{
                "type": "futureToolCall",
                "futureSchemaKey": "openclaw-private-value-sentinel",
                "arguments": {
                    "openclaw_private_argument_sentinel": "/Users/private/project",
                },
                "input": {
                    "openclaw_private_input_sentinel": "/Users/private/input",
                },
            }],
        },
    }], name="openclaw-observed.jsonl")

    baseline_fp = agent_watch._schema_fingerprint_for_agent(
        "openclaw", baseline, max_lines=100
    )
    observed_fp = agent_watch._schema_fingerprint_for_agent(
        "openclaw", observed, max_lines=100
    )
    diff = agent_watch._schema_diff(
        observed_type_keys=observed_fp["type_keys"],
        baseline_type_keys=baseline_fp["type_keys"],
    )

    bucket = "message.message.content:futureToolCall"
    assert bucket in diff["unknown_types"]
    assert "futureSchemaKey" in observed_fp["type_keys"][bucket]
    assert f"{bucket}.arguments" not in observed_fp["type_keys"]
    assert "input" in observed_fp["type_keys"][bucket]
    assert f"{bucket}.input" not in observed_fp["type_keys"]
    assert "openclaw-private-value-sentinel" not in repr(observed_fp)
    assert "openclaw_private_argument_sentinel" not in repr(observed_fp)
    assert "openclaw_private_input_sentinel" not in repr(observed_fp)
    assert "/Users/private/project" not in repr(observed_fp)
    assert "/Users/private/input" not in repr(observed_fp)


def test_antigravity_detects_nested_tool_call_key_but_hides_args(tmp_path):
    baseline = _write(tmp_path, [{
        "type": "PLANNER_RESPONSE",
        "tool_calls": [{"name": "Read", "args": {"path": "private"}}],
    }], name="antigravity-baseline.jsonl")
    observed = _write(tmp_path, [{
        "type": "PLANNER_RESPONSE",
        "tool_calls": [{
            "name": "Read",
            "futureToolMetadata": "antigravity-private-value-sentinel",
            "args": {
                "antigravity_private_argument_sentinel": "/Users/private/project",
            },
        }],
    }], name="antigravity-observed.jsonl")

    baseline_fp = agent_watch._schema_fingerprint_for_agent(
        "antigravity", baseline, max_lines=100
    )
    observed_fp = agent_watch._schema_fingerprint_for_agent(
        "antigravity", observed, max_lines=100
    )
    diff = agent_watch._schema_diff(
        observed_type_keys=observed_fp["type_keys"],
        baseline_type_keys=baseline_fp["type_keys"],
    )

    bucket = "PLANNER_RESPONSE.tool_calls"
    assert diff["unknown_keys"][bucket] == ["futureToolMetadata"]
    assert f"{bucket}.args" not in observed_fp["type_keys"]
    assert "antigravity-private-value-sentinel" not in repr(observed_fp)
    assert "antigravity_private_argument_sentinel" not in repr(observed_fp)
    assert "/Users/private/project" not in repr(observed_fp)


def test_claude_input_schema_is_named_but_never_walked(tmp_path):
    p = _write(tmp_path, [{
        "type": "attachment",
        "attachment": {
            "type": "deferred_tools_record",
            "entries": [{
                "name": "FutureTool",
                "input_schema": {
                    "properties": {"future_parameter": {"type": "string"}},
                },
            }],
        },
    }])
    keys = agent_watch._schema_fingerprint_for_agent("claude", p, max_lines=100)["type_keys"]
    entries = "attachment.attachment:deferred_tools_record.entries"
    assert "input_schema" in keys[entries]
    assert f"{entries}.input_schema" not in keys
    assert not [bucket for bucket in keys if "future_parameter" in bucket]


def test_claude_tool_id_maps_are_named_but_never_walked(tmp_path):
    p = _write(tmp_path, [{
        "type": "assistant",
        "wireIngestContext": {
            "toolu_private_ingest_id": {"input": {"private_file_path": "/Users/private/file"}},
        },
        "wireToolInputs": {
            "toolu_private_tool_id": {"input": {"private_argument": "value"}},
        },
    }])
    keys = agent_watch._schema_fingerprint_for_agent("claude", p, max_lines=100)["type_keys"]

    assert "wireIngestContext" in keys["assistant"]
    assert "wireToolInputs" in keys["assistant"]
    assert "assistant.wireIngestContext" not in keys
    assert "assistant.wireToolInputs" not in keys
    assert not [bucket for bucket in keys if "toolu_private" in bucket]
    assert not [bucket for bucket in keys if "private_file_path" in bucket]
    assert not [bucket for bucket in keys if "private_argument" in bucket]


def test_claude_file_backup_map_does_not_expose_path_keys(tmp_path):
    p = _write(tmp_path, [{
        "type": "file-history-snapshot",
        "snapshot": {
            "trackedFileBackups": {
                "/Users/private/project/Secret.swift": {
                    "backupFileName": "private-backup",
                    "version": 1,
                },
            },
        },
    }])

    keys = agent_watch._schema_fingerprint_for_agent("claude", p, max_lines=100)["type_keys"]

    assert "trackedFileBackups" in keys["file-history-snapshot.snapshot"]
    assert not [bucket for bucket in keys if "Secret.swift" in bucket]
    assert "file-history-snapshot.snapshot.trackedFileBackups" not in keys


def test_codex_agent_state_map_does_not_expose_agent_ids(tmp_path):
    p = _write(tmp_path, [{
        "type": "event_msg",
        "payload": {
            "type": "item_completed",
            "item": {"agents_states": {"agent-private-id": {"state": "completed"}}},
        },
    }])

    keys = agent_watch._schema_fingerprint_for_agent("codex", p, max_lines=100)["type_keys"]

    assert "agents_states" in keys["event_msg.payload:item_completed.item"]
    assert not [bucket for bucket in keys if "agent-private-id" in bucket]
    assert "event_msg.payload:item_completed.item.agents_states" not in keys


def test_codex_recent_response_metadata_is_fingerprinted_without_values(tmp_path):
    p = _write(tmp_path, [{
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "assistant",
        },
        "metadata": {
            "user_input_order": 7,
            "mcp_attribution": {"status": "private-status-sentinel"},
        },
    }])

    fingerprint = agent_watch._schema_fingerprint_for_agent("codex", p, max_lines=100)
    keys = fingerprint["type_keys"]

    assert "user_input_order" in keys["response_item.metadata"]
    assert "mcp_attribution" in keys["response_item.metadata"]
    assert keys["response_item.metadata.mcp_attribution"] == ["status"]
    assert "private-status-sentinel" not in repr(fingerprint)


def test_copilot_recent_tool_metadata_is_fingerprinted_without_values(tmp_path):
    p = _write(tmp_path, [
        {"type": "assistant.message", "data": {"originatingMessageId": "private-id-sentinel"}},
        {"type": "tool.execution_complete", "data": {"shellExecution": {"exitCode": 0}}},
    ])

    fingerprint = agent_watch._schema_fingerprint_for_agent("copilot", p, max_lines=100)
    keys = fingerprint["type_keys"]

    assert "originatingMessageId" in keys["assistant.message.data"]
    assert "shellExecution" in keys["tool.execution_complete.data"]
    assert keys["tool.execution_complete.data.shellExecution"] == ["exitCode"]
    assert "private-id-sentinel" not in repr(fingerprint)


def test_cursor_roleless_turn_events_have_a_typed_bucket(tmp_path):
    p = _write(tmp_path, [{
        "type": "turn_ended",
        "status": "error",
        "error": "upstream request failed",
    }])

    fingerprint = agent_watch._cursor_transcript_schema_fingerprint(p, max_lines=100)

    assert fingerprint["type_counts"] == {"type.turn_ended": 1}
    assert fingerprint["type_keys"]["type.turn_ended"] == ["error", "status", "type"]


def test_cursor_recent_schema_union_covers_five_newest_transcripts(tmp_path):
    files = []
    for i in range(6):
        rows = [{"role": "assistant", "message": {"content": [{"type": "text", "text": "ok"}]}}]
        if i == 1:
            rows = [
                {"role": "assistant", "message": {"content": [{"type": "thinking", "thinking": "reasoning"}]}},
                {"role": "assistant", "message": {"content": [{"type": "tool_result", "content": "done"}]}},
                {"role": "assistant", "future_monitor_test_key": True},
            ]
        if i == 0:
            rows = [{"role": "assistant", "message": {"content": [{"type": "excluded_old", "text": "old"}]}}]
        path = _write(tmp_path, rows, name=f"chat-{i}.jsonl")
        path.touch()
        # chat-5 is newest; chat-0 is the sixth-newest and must fall outside the cap.
        path_mtime = 100 + i
        os.utime(path, (path_mtime, path_mtime))
        files.append(path)

    fingerprint = agent_watch._cursor_recent_schema_fingerprint(
        [str(tmp_path)], "*.jsonl", max_lines=100
    )

    assert fingerprint is not None
    assert fingerprint["sampled_files"] == [str(path) for path in reversed(files[1:])]
    assert fingerprint["sampled_sessions"] == 5
    assert "content.thinking" in fingerprint["type_keys"]
    assert "content.tool_result" in fingerprint["type_keys"]
    assert "future_monitor_test_key" in fingerprint["type_keys"]["assistant"]
    assert "content.excluded_old" not in fingerprint["type_keys"]
    assert fingerprint["type_counts"]["assistant"] == 7


def test_lists_union_every_element_not_just_the_first(tmp_path):
    # Claude's message.content mixes block types. Sampling only the first element hid
    # every later one — exactly the drift the nesting exists to catch.
    p = _write(tmp_path, [{"type": "assistant", "message": {"type": "message", "content": [
        {"type": "thinking", "thinking": "t"},
        {"type": "text", "text": "hello"},
        {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}},
    ]}}])
    keys = agent_watch._schema_fingerprint_for_agent("claude", p, max_lines=100)["type_keys"]
    content = keys["assistant.message:message.content"]
    for k in ("thinking", "text", "name", "type"):
        assert k in content, f"{k} missing — later list elements were dropped"
    # `input` is opaque for claude (tool-defined), so it is named but not descended into.
    assert "input" in content
    assert "assistant.message:message.content.input" not in keys


def test_thin_sample_needs_both_low_coverage_and_low_volume():
    # Coverage alone false-flagged a healthy 1092-event Claude session, because
    # baselines deliberately hold rare interactive-only families.
    baseline = {f"t{i}": ["a"] for i in range(10)}
    observed = {"t0": ["a"], "t1": ["a"]}
    narrow_and_tiny = agent_watch._schema_diff(
        observed_type_keys=observed, baseline_type_keys=baseline, observed_event_count=3)
    narrow_but_busy = agent_watch._schema_diff(
        observed_type_keys=observed, baseline_type_keys=baseline, observed_event_count=5000)
    assert narrow_and_tiny["coverage_ratio"] < agent_watch._MIN_SAMPLE_COVERAGE_RATIO
    assert narrow_and_tiny["observed_event_count"] < agent_watch._MIN_SAMPLE_EVENT_COUNT
    assert narrow_but_busy["observed_event_count"] >= agent_watch._MIN_SAMPLE_EVENT_COUNT


def test_sibling_sampling_honours_required_types(tmp_path):
    # OpenClaw's glob is `**/*.jsonl` over ~/.openclaw, which also sweeps up audit logs
    # and an embedded codex-home; sampling those unfiltered reported codex's own event
    # types as OpenClaw drift.
    (tmp_path / "agents/main/sessions").mkdir(parents=True)
    real = tmp_path / "agents/main/sessions/a.jsonl"
    real.write_text(json.dumps({"type": "session"}) + "\n", encoding="utf-8")
    foreign = tmp_path / "agents/main/sessions/codex.jsonl"
    foreign.write_text(json.dumps({"type": "turn_context"}) + "\n", encoding="utf-8")

    picked = agent_watch._newest_files_with_types(
        [str(tmp_path)], "**/*.jsonl", ["session", "message"], 5, max_lines=100)
    assert real in picked
    assert foreign not in picked


def test_shipped_fixtures_cover_their_own_nested_baseline():
    # A fixture that cannot fingerprint itself cleanly is not a baseline.
    for agent, rel in (("codex", "codex/small.jsonl"),
                       ("copilot", "copilot/small.jsonl"),
                       ("claude", "claude/small.jsonl"),
                       ("antigravity", "antigravity/cli_small.jsonl"),
                       ("openclaw", "openclaw/small.jsonl")):
        path = REPO / "Resources/Fixtures/stage0/agents" / rel
        fp = agent_watch._schema_fingerprint_for_agent(agent, path, max_lines=5000)
        assert fp["parse_errors"] == 0, f"{rel} has unparseable lines"
        base = agent_watch._baseline_type_keys_for_agent(agent, [str(path)])
        diff = agent_watch._schema_diff(
            observed_type_keys=fp["type_keys"], baseline_type_keys=base)
        assert diff["unknown_only_is_empty"], f"{rel} does not match its own baseline"


def test_every_monitored_agent_is_registered_in_the_rebuild_tool():
    # rebuild_stage0_baseline.py resolves an agent's baseline fixtures by looking its
    # matrix section up through its own hand-maintained MATRIX_KEY map. When an agent is
    # missing, _baseline_paths returns EMPTY and the tool reports the entire schema as
    # missing -- a fabricated total-drift report -- and then dies on --emit. grok hit
    # this on 2026-08-13 (section `grok_cli:`) and qwen hit it again on 2026-08-17
    # (section `qwen_code:`), because nothing forced a newly monitored agent into the
    # map. This is that forcing function.
    import rebuild_stage0_baseline as rebuild

    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json")
                     .read_text(encoding="utf-8"))
    matrix = (REPO / "docs/agent-support/agent-support-matrix.yml").read_text(encoding="utf-8")

    for agent in cfg.get("agents", cfg):
        key = rebuild.MATRIX_KEY.get(agent, agent)
        assert f"\n  {key}:" in matrix, (
            f"{agent}: MATRIX_KEY resolves to '{key}:', which is not a section in "
            f"agent-support-matrix.yml -- _baseline_paths would return empty and the "
            f"tool would report the whole schema as missing")
        assert rebuild._baseline_paths(agent), (
            f"{agent}: resolved no evidence_fixtures from the matrix")


def test_qwen_latest_source_tracks_the_cli_package_not_sdk_releases():
    cfg = json.loads((REPO / "docs/agent-support/agent-watch-config.json")
                     .read_text(encoding="utf-8"))
    assert cfg["agents"]["qwen"]["upstream"] == [
        {"kind": "npm_latest", "package": "@qwen-code/qwen-code"}
    ]


def test_rebuild_merges_missing_grok_sidecar_structure_without_overwriting_values():
    import rebuild_stage0_baseline as rebuild

    existing = {"info": {"id": "fixture-id"}, "agent_name": "grok"}
    observed = {
        "info": {"id": "[trimmed]", "new_key": "[trimmed]"},
        "last_recap": "[trimmed]",
    }
    assert rebuild._merge_missing_structure(existing, observed) == {
        "info": {"id": "fixture-id", "new_key": "[trimmed]"},
        "agent_name": "grok",
        "last_recap": "[trimmed]",
    }


def test_rebuild_redacts_claude_organization_identity_and_string_lists():
    import rebuild_stage0_baseline as rebuild

    source = {
        "type": "attachment",
        "attachment": {
            "type": "credential_org",
            "organizationUuid": "019db6b0-1234-7000-8000-private",
            "builtInTypes": ["private-agent-type"],
        },
    }
    redacted = rebuild._redact(source, frozenset())

    assert redacted["type"] == "attachment"
    assert redacted["attachment"]["type"] == "credential_org"
    assert redacted["attachment"]["organizationUuid"] == rebuild.PLACEHOLDER
    assert redacted["attachment"]["builtInTypes"] == [rebuild.PLACEHOLDER]
