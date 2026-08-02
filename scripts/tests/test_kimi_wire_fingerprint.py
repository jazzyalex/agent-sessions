# scripts/tests/test_kimi_wire_fingerprint.py
"""
Kimi's renderable content is nested under `context.append_loop_event` -> `event`,
so the generic top-level fingerprint cannot see it. These tests pin the nested
buckets and the two regressions that used to pass silently: streamed assistant
text, and additions inside `part` / `tool.result.result`.
"""
import json
import re
from pathlib import Path

import agent_watch

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "Resources/Fixtures/stage0/agents/kimi/small.jsonl"


def _loop(event, time=1785613801102):
    return {"type": "context.append_loop_event", "event": event, "time": time}


def _text_part(text, *, uuid, turn="2", step=1, step_uuid="s1"):
    return _loop({
        "type": "content.part", "uuid": uuid, "turnId": turn, "step": step,
        "stepUuid": step_uuid, "part": {"type": "text", "text": text},
    })


def _write(tmp_path, lines, name="wire.jsonl"):
    path = tmp_path / name
    path.write_text("".join(json.dumps(obj) + "\n" for obj in lines), encoding="utf-8")
    return path


def _fingerprint(tmp_path, lines):
    return agent_watch._kimi_wire_schema_fingerprint(_write(tmp_path, lines), max_lines=5000)


def _drift(observed, baseline):
    return agent_watch._schema_diff(
        observed_type_keys=observed["type_keys"],
        baseline_type_keys=baseline["type_keys"],
    )


BASELINE_LINES = [
    {"type": "metadata", "protocol_version": "1.4", "created_at": 1785612812000},
    _loop({"type": "step.begin", "uuid": "s1", "turnId": "2", "step": 1}),
    _loop({
        "type": "content.part", "uuid": "p0", "turnId": "2", "step": 1,
        "stepUuid": "s1", "part": {"type": "think", "think": "reasoning"},
    }),
    _text_part("Hi there!", uuid="p1"),
    _loop({
        "type": "tool.call", "uuid": "Bash_0", "turnId": "2", "step": 1, "stepUuid": "s1",
        "toolCallId": "Bash_0", "name": "Bash", "args": {"command": "ls"},
        "description": "Running: ls", "display": {"kind": "command"},
    }),
    _loop({
        "type": "tool.result", "parentUuid": "Bash_0", "toolCallId": "Bash_0",
        "result": {"output": "a\nb", "isError": False},
    }),
    _loop({"type": "step.end", "uuid": "s1", "turnId": "2", "step": 1, "finishReason": "end_turn"}),
]


def test_nested_loop_event_vocabulary_is_recorded(tmp_path):
    fp = _fingerprint(tmp_path, BASELINE_LINES)

    # Top-level map is preserved alongside the nested one.
    assert fp["type_counts"]["metadata"] == 1
    assert fp["type_counts"]["context.append_loop_event"] == 6
    assert fp["type_keys"]["context.append_loop_event"] == ["event", "time", "type"]

    # Histogram of event.type values.
    assert fp["type_counts"]["event.step.begin"] == 1
    assert fp["type_counts"]["event.content.part"] == 2
    assert fp["type_counts"]["event.tool.call"] == 1
    assert fp["type_counts"]["event.tool.result"] == 1
    assert fp["type_counts"]["event.step.end"] == 1
    assert fp["loop_events_parsed"] == 6

    # Keys per event.type.
    assert fp["type_keys"]["event.tool.call"] == [
        "args", "description", "display", "name", "step", "stepUuid",
        "toolCallId", "turnId", "type", "uuid",
    ]

    # part.type values, and the keys inside tool.result.result.
    assert fp["type_keys"]["part.text"] == ["text", "type"]
    assert fp["type_keys"]["part.think"] == ["think", "type"]
    assert fp["type_keys"]["event.tool.result.result"] == ["isError", "output"]

    assert fp["parse_errors"] == 0


def test_identical_journal_reports_no_drift(tmp_path):
    baseline = _fingerprint(tmp_path, BASELINE_LINES)
    observed = agent_watch._kimi_wire_schema_fingerprint(
        _write(tmp_path, BASELINE_LINES, name="observed.jsonl"), max_lines=5000
    )
    diff = _drift(observed, baseline)
    assert diff["unknown_types"] == []
    assert diff["unknown_keys"] == {}
    assert diff["is_empty"]


def test_new_part_type_surfaces_as_drift(tmp_path):
    baseline = _fingerprint(tmp_path, BASELINE_LINES)
    drifted = list(BASELINE_LINES)
    drifted.append(_loop({
        "type": "content.part", "uuid": "p2", "turnId": "2", "step": 1, "stepUuid": "s1",
        "part": {"type": "citation", "url": "https://example.invalid"},
    }))
    observed = agent_watch._kimi_wire_schema_fingerprint(
        _write(tmp_path, drifted, name="drifted.jsonl"), max_lines=5000
    )
    diff = _drift(observed, baseline)
    assert diff["unknown_types"] == ["part.citation"]
    assert diff["unknown_keys"]["part.citation"] == ["type", "url"]


def test_new_tool_result_key_surfaces_as_drift(tmp_path):
    """`isError` drives error classification; a replacement must not slip through."""
    baseline = _fingerprint(tmp_path, BASELINE_LINES)
    drifted = list(BASELINE_LINES)
    drifted.append(_loop({
        "type": "tool.result", "parentUuid": "Bash_1", "toolCallId": "Bash_1",
        "result": {"output": "boom", "errorKind": "timeout"},
    }))
    observed = agent_watch._kimi_wire_schema_fingerprint(
        _write(tmp_path, drifted, name="drifted.jsonl"), max_lines=5000
    )
    diff = _drift(observed, baseline)
    assert diff["unknown_keys"]["event.tool.result.result"] == ["errorKind"]


def test_streamed_assistant_text_surfaces_as_drift(tmp_path):
    """
    KimiSessionParser emits one .assistant event per text part. If Kimi ever streams
    partial parts, transcripts fragment and assistant counts inflate — same event.type,
    same keys, so only the per-step multiplicity gives it away.
    """
    baseline = _fingerprint(tmp_path, BASELINE_LINES)
    drifted = list(BASELINE_LINES)
    drifted.insert(4, _text_part(" How can I help", uuid="p1b"))
    drifted.insert(5, _text_part(" you today?", uuid="p1c"))
    observed = agent_watch._kimi_wire_schema_fingerprint(
        _write(tmp_path, drifted, name="drifted.jsonl"), max_lines=5000
    )
    diff = _drift(observed, baseline)
    assert diff["unknown_types"] == ["part.text.<multi-per-step>"]


def test_parts_of_different_types_in_one_step_are_not_drift(tmp_path):
    """A think part plus a text part in the same step is the normal shape."""
    fp = _fingerprint(tmp_path, BASELINE_LINES)
    assert not any(k.endswith("<multi-per-step>") for k in fp["type_keys"])


def test_same_part_type_across_different_steps_is_not_drift(tmp_path):
    lines = list(BASELINE_LINES)
    lines.append(_loop({"type": "step.begin", "uuid": "s2", "turnId": "2", "step": 2}))
    lines.append(_text_part("Second step reply.", uuid="p9", step=2, step_uuid="s2"))
    fp = _fingerprint(tmp_path, lines)
    assert not any(k.endswith("<multi-per-step>") for k in fp["type_keys"])


def test_nested_value_losing_its_object_shape_surfaces_as_drift(tmp_path):
    baseline = _fingerprint(tmp_path, BASELINE_LINES)
    drifted = list(BASELINE_LINES)
    drifted.append(_loop({
        "type": "tool.result", "parentUuid": "Bash_1", "toolCallId": "Bash_1",
        "result": "plain string output",
    }))
    observed = agent_watch._kimi_wire_schema_fingerprint(
        _write(tmp_path, drifted, name="drifted.jsonl"), max_lines=5000
    )
    diff = _drift(observed, baseline)
    assert diff["unknown_types"] == ["event.tool.result.result.<non-object>"]


def test_malformed_loop_event_is_counted_not_crashed(tmp_path):
    lines = [
        _loop({"type": "content.part", "uuid": "p0", "part": "not-an-object"}),
        {"type": "context.append_loop_event", "event": "not-an-object", "time": 1},
        _loop({"uuid": "p1", "part": {"text": "no types anywhere"}}),
    ]
    fp = _fingerprint(tmp_path, lines)
    assert fp["type_counts"]["event.content.part.part.<non-object>"] == 1
    assert fp["type_counts"]["event.<non-object>"] == 1
    assert fp["type_counts"]["event.<missing-type>"] == 1
    assert fp["type_counts"]["part.<missing-type>"] == 1
    assert fp["parse_errors"] == 0


def test_weekly_config_routes_kimi_through_the_nested_fingerprint():
    """
    `jsonl_newest` would still diff cleanly against a nested baseline — the nested
    buckets would land in `missing_types`, which does not raise severity — so a
    downgraded `kind` reads as "clean" while watching nothing. Pin it.
    """
    cfg = json.loads((REPO / agent_watch.DEFAULT_CONFIG).read_text(encoding="utf-8"))
    assert cfg["agents"]["kimi"]["weekly"]["local_schema"]["kind"] == "kimi_wire_newest"


def test_repo_fixture_baseline_covers_the_nested_vocabulary():
    """The kimi baseline is only useful if the shipped fixtures exercise loop events.

    Built from the *union* of the matrix's evidence fixtures, which is what
    `agent_watch.main()` feeds `_baseline_type_keys_for_agent`. No single capture
    carries the whole vocabulary: `small.jsonl` holds the interrupted-session
    families (`turn.cancel`, `turn.steer`, `permission.set_mode`) and
    `assistant_tools.jsonl` holds the model's own output. Asserting against one
    file alone would fail for a baseline that is in fact complete.
    """
    fixtures = _matrix_jsonl_fixtures()
    missing_files = [p for p in fixtures if not (REPO / p).exists()]
    assert not missing_files, f"matrix lists fixtures that do not exist: {missing_files}"
    baseline = agent_watch._baseline_type_keys_for_agent(
        "kimi", [str(REPO / p) for p in fixtures]
    )
    for bucket in (
        "event.step.begin", "event.step.end", "event.content.part",
        "event.tool.call", "event.tool.result", "event.tool.result.result",
        "part.text", "part.think",
    ):
        assert bucket in baseline, f"fixture no longer covers {bucket}"
    assert "isError" in baseline["event.tool.result.result"]
    # A fixture that already contained streamed parts would disable the signal.
    assert not any(k.endswith("<multi-per-step>") for k in baseline)


def _matrix_jsonl_fixtures(agent_key="kimi_code"):
    """kimi_code's evidence_fixtures, read the way agent_watch.main() reads them."""
    text = (REPO / "docs/agent-support/agent-support-matrix.yml").read_text(encoding="utf-8")
    out, current, in_evidence = [], None, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m_agent = re.match(r"^\s{2}([a-zA-Z0-9_]+):\s*$", line)
        if m_agent:
            current, in_evidence = m_agent.group(1), False
            continue
        if re.match(r"^\s{4}evidence_fixtures:\s*$", line):
            in_evidence = current == agent_key
            continue
        if in_evidence:
            m_item = re.match(r'^\s{6}-\s+"?(.*?)"?\s*$', line)
            if m_item:
                out.append(m_item.group(1))
            elif re.match(r"^\s{4}\w+:", line) or re.match(r"^\s{2}\w+:", line):
                in_evidence = False
    return [p for p in out if p.endswith(".jsonl")]


def test_baseline_covers_investigated_session_ops():
    """
    Regression guard for a silent baseline narrowing.

    `permission.set_mode` was flagged by the 2026-07-25 weekly scan, investigated,
    accepted as additive, and appended to the baseline. Replacing `small.jsonl` with
    the funded 0.31.1 capture then dropped it — along with `turn.cancel`,
    `turn.steer` and `llm.request.attempt` — re-arming an alert that was already
    resolved. Nothing failed at swap time; the weekly scan fingerprints only the
    newest journal, and that one happened to exercise none of them.

    These names are real, observed, and already adjudicated. Whatever fixture set
    carries them, the union must keep them.
    """
    fixtures = _matrix_jsonl_fixtures()
    missing_files = [p for p in fixtures if not (REPO / p).exists()]
    assert not missing_files, f"matrix lists fixtures that do not exist: {missing_files}"

    baseline = agent_watch._baseline_type_keys_for_agent(
        "kimi", [str(REPO / p) for p in fixtures]
    )
    for t in ("permission.set_mode", "turn.cancel", "turn.steer"):
        assert t in baseline, (
            f"{t} fell out of the kimi baseline; a previously investigated type will "
            "re-raise format_drift_detected. See docs/agent-json-tracking.md -> Kimi Code."
        )
    assert "attempt" in baseline.get("llm.request", []), (
        "llm.request.attempt fell out of the kimi baseline (it appears only on retries, "
        "so a capture without one is not evidence the key is gone)."
    )
