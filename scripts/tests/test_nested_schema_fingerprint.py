# scripts/tests/test_nested_schema_fingerprint.py
"""
Codex/Copilot/Claude fingerprint their payload interiors, not just the envelope.
Each test here pins a rule that was added because its absence produced a real,
silent wrong answer during the 2026-08-03 format check.
"""
import json
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
                       ("claude", "claude/small.jsonl")):
        path = REPO / "Resources/Fixtures/stage0/agents" / rel
        fp = agent_watch._schema_fingerprint_for_agent(agent, path, max_lines=5000)
        assert fp["parse_errors"] == 0, f"{rel} has unparseable lines"
        base = agent_watch._baseline_type_keys_for_agent(agent, [str(path)])
        diff = agent_watch._schema_diff(
            observed_type_keys=fp["type_keys"], baseline_type_keys=base)
        assert diff["unknown_only_is_empty"], f"{rel} does not match its own baseline"
