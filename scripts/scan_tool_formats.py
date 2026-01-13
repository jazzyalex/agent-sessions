#!/usr/bin/env python3
"""
Scan agent session logs to catalog tool input/output rendering formats.

Outputs:
- artifacts/tool_io_formats_catalog.json
- artifacts/tool_io_formats_report.md
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
ARTIFACTS_DIR = REPO_ROOT / "artifacts"

# Reuse existing JSONL reader when possible.
try:
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    from purge_no_prompt_sessions import _read_jsonl as read_jsonl  # type: ignore
except Exception:
    read_jsonl = None

DEFAULT_MAX_EXAMPLES_PER_GROUP = 3
DEFAULT_MAX_EXAMPLES_PER_SHAPE = 3
DEFAULT_MAX_FILES_PER_AGENT = 200
MAX_TEXT_EVENT_LEN = 2000
MAX_EXAMPLE_CHARS = 800


@dataclass
class Example:
    agent_family: str
    source_file: str
    event_index: Optional[int]
    direction: str
    tool_name: Optional[str]
    shape_signature: str
    field_path: Optional[str]
    raw_event: str
    raw_payload: Optional[str]
    parsed_payload: Optional[Any]
    parse_error: Optional[str]


@dataclass
class GroupStats:
    agent_family: str
    tool_name_normalized: str
    shape_signature: str
    direction: str
    count: int = 0
    parse_success: int = 0
    tool_name_variants: set[str] = field(default_factory=set)
    fields_seen: set[str] = field(default_factory=set)
    field_variants: Dict[str, set[str]] = field(default_factory=dict)
    examples: List[Example] = field(default_factory=list)


@dataclass
class ShapeStats:
    shape_signature: str
    count: int = 0
    agents: set[str] = field(default_factory=set)
    directions: Dict[str, int] = field(default_factory=dict)
    examples: List[Example] = field(default_factory=list)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def json_safe(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (list, dict)):
        return value
    return str(value)


def normalize_token(value: str) -> str:
    s = value.strip()
    if not s:
        return ""
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    s = s.replace("-", "_").replace(" ", "_").replace(".", "_").replace("/", "_")
    s = s.lower()
    s = re.sub(r"[^a-z0-9_]+", "", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s


def normalize_tool_name(name: Optional[str]) -> str:
    if not name:
        return "unknown"
    norm = normalize_token(name)
    return norm or "unknown"


def normalize_field_name(name: str) -> str:
    norm = normalize_token(name)
    return norm or name.strip().lower()


def parse_payload(payload: Any) -> Tuple[Optional[str], Optional[Any], Optional[str], List[str]]:
    raw_payload: Optional[str] = None
    parsed_payload: Optional[Any] = None
    parse_error: Optional[str] = None
    fields: List[str] = []

    if payload is None:
        return None, None, None, []

    if isinstance(payload, (dict, list)):
        raw_payload = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        parsed_payload = payload
        if isinstance(payload, dict):
            fields = list(payload.keys())
        return raw_payload, parsed_payload, None, fields

    if isinstance(payload, str):
        raw_payload = payload
        candidate = payload.strip()
        if candidate.startswith("{") or candidate.startswith("["):
            try:
                parsed_payload = json.loads(candidate)
                if isinstance(parsed_payload, dict):
                    fields = list(parsed_payload.keys())
            except Exception as exc:
                parse_error = f"json_decode_error: {exc}"
        return raw_payload, parsed_payload, parse_error, fields

    raw_payload = str(payload)
    return raw_payload, None, None, []


def infer_direction_from_payload(parsed_payload: Any) -> str:
    if not isinstance(parsed_payload, dict):
        return "unknown"
    keys = {normalize_field_name(k) for k in parsed_payload.keys()}
    output_keys = {
        "stdout",
        "stderr",
        "output",
        "result",
        "exitcode",
        "exit_code",
        "exit",
        "exitstatus",
        "is_error",
        "error",
    }
    input_keys = {
        "command",
        "commands",
        "args",
        "arguments",
        "input",
        "parameters",
        "query",
        "path",
        "paths",
        "cwd",
        "directory",
    }
    if keys & output_keys:
        return "output"
    if keys & input_keys:
        return "input"
    return "unknown"


def extract_balanced_braces(text: str, start: int) -> Optional[str]:
    in_string = False
    escape = False
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return None


def split_json_array_items(text: str, start_index: int) -> List[str]:
    items: List[str] = []
    in_string = False
    escape = False
    depth = 0
    item_start: Optional[int] = None

    for i in range(start_index, len(text)):
        ch = text[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == "[":
            depth += 1
            if depth == 1:
                continue
        if ch == "]":
            if depth == 1 and item_start is not None:
                items.append(text[item_start:i].strip())
                return items
            depth -= 1
        if depth == 1:
            if ch == ",":
                if item_start is not None:
                    items.append(text[item_start:i].strip())
                    item_start = None
            elif not ch.isspace():
                if item_start is None:
                    item_start = i
        elif depth > 1:
            continue
    return items


def extract_raw_items_from_json(text: str) -> List[str]:
    stripped = text.lstrip()
    if stripped.startswith("["):
        start = text.find("[")
        if start >= 0:
            return split_json_array_items(text, start)
        return []
    for key in ["messages", "history", "items"]:
        pattern = re.compile(r'"' + re.escape(key) + r'"\s*:\s*\[', re.MULTILINE)
        match = pattern.search(text)
        if not match:
            continue
        start = text.find("[", match.end() - 1)
        if start >= 0:
            return split_json_array_items(text, start)
    return []


def iter_jsonl_with_raw(path: Path) -> Iterable[Tuple[int, Dict[str, Any], str]]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for idx, line in enumerate(handle):
                raw = line.rstrip("\n")
                if not raw.strip():
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    yield idx, obj, raw
    except OSError:
        return


def iter_json_items_with_raw(path: Path) -> Iterable[Tuple[int, Dict[str, Any], str]]:
    try:
        raw_text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    raw_items = extract_raw_items_from_json(raw_text)
    for idx, raw in enumerate(raw_items):
        if not raw.strip():
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if isinstance(obj, dict):
            yield idx, obj, raw


def text_candidates(obj: Dict[str, Any]) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []

    def add(path: str, value: Any) -> None:
        if isinstance(value, str) and value.strip():
            out.append((path, value))

    add("text", obj.get("text"))
    add("content", obj.get("content"))
    add("message", obj.get("message"))
    add("finalText", obj.get("finalText"))

    msg = obj.get("message")
    if isinstance(msg, dict):
        add("message.content", msg.get("content"))
        content = msg.get("content")
        if isinstance(content, list):
            for i, item in enumerate(content):
                if isinstance(item, dict):
                    add(f"message.content[{i}].text", item.get("text"))
                    add(f"message.content[{i}].content", item.get("content"))

    data = obj.get("data")
    if isinstance(data, dict):
        add("data.content", data.get("content"))
        add("data.transformedContent", data.get("transformedContent"))

    content = obj.get("content")
    if isinstance(content, list):
        for i, item in enumerate(content):
            if isinstance(item, dict):
                add(f"content[{i}].text", item.get("text"))
                add(f"content[{i}].content", item.get("content"))

    return out


def extract_text_tool_blocks(text: str, full_path: str) -> List[Tuple[str, str, str]]:
    results: List[Tuple[str, str, str]] = []
    if not text.strip():
        return results
    lines = text.splitlines()
    if not lines:
        return results

    # Build line offsets to recover exact substrings.
    offsets: List[int] = []
    pos = 0
    for line in lines:
        offsets.append(pos)
        pos += len(line) + 1

    def looks_like_tool_name(s: str) -> Optional[str]:
        raw = s.strip().strip("<>").strip()
        if not raw:
            return None
        if re.match(r"^[A-Za-z][A-Za-z0-9_./-]{1,80}$", raw):
            return raw
        return None

    seen: set[Tuple[str, str]] = set()

    for idx, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue

        brace_index = stripped.find("{")
        if brace_index > 0:
            prefix = stripped[:brace_index].strip().strip(":")
            tool_name = looks_like_tool_name(prefix.split()[0]) if prefix else None
            if tool_name:
                line_start = offsets[idx]
                full_index = line_start + line.find("{")
                raw_json = extract_balanced_braces(text, full_index)
                if raw_json:
                    shape = "text:line-prefix+json"
                    if "\n" in raw_json:
                        shape = "text:line-prefix+json_block"
                    key = (tool_name, raw_json)
                    if key not in seen:
                        seen.add(key)
                        results.append((tool_name, raw_json, shape))
            continue

        tool_name = looks_like_tool_name(stripped)
        if tool_name and idx + 1 < len(lines):
            # Look ahead for a JSON block starting on the next non-empty line.
            for j in range(idx + 1, len(lines)):
                if not lines[j].strip():
                    continue
                if "{" not in lines[j]:
                    break
                line_start = offsets[j]
                full_index = line_start + lines[j].find("{")
                raw_json = extract_balanced_braces(text, full_index)
                if raw_json:
                    shape = "text:line+json_block"
                    key = (tool_name, raw_json)
                    if key not in seen:
                        seen.add(key)
                        results.append((tool_name, raw_json, shape))
                break

    return results


def example_is_too_large(example: Example) -> bool:
    if len(example.raw_event) > MAX_EXAMPLE_CHARS:
        return True
    if example.raw_payload is not None and len(example.raw_payload) > MAX_EXAMPLE_CHARS:
        return True
    return False


def add_group_example(group: GroupStats, example: Example, max_examples: int) -> None:
    if len(group.examples) >= max_examples:
        return
    if example_is_too_large(example):
        return
    group.examples.append(example)


def add_shape_example(shape: ShapeStats, example: Example, max_examples: int) -> None:
    if len(shape.examples) >= max_examples:
        return
    if example_is_too_large(example):
        return
    shape.examples.append(example)


def record_fields(group: GroupStats, fields: Iterable[str]) -> None:
    for field_name in fields:
        if not field_name:
            continue
        norm = normalize_field_name(field_name)
        group.fields_seen.add(norm)
        group.field_variants.setdefault(norm, set()).add(field_name)


def add_tool_block(
    groups: Dict[Tuple[str, str, str, str], GroupStats],
    shapes: Dict[str, ShapeStats],
    agent: str,
    tool_name: Optional[str],
    direction: str,
    shape_signature: str,
    raw_event: str,
    raw_payload: Optional[str],
    parsed_payload: Optional[Any],
    parse_error: Optional[str],
    field_path: Optional[str],
    fields: Iterable[str],
    source_file: str,
    event_index: Optional[int],
    max_examples_per_group: int,
    max_examples_per_shape: int,
) -> None:
    tool_norm = normalize_tool_name(tool_name)
    key = (agent, tool_norm, shape_signature, direction)

    group = groups.get(key)
    if group is None:
        group = GroupStats(
            agent_family=agent,
            tool_name_normalized=tool_norm,
            shape_signature=shape_signature,
            direction=direction,
        )
        groups[key] = group

    group.count += 1
    if parsed_payload is not None:
        group.parse_success += 1
    if tool_name:
        group.tool_name_variants.add(tool_name)
    record_fields(group, fields)

    example = Example(
        agent_family=agent,
        source_file=source_file,
        event_index=event_index,
        direction=direction,
        tool_name=tool_name,
        shape_signature=shape_signature,
        field_path=field_path,
        raw_event=raw_event,
        raw_payload=raw_payload,
        parsed_payload=parsed_payload,
        parse_error=parse_error,
    )
    add_group_example(group, example, max_examples_per_group)

    shape = shapes.get(shape_signature)
    if shape is None:
        shape = ShapeStats(shape_signature=shape_signature)
        shapes[shape_signature] = shape
    shape.count += 1
    shape.agents.add(agent)
    shape.directions[direction] = shape.directions.get(direction, 0) + 1
    add_shape_example(shape, example, max_examples_per_shape)


def codex_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None
    working = payload if isinstance(payload, dict) else obj
    event_type = None
    if isinstance(working, dict):
        event_type = working.get("type") or working.get("event")
    if event_type is None and isinstance(obj.get("type"), str):
        event_type = obj.get("type")

    if not isinstance(working, dict):
        return blocks

    event_type_l = str(event_type).lower() if event_type else ""
    if event_type_l in {"tool_call", "function_call"}:
        tool_name = working.get("name") or working.get("tool")
        fn = working.get("function")
        if isinstance(fn, dict) and not tool_name:
            tool_name = fn.get("name")
        tool_input = working.get("arguments") or working.get("input") or working.get("parameters")
        fields = list(working.keys())
        shape = "jsonl:type=tool_call"
        if obj.get("type") == "response_item" and isinstance(payload, dict):
            shape = "jsonl:response_item:payload.type=tool_call"
        if event_type_l == "function_call":
            shape = "jsonl:type=function_call"
        blocks.append(("input", tool_name, tool_input, shape, fields, "payload.type" if payload else "type"))

    if event_type_l in {"tool_result", "function_result"}:
        tool_name = working.get("name") or working.get("tool")
        fn = working.get("function")
        if isinstance(fn, dict) and not tool_name:
            tool_name = fn.get("name")
        tool_output = (
            working.get("result")
            if "result" in working
            else working.get("output") or working.get("stdout") or working.get("stderr")
        )
        fields = list(working.keys())
        shape = "jsonl:type=tool_result"
        if obj.get("type") == "response_item" and isinstance(payload, dict):
            shape = "jsonl:response_item:payload.type=tool_result"
        if event_type_l == "function_result":
            shape = "jsonl:type=function_result"
        blocks.append(("output", tool_name, tool_output, shape, fields, "payload.type" if payload else "type"))

    return blocks


def claude_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    msg = obj.get("message")
    if isinstance(msg, dict):
        content = msg.get("content")
        if isinstance(content, list):
            for item in content:
                if not isinstance(item, dict):
                    continue
                t = (item.get("type") or "").lower()
                if t in {"tool_use", "tool_call"}:
                    tool_name = item.get("name") or item.get("tool")
                    tool_input = item.get("input")
                    shape = "jsonl:message.content[].type=tool_use"
                    blocks.append(("input", tool_name, tool_input, shape, list(item.keys()), "message.content[]"))
                elif t == "tool_result":
                    tool_output = item.get("content")
                    shape = "jsonl:message.content[].type=tool_result"
                    blocks.append(("output", None, tool_output, shape, list(item.keys()), "message.content[]"))

    tool_use_result = obj.get("toolUseResult")
    if isinstance(tool_use_result, dict):
        shape = "jsonl:toolUseResult"
        blocks.append(("output", None, tool_use_result, shape, list(tool_use_result.keys()), "toolUseResult"))

    return blocks


def copilot_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    event_type = obj.get("type")
    data = obj.get("data")
    if event_type == "assistant.message" and isinstance(data, dict):
        reqs = data.get("toolRequests")
        if isinstance(reqs, list):
            for item in reqs:
                if not isinstance(item, dict):
                    continue
                tool_name = item.get("name")
                tool_input = item.get("arguments")
                shape = "jsonl:data.toolRequests[]"
                blocks.append(("input", tool_name, tool_input, shape, list(item.keys()), "data.toolRequests[]"))
    if event_type == "tool.execution_complete" and isinstance(data, dict):
        tool_name = data.get("toolName") or data.get("name")
        tool_output = data.get("result") or data.get("output")
        shape = "jsonl:type=tool.execution_complete"
        blocks.append(("output", tool_name, tool_output, shape, list(data.keys()), "data"))
    return blocks


def droid_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    t = (obj.get("type") or "").lower()
    if t == "tool_call":
        tool_name = obj.get("toolName") or obj.get("tool")
        tool_input = obj.get("parameters") or obj.get("input")
        shape = "jsonl:type=tool_call"
        blocks.append(("input", tool_name, tool_input, shape, list(obj.keys()), "type"))
    if t == "tool_result":
        tool_name = obj.get("toolName") or obj.get("tool")
        tool_output = obj.get("value") or obj.get("result") or obj.get("output")
        shape = "jsonl:type=tool_result"
        blocks.append(("output", tool_name, tool_output, shape, list(obj.keys()), "type"))

    msg = obj.get("message")
    if isinstance(msg, dict):
        content = msg.get("content")
        if isinstance(content, list):
            for item in content:
                if not isinstance(item, dict):
                    continue
                item_type = (item.get("type") or "").lower()
                if item_type in {"tool_use", "tool_call"}:
                    tool_name = item.get("name") or item.get("tool")
                    tool_input = item.get("input")
                    shape = "jsonl:message.content[].type=tool_use"
                    blocks.append(("input", tool_name, tool_input, shape, list(item.keys()), "message.content[]"))
                elif item_type == "tool_result":
                    tool_output = item.get("content")
                    shape = "jsonl:message.content[].type=tool_result"
                    blocks.append(("output", None, tool_output, shape, list(item.keys()), "message.content[]"))
    return blocks


def opencode_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    if (obj.get("type") or "").lower() != "tool":
        return blocks
    tool_name = obj.get("tool")
    state = obj.get("state") if isinstance(obj.get("state"), dict) else {}
    tool_input = state.get("input")
    tool_output = state.get("output") or state.get("stdout")
    if state.get("error") or state.get("stderr"):
        tool_output = {"output": tool_output, "error": state.get("error") or state.get("stderr")}
    shape = "json:part.type=tool"
    blocks.append(("input", tool_name, tool_input, shape, list(obj.keys()), "state.input"))
    if tool_output is not None:
        blocks.append(("output", tool_name, tool_output, shape, list(obj.keys()), "state.output"))
    return blocks


def gemini_extract_tool_output(tc: Dict[str, Any]) -> Optional[Any]:
    if tc.get("output") is not None:
        return tc.get("output")
    if tc.get("resultDisplay") is not None:
        return tc.get("resultDisplay")
    result = tc.get("result")
    if isinstance(result, list):
        for item in result:
            if isinstance(item, dict):
                if "functionResponse" in item and isinstance(item["functionResponse"], dict):
                    resp = item["functionResponse"].get("response")
                    if isinstance(resp, dict):
                        for key in ["output", "stdout", "text", "content"]:
                            if key in resp:
                                return resp[key]
                if "output" in item:
                    return item["output"]
                if "stdout" in item:
                    return item["stdout"]
    return None


def gemini_tool_blocks(obj: Dict[str, Any], raw_event: str) -> List[Tuple[str, str, Any, str, List[str], Optional[str]]]:
    blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
    t = (obj.get("type") or obj.get("role") or "").lower()
    if t in {"tool_use", "tool_call"}:
        tool_name = obj.get("name") or obj.get("tool")
        tool_input = obj.get("input")
        shape = "json:type=tool_call"
        blocks.append(("input", tool_name, tool_input, shape, list(obj.keys()), "type"))
    if t in {"tool_result", "tool"}:
        tool_output = obj.get("output")
        shape = "json:type=tool_result"
        blocks.append(("output", None, tool_output, shape, list(obj.keys()), "type"))

    tool_calls = obj.get("toolCalls") or obj.get("tool_calls")
    if isinstance(tool_calls, list):
        for tc in tool_calls:
            if not isinstance(tc, dict):
                continue
            tool_name = tc.get("displayName") or tc.get("name") or tc.get("tool")
            tool_input = tc.get("args") or tc.get("input")
            shape = "json:toolCalls[]" if "toolCalls" in obj else "json:tool_calls[]"
            blocks.append(("input", tool_name, tool_input, shape, list(tc.keys()), "toolCalls[]"))
            output = gemini_extract_tool_output(tc)
            if output is not None:
                blocks.append(("output", tool_name, output, shape, list(tc.keys()), "toolCalls[]"))
    return blocks


def discover_codex_sessions() -> List[Path]:
    if os.getenv("CODEX_HOME"):
        root = Path(os.getenv("CODEX_HOME", "")).expanduser() / "sessions"
    else:
        root = Path.home() / ".codex" / "sessions"
    if not root.exists():
        return []
    return [p for p in root.rglob("*.jsonl") if p.name.startswith("rollout-")]


def discover_claude_sessions() -> List[Path]:
    root = Path.home() / ".claude"
    if not root.exists():
        return []
    projects = root / "projects"
    scan_root = projects if projects.exists() else root
    out: List[Path] = []
    for ext in ("*.jsonl", "*.ndjson"):
        out.extend(scan_root.rglob(ext))
    return out


def discover_copilot_sessions() -> List[Path]:
    root = Path.home() / ".copilot" / "session-state"
    if not root.exists():
        return []
    return [p for p in root.glob("*.jsonl")]


def discover_gemini_sessions() -> List[Path]:
    root = Path.home() / ".gemini" / "tmp"
    if not root.exists():
        return []
    out: List[Path] = []
    for project in root.iterdir():
        if not project.is_dir():
            continue
        name = project.name
        if not (32 <= len(name) <= 64 and all(c in "0123456789abcdef" for c in name.lower())):
            continue
        chats = project / "chats"
        if chats.exists():
            out.extend([p for p in chats.glob("session-*.json")])
        out.extend([p for p in project.glob("session-*.json")])
    return out


def discover_opencode_sessions() -> List[Path]:
    root = Path.home() / ".local" / "share" / "opencode" / "storage" / "session"
    if not root.exists():
        return []
    return [p for p in root.rglob("ses_*.json")]


def droid_looks_like_stream_json(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            recognized = 0
            saw_session = False
            saw_primary = False
            for idx, line in enumerate(handle):
                if idx >= 50:
                    break
                raw = line.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                t = str(obj.get("type", "")).lower()
                if t in {"system", "message", "tool_call", "tool_result", "completion"}:
                    recognized += 1
                if obj.get("session_id") or obj.get("sessionId"):
                    saw_session = True
                if t == "message" and obj.get("role") and obj.get("text"):
                    saw_primary = True
                if t == "tool_call" and obj.get("toolName"):
                    saw_primary = True
            return recognized >= 3 and saw_session and saw_primary
    except OSError:
        return False


def discover_droid_sessions() -> List[Path]:
    out: List[Path] = []
    sessions_root = Path.home() / ".factory" / "sessions"
    if sessions_root.exists():
        out.extend(sessions_root.rglob("*.jsonl"))
    projects_root = Path.home() / ".factory" / "projects"
    if projects_root.exists():
        for path in projects_root.rglob("*.jsonl"):
            if droid_looks_like_stream_json(path):
                out.append(path)
    return out


def limit_by_mtime(paths: List[Path], max_files: int) -> List[Path]:
    if max_files <= 0 or len(paths) <= max_files:
        return paths
    with_mtime: List[Tuple[float, Path]] = []
    for path in paths:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = 0.0
        with_mtime.append((mtime, path))
    with_mtime.sort(key=lambda item: item[0], reverse=True)
    return [p for _, p in with_mtime[:max_files]]


def discover_fixture_sessions(fixtures_root: Path) -> Dict[str, List[Path]]:
    out: Dict[str, List[Path]] = {}
    if not fixtures_root.exists():
        return out
    for path in fixtures_root.rglob("*"):
        if path.suffix.lower() not in {".jsonl", ".ndjson"}:
            continue
        parts = list(path.parts)
        agent = "codex"
        if "stage0" in parts:
            try:
                idx = parts.index("agents")
                agent = parts[idx + 1]
            except Exception:
                agent = "codex"
        elif "claude" in path.name:
            agent = "claude"
        elif "copilot" in path.name:
            agent = "copilot"
        elif "droid" in path.name:
            agent = "droid"
        out.setdefault(agent, []).append(path)
    return out


def scan_jsonl_file(
    agent: str,
    path: Path,
    groups: Dict[Tuple[str, str, str, str], GroupStats],
    shapes: Dict[str, ShapeStats],
    max_examples_per_group: int,
    max_examples_per_shape: int,
) -> None:
    for idx, obj, raw in iter_jsonl_with_raw(path):
        blocks: List[Tuple[str, str, Any, str, List[str], Optional[str]]] = []
        if agent == "codex":
            blocks = codex_tool_blocks(obj, raw)
        elif agent == "claude":
            blocks = claude_tool_blocks(obj, raw)
        elif agent == "copilot":
            blocks = copilot_tool_blocks(obj, raw)
        elif agent == "droid":
            blocks = droid_tool_blocks(obj, raw)

        for direction, tool_name, payload, shape, fields, field_path in blocks:
            raw_payload, parsed_payload, parse_error, payload_fields = parse_payload(payload)
            use_fields = fields or payload_fields
            add_tool_block(
                groups=groups,
                shapes=shapes,
                agent=agent,
                tool_name=tool_name,
                direction=direction,
                shape_signature=shape,
                raw_event=raw,
                raw_payload=raw_payload,
                parsed_payload=parsed_payload,
                parse_error=parse_error,
                field_path=field_path,
                fields=use_fields,
                source_file=str(path),
                event_index=idx,
                max_examples_per_group=max_examples_per_group,
                max_examples_per_shape=max_examples_per_shape,
            )

        # Text-based tool patterns inside message text.
        for field_path, text in text_candidates(obj):
            if len(text) > MAX_TEXT_EVENT_LEN:
                continue
            for tool_name, raw_json, shape in extract_text_tool_blocks(text, field_path):
                raw_payload, parsed_payload, parse_error, payload_fields = parse_payload(raw_json)
                direction = infer_direction_from_payload(parsed_payload)
                add_tool_block(
                    groups=groups,
                    shapes=shapes,
                    agent=agent,
                    tool_name=tool_name,
                    direction=direction,
                    shape_signature=shape,
                    raw_event=text,
                    raw_payload=raw_payload,
                    parsed_payload=parsed_payload,
                    parse_error=parse_error,
                    field_path=field_path,
                    fields=payload_fields,
                    source_file=str(path),
                    event_index=idx,
                    max_examples_per_group=max_examples_per_group,
                    max_examples_per_shape=max_examples_per_shape,
                )


def scan_json_file(
    agent: str,
    path: Path,
    groups: Dict[Tuple[str, str, str, str], GroupStats],
    shapes: Dict[str, ShapeStats],
    max_examples_per_group: int,
    max_examples_per_shape: int,
) -> None:
    if agent == "gemini":
        for idx, obj, raw in iter_json_items_with_raw(path):
            blocks = gemini_tool_blocks(obj, raw)
            for direction, tool_name, payload, shape, fields, field_path in blocks:
                raw_payload, parsed_payload, parse_error, payload_fields = parse_payload(payload)
                use_fields = fields or payload_fields
                add_tool_block(
                    groups=groups,
                    shapes=shapes,
                    agent=agent,
                    tool_name=tool_name,
                    direction=direction,
                    shape_signature=shape,
                    raw_event=raw,
                    raw_payload=raw_payload,
                    parsed_payload=parsed_payload,
                    parse_error=parse_error,
                    field_path=field_path,
                    fields=use_fields,
                    source_file=str(path),
                    event_index=idx,
                    max_examples_per_group=max_examples_per_group,
                    max_examples_per_shape=max_examples_per_shape,
                )
            for field_path, text in text_candidates(obj):
                if len(text) > MAX_TEXT_EVENT_LEN:
                    continue
                for tool_name, raw_json, shape in extract_text_tool_blocks(text, field_path):
                    raw_payload, parsed_payload, parse_error, payload_fields = parse_payload(raw_json)
                    direction = infer_direction_from_payload(parsed_payload)
                    add_tool_block(
                        groups=groups,
                        shapes=shapes,
                        agent=agent,
                        tool_name=tool_name,
                        direction=direction,
                        shape_signature=shape,
                        raw_event=text,
                        raw_payload=raw_payload,
                        parsed_payload=parsed_payload,
                        parse_error=parse_error,
                        field_path=field_path,
                        fields=payload_fields,
                        source_file=str(path),
                        event_index=idx,
                        max_examples_per_group=max_examples_per_group,
                        max_examples_per_shape=max_examples_per_shape,
                    )
        return

    # OpenCode part files contain single JSON objects.
    if agent == "opencode_part":
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return
        try:
            obj = json.loads(raw)
        except Exception:
            return
        if not isinstance(obj, dict):
            return
        blocks = opencode_tool_blocks(obj, raw)
        for direction, tool_name, payload, shape, fields, field_path in blocks:
            raw_payload, parsed_payload, parse_error, payload_fields = parse_payload(payload)
            use_fields = fields or payload_fields
            add_tool_block(
                groups=groups,
                shapes=shapes,
                agent="opencode",
                tool_name=tool_name,
                direction=direction,
                shape_signature=shape,
                raw_event=raw,
                raw_payload=raw_payload,
                parsed_payload=parsed_payload,
                parse_error=parse_error,
                field_path=field_path,
                fields=use_fields,
                source_file=str(path),
                event_index=None,
                max_examples_per_group=max_examples_per_group,
                max_examples_per_shape=max_examples_per_shape,
            )


def discover_opencode_part_files(session_paths: List[Path]) -> List[Path]:
    parts: List[Path] = []
    seen: set[str] = set()
    for session_path in session_paths:
        try:
            project_dir = session_path.parent
            session_root = project_dir.parent
            storage_root = session_root.parent
            part_root = storage_root / "part"
        except Exception:
            continue
        if not part_root.exists():
            continue
        for part_file in part_root.rglob("*.json"):
            key = str(part_file)
            if key in seen:
                continue
            seen.add(key)
            parts.append(part_file)
    return parts


def build_catalog(
    groups: Dict[Tuple[str, str, str, str], GroupStats],
    shapes: Dict[str, ShapeStats],
    scan_roots: Dict[str, List[str]],
    files_scanned: Dict[str, int],
) -> Dict[str, Any]:
    groups_out: List[Dict[str, Any]] = []
    for group in groups.values():
        parse_rate = group.parse_success / group.count if group.count else 0.0
        groups_out.append(
            {
                "agent_family": group.agent_family,
                "tool_name_normalized": group.tool_name_normalized,
                "tool_name_variants": sorted(group.tool_name_variants),
                "shape_signature": group.shape_signature,
                "direction": group.direction,
                "count": group.count,
                "fields_seen": sorted(group.fields_seen),
                "field_variants": {
                    k: sorted(v) for k, v in sorted(group.field_variants.items(), key=lambda x: x[0])
                },
                "parse_success_rate": round(parse_rate, 4),
                "examples": [
                    {
                        "agent_family": ex.agent_family,
                        "source_file": ex.source_file,
                        "event_index": ex.event_index,
                        "direction": ex.direction,
                        "tool_name": ex.tool_name,
                        "shape_signature": ex.shape_signature,
                        "field_path": ex.field_path,
                        "raw_event": ex.raw_event,
                        "raw_payload": ex.raw_payload,
                        "parsed_payload": json_safe(ex.parsed_payload),
                        "parse_error": ex.parse_error,
                    }
                    for ex in group.examples
                ],
            }
        )

    shapes_out: List[Dict[str, Any]] = []
    for shape in shapes.values():
        shapes_out.append(
            {
                "shape_signature": shape.shape_signature,
                "count": shape.count,
                "agent_families": sorted(shape.agents),
                "direction_counts": dict(sorted(shape.directions.items())),
                "examples": [
                    {
                        "agent_family": ex.agent_family,
                        "source_file": ex.source_file,
                        "event_index": ex.event_index,
                        "direction": ex.direction,
                        "tool_name": ex.tool_name,
                        "shape_signature": ex.shape_signature,
                        "field_path": ex.field_path,
                        "raw_event": ex.raw_event,
                        "raw_payload": ex.raw_payload,
                        "parsed_payload": json_safe(ex.parsed_payload),
                        "parse_error": ex.parse_error,
                    }
                    for ex in shape.examples
                ],
            }
        )

    summary = {
        "total_tool_blocks": sum(g.count for g in groups.values()),
        "agent_counts": {
            agent: sum(g.count for g in groups.values() if g.agent_family == agent)
            for agent in sorted({g.agent_family for g in groups.values()})
        },
        "direction_counts": {
            direction: sum(g.count for g in groups.values() if g.direction == direction)
            for direction in sorted({g.direction for g in groups.values()})
        },
        "shape_counts": {shape.shape_signature: shape.count for shape in shapes.values()},
    }

    return {
        "generated_at": now_iso(),
        "scan_roots": scan_roots,
        "files_scanned": files_scanned,
        "summary": summary,
        "groups": sorted(
            groups_out,
            key=lambda g: (g["agent_family"], g["shape_signature"], g["tool_name_normalized"], g["direction"]),
        ),
        "shape_signatures": sorted(shapes_out, key=lambda s: s["shape_signature"]),
    }


def render_json(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def render_report(
    catalog: Dict[str, Any],
    shapes: Dict[str, ShapeStats],
    scan_roots: Dict[str, List[str]],
    files_scanned: Dict[str, int],
) -> str:
    lines: List[str] = []
    lines.append("# Tool IO Formats Report")
    lines.append(f"Generated: {catalog.get('generated_at')}")
    lines.append("")
    lines.append("## Scan Summary")
    for agent, roots in sorted(scan_roots.items()):
        count = files_scanned.get(agent, 0)
        if not roots:
            root_text = "(none)"
        else:
            preview = ", ".join(roots[:3])
            suffix = "" if len(roots) <= 3 else f", ... (+{len(roots) - 3} more)"
            root_text = f"{preview}{suffix}"
        lines.append(f"- {agent}: {count} files from {root_text}")
    lines.append("")

    lines.append("## Shape Summary")
    lines.append("| Shape Signature | Count | Agents | Directions |")
    lines.append("| --- | --- | --- | --- |")
    for shape in sorted(shapes.values(), key=lambda s: s.shape_signature):
        agents = ", ".join(sorted(shape.agents))
        directions = ", ".join(f"{k}={v}" for k, v in sorted(shape.directions.items()))
        lines.append(f"| {shape.shape_signature} | {shape.count} | {agents} | {directions} |")
    lines.append("")

    for shape in sorted(shapes.values(), key=lambda s: s.shape_signature):
        lines.append(f"## Shape: {shape.shape_signature}")
        lines.append(f"- Count: {shape.count}")
        lines.append(f"- Agents: {', '.join(sorted(shape.agents))}")
        direction_line = ", ".join(f"{k}={v}" for k, v in sorted(shape.directions.items()))
        lines.append(f"- Directions: {direction_line}")
        lines.append("")
        lines.append("Examples:")
        for idx, ex in enumerate(shape.examples, start=1):
            lines.append(f"{idx}. Raw event:")
            info = "json" if ex.raw_event.strip().startswith("{") else "text"
            lines.append(f"```{info}")
            lines.append(ex.raw_event)
            lines.append("```")
            if ex.raw_payload is not None:
                lines.append("Raw payload:")
                payload_info = "json" if ex.raw_payload.strip().startswith("{") else "text"
                lines.append(f"```{payload_info}")
                lines.append(ex.raw_payload)
                lines.append("```")
            if ex.parsed_payload is not None:
                lines.append("Parsed payload:")
                lines.append("```json")
                lines.append(render_json(json_safe(ex.parsed_payload)).strip())
                lines.append("```")
            elif ex.parse_error:
                lines.append(f"Parsed payload: (unparsable) {ex.parse_error}")
            lines.append("")

    lines.append("## Proposed ToolEventNormalized Schema")
    lines.append("```json")
    lines.append(
        render_json(
            {
                "id": "string",
                "agent_family": "codex|claude|copilot|droid|opencode|gemini|other",
                "session_id": "string",
                "timestamp": "string|number|null",
                "direction": "input|output|unknown",
                "tool": {
                    "name": "string|null",
                    "name_normalized": "string",
                    "call_id": "string|null",
                },
                "io": {
                    "input": "object|string|null",
                    "output": "object|string|null",
                    "stdout": "string|null",
                    "stderr": "string|null",
                    "exit_code": "number|null",
                    "is_error": "bool|null",
                },
                "raw": {
                    "shape_signature": "string",
                    "field_path": "string|null",
                    "event": "string",
                    "payload": "string|null",
                },
                "source": {
                    "file_path": "string",
                    "event_index": "number|null",
                },
            }
        ).strip()
    )
    lines.append("```")
    lines.append("")

    lines.append("## UI Formatting Recommendations")
    lines.append("- Render tool calls/results as distinct blocks keyed by shape signature and direction.")
    lines.append("- When outputs include stdout/stderr or exit codes, show labeled sections and preserve line breaks.")
    lines.append("- For text-line tool call patterns, promote JSON payloads into structured UI chips with a fallback raw view.")
    lines.append("- Keep raw JSONL lines accessible via a disclosure toggle for schema-drift cases.")
    lines.append("- For OpenCode part-tool events, group call/result pairs by tool name and call id when available.")
    lines.append("- For Claude toolUseResult outputs, render stdout/stderr separately and surface is_error in badges.")
    lines.append("")

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Catalog tool input/output rendering formats.")
    ap.add_argument("--output-catalog", default=str(ARTIFACTS_DIR / "tool_io_formats_catalog.json"))
    ap.add_argument("--output-report", default=str(ARTIFACTS_DIR / "tool_io_formats_report.md"))
    ap.add_argument("--include-fixtures", action="store_true", default=True)
    ap.add_argument("--fixtures-only", action="store_true", default=False)
    ap.add_argument("--sanity-check", action="store_true", default=False)
    ap.add_argument("--max-files-per-agent", type=int, default=DEFAULT_MAX_FILES_PER_AGENT)
    ap.add_argument("--max-examples-per-group", type=int, default=DEFAULT_MAX_EXAMPLES_PER_GROUP)
    ap.add_argument("--max-examples-per-shape", type=int, default=DEFAULT_MAX_EXAMPLES_PER_SHAPE)
    args = ap.parse_args()

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    scan_roots: Dict[str, List[str]] = {}
    files_scanned: Dict[str, int] = {}
    groups: Dict[Tuple[str, str, str, str], GroupStats] = {}
    shapes: Dict[str, ShapeStats] = {}

    sources: Dict[str, List[Path]] = {}
    if not args.fixtures_only:
        sources["codex"] = discover_codex_sessions()
        sources["claude"] = discover_claude_sessions()
        sources["copilot"] = discover_copilot_sessions()
        sources["droid"] = discover_droid_sessions()
        sources["gemini"] = discover_gemini_sessions()
        sources["opencode"] = discover_opencode_sessions()

    if args.include_fixtures or args.fixtures_only:
        fixtures = discover_fixture_sessions(REPO_ROOT / "Resources" / "Fixtures")
        for agent, paths in fixtures.items():
            sources.setdefault(agent, []).extend(paths)

    for agent, paths in sources.items():
        if args.max_files_per_agent > 0:
            paths = limit_by_mtime(paths, args.max_files_per_agent)
            sources[agent] = paths
        scan_roots[agent] = sorted({str(p.parent) for p in paths})
        files_scanned[agent] = 0
        for path in paths:
            if path.suffix.lower() in {".jsonl", ".ndjson"}:
                files_scanned[agent] += 1
                scan_jsonl_file(
                    agent,
                    path,
                    groups,
                    shapes,
                    max_examples_per_group=args.max_examples_per_group,
                    max_examples_per_shape=args.max_examples_per_shape,
                )
            elif path.suffix.lower() == ".json":
                files_scanned[agent] += 1
                scan_json_file(
                    agent,
                    path,
                    groups,
                    shapes,
                    max_examples_per_group=args.max_examples_per_group,
                    max_examples_per_shape=args.max_examples_per_shape,
                )

    # OpenCode tool data lives in part files under storage/part.
    opencode_sessions = sources.get("opencode", [])
    opencode_parts = discover_opencode_part_files(opencode_sessions)
    if args.max_files_per_agent > 0:
        opencode_parts = limit_by_mtime(opencode_parts, args.max_files_per_agent)
    if opencode_parts:
        scan_roots.setdefault("opencode", [])
        scan_roots["opencode"].extend(sorted({str(p.parent) for p in opencode_parts}))
        files_scanned["opencode"] = files_scanned.get("opencode", 0) + len(opencode_parts)
        for part_path in opencode_parts:
            scan_json_file(
                "opencode_part",
                part_path,
                groups,
                shapes,
                max_examples_per_group=args.max_examples_per_group,
                max_examples_per_shape=args.max_examples_per_shape,
            )

    catalog = build_catalog(groups, shapes, scan_roots, files_scanned)
    Path(args.output_catalog).write_text(render_json(catalog), encoding="utf-8")

    report = render_report(catalog, shapes, scan_roots, files_scanned)
    Path(args.output_report).write_text(report + "\n", encoding="utf-8")

    if args.sanity_check:
        if catalog["summary"]["total_tool_blocks"] == 0:
            raise SystemExit("Sanity check failed: no tool blocks found.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
