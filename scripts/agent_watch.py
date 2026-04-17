#!/usr/bin/env python3
"""
Daily/weekly agent monitoring for upstream version drift and schema-risk detection.

Policy:
- Daily mode is quiet when there is nothing actionable.
- Weekly mode always emits a report (expected review).
- This tool never edits parsers or fixtures. It only writes reports and optional probe outputs.

Outputs:
- Writes JSON report under scripts/probe_scan_output/agent_watch/<UTC timestamp>/report.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = "docs/agent-support/agent-watch-config.json"
DEFAULT_TIMEOUT_SECONDS = 120


def _now_utc_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _expand_path(p: str) -> Path:
    # Expand env vars and ~
    expanded = os.path.expandvars(p)
    return Path(expanded).expanduser()


def _http_get_text(url: str, timeout: int) -> str:
    # Prefer curl to avoid Python SSL trust-store drift on some macOS setups.
    rc, out, err = _run_cmd(["curl", "-fsSL", url], timeout=timeout)
    if rc == 0 and out:
        return out
    # Fallback to urllib for environments without curl.
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "AgentSessions-AgentWatch/1.0",
            "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace")


def _http_get_json(url: str, timeout: int) -> Any:
    txt = _http_get_text(url, timeout=timeout)
    return json.loads(txt)


_SEMVER_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


@dataclass(frozen=True, order=True)
class Semver:
    major: int
    minor: int
    patch: int

    @staticmethod
    def parse(text: str) -> "Semver | None":
        m = _SEMVER_RE.search(text)
        if not m:
            return None
        return Semver(int(m.group(1)), int(m.group(2)), int(m.group(3)))

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


def _extract_semver(text: str) -> str | None:
    v = Semver.parse(text)
    return str(v) if v else None


def _run_cmd(argv: list[str], timeout: int) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=timeout,
        )
        return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()
    except FileNotFoundError:
        return 127, "", f"Command not found: {argv[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"Timed out after {timeout}s"


def _read_verified_versions_from_matrix(matrix_path: Path) -> dict[str, str]:
    """
    Minimal YAML reader for the specific support matrix shape.
    Avoids external dependencies (PyYAML).
    """
    text = matrix_path.read_text(encoding="utf-8", errors="replace").splitlines()

    # We only need: agents.<key>.max_verified_version
    in_agents = False
    current_agent: str | None = None
    versions: dict[str, str] = {}

    for raw in text:
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("agents:"):
            in_agents = True
            current_agent = None
            continue
        if not in_agents:
            continue

        # Top-level agent key (2-space indent): "  codex_cli:"
        m_agent = re.match(r"^\s{2}([a-zA-Z0-9_]+):\s*$", line)
        if m_agent:
            current_agent = m_agent.group(1)
            continue

        if current_agent is None:
            continue

        # Field line (4-space indent): "    max_verified_version: "0.73.0""
        m_ver = re.match(r'^\s{4}max_verified_version:\s*"?(.*?)"?\s*$', line)
        if m_ver:
            versions[current_agent] = m_ver.group(1).strip()

    return versions


def _keyword_hits(text: str, keywords: list[str]) -> list[str]:
    if not text:
        return []
    lower = text.lower()
    hits: list[str] = []
    for k in keywords:
        if k.lower() in lower:
            hits.append(k)
    return hits


def _resolve_cli_binary_mtime(installed_version_cmd: list[str] | None) -> tuple[str | None, float | None]:
    """Resolve the CLI binary on PATH and return (abs_path, mtime_epoch).

    Both elements are None if the command is empty, unresolvable, or the
    resolved path cannot be stat'd. Used by sample_freshness to decide if
    the newest local sample predates the installed binary.
    """
    if not isinstance(installed_version_cmd, list) or not installed_version_cmd:
        return None, None
    binary_name = installed_version_cmd[0]
    if not isinstance(binary_name, str) or not binary_name:
        return None, None
    resolved = shutil.which(binary_name)
    if not resolved:
        return None, None
    try:
        st = os.stat(resolved)
    except OSError:
        return resolved, None
    return resolved, float(st.st_mtime)


def _epoch_to_utc_iso(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def _compute_sample_freshness(
    *,
    sample_mtime: float | None,
    cli_binary_path: str | None,
    cli_binary_mtime: float | None,
    freshness_window_seconds: int,
    now_epoch: float,
    mode_context: str,
    force_fresh: bool,
) -> dict[str, Any]:
    """Build the sample_freshness evidence block per spec §3.1/§3.2."""
    block: dict[str, Any] = {
        "sample_mtime_utc": _epoch_to_utc_iso(sample_mtime),
        "cli_binary_mtime_utc": _epoch_to_utc_iso(cli_binary_mtime),
        "cli_binary_path": cli_binary_path,
        "freshness_window_seconds": int(freshness_window_seconds),
        "sample_older_than_cli": None,
        "sample_older_than_window": None,
        "is_stale": False,
        "stale_reason": None,
        "mode_context": mode_context,
    }

    if force_fresh:
        block["is_stale"] = False
        block["stale_reason"] = "forced_fresh"
        return block

    if sample_mtime is None:
        # No sample on disk — staleness is not meaningful; leave flags None.
        return block

    if cli_binary_mtime is not None:
        older_cli = sample_mtime < cli_binary_mtime
        block["sample_older_than_cli"] = bool(older_cli)
    else:
        block["sample_older_than_cli"] = None

    older_window = (now_epoch - sample_mtime) > freshness_window_seconds
    block["sample_older_than_window"] = bool(older_window)

    if block["sample_older_than_cli"] is True:
        block["is_stale"] = True
        block["stale_reason"] = "sample_older_than_cli"
    elif older_window:
        block["is_stale"] = True
        if cli_binary_path is None:
            block["stale_reason"] = "cli_binary_unresolved"
        else:
            block["stale_reason"] = "sample_older_than_window"
    else:
        if cli_binary_path is None:
            # Binary unresolved but window still fresh — record the cause so
            # downstream readers know signal 1 was unavailable.
            block["stale_reason"] = "cli_binary_unresolved"
            block["is_stale"] = False

    return block


def _pick_severity(
    *,
    upstream_newer_than_verified: bool,
    installed_newer_than_verified: bool,
    monitoring_failed: bool,
    schema_hits: list[str],
    usage_hits: list[str],
    probe_failed: bool,
    probe_failed_but_upstream_degraded: bool,
) -> tuple[str, str]:
    if monitoring_failed:
        return "high", "prepare_hotfix"
    if probe_failed and not probe_failed_but_upstream_degraded:
        return "high", "prepare_hotfix"
    if probe_failed and probe_failed_but_upstream_degraded:
        # Upstream issue: monitor rather than treat as an AS regression.
        return "medium", "monitor"
    if installed_newer_than_verified:
        return "medium", "run_weekly_now"
    if not upstream_newer_than_verified and not installed_newer_than_verified:
        return "none", "ignore"
    if schema_hits or usage_hits:
        return "medium", "run_weekly_now"
    return "low", "monitor"


def _compare_semver(a: str | None, b: str | None) -> int | None:
    """
    Returns -1/0/1 for a<b, a==b, a>b. None if either is not semver.
    """
    if not a or not b:
        return None
    va = Semver.parse(a)
    vb = Semver.parse(b)
    if not va or not vb:
        return None
    if va < vb:
        return -1
    if va > vb:
        return 1
    return 0


def _safe_relpath(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except Exception:
        return str(path)


def _path_matches_any_exclude(path: Path, exclude_globs: list[str] | None) -> bool:
    """Return True if *path* matches any of the provided fnmatch-style globs.

    Matching is performed against both the full POSIX path and against each
    individual path component so patterns like ``backup`` or ``**/backup/**``
    both work. This is used by the weekly local-schema selector to skip
    backup/reset snapshots that the Swift-side discovery does not surface.
    """
    if not exclude_globs:
        return False
    import fnmatch
    posix = path.as_posix()
    for pattern in exclude_globs:
        if not isinstance(pattern, str) or not pattern:
            continue
        if fnmatch.fnmatch(posix, pattern):
            return True
        for part in path.parts:
            if fnmatch.fnmatch(part, pattern):
                return True
    return False


def _newest_file(roots: list[str], glob: str, exclude_globs: list[str] | None = None) -> Path | None:
    candidates: list[Path] = []
    for r in roots:
        root = _expand_path(r)
        if not root.exists():
            continue
        candidates.extend(root.glob(glob) if "*" in glob and "/" not in glob else root.rglob(glob))
    newest: Path | None = None
    newest_mtime = -1.0
    for p in candidates:
        try:
            st = p.stat()
        except OSError:
            continue
        if not p.is_file():
            continue
        if _path_matches_any_exclude(p, exclude_globs):
            continue
        if st.st_mtime > newest_mtime:
            newest = p
            newest_mtime = st.st_mtime
    return newest


def _jsonl_contains_any_type(path: Path, required_types: set[str], max_lines: int) -> bool:
    try:
        lines_seen = 0
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                lines_seen += 1
                if lines_seen > max_lines:
                    break
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                t = obj.get("type")
                if isinstance(t, str) and t in required_types:
                    return True
    except OSError:
        return False
    return False


def _newest_file_with_types(
    roots: list[str],
    glob: str,
    required_types: list[str],
    max_lines: int,
    exclude_globs: list[str] | None = None,
) -> Path | None:
    candidates: list[Path] = []
    for r in roots:
        root = _expand_path(r)
        if not root.exists():
            continue
        candidates.extend(root.glob(glob) if "*" in glob and "/" not in glob else root.rglob(glob))
    candidates = [c for c in candidates if c.is_file() and not _path_matches_any_exclude(c, exclude_globs)]
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    wanted = {t for t in required_types if isinstance(t, str) and t}
    for p in candidates:
        if _jsonl_contains_any_type(p, wanted, max_lines=max_lines):
            return p
    return None


def _check_discovery_path_contract(local_file: str | None, contract_cfg: dict[str, Any]) -> dict[str, Any]:
    patterns_raw = contract_cfg.get("patterns")
    patterns = [p for p in (patterns_raw if isinstance(patterns_raw, list) else []) if isinstance(p, str) and p]
    if not patterns:
        return {"ok": False, "error": "missing_patterns"}

    description = contract_cfg.get("description")
    candidate = (local_file or "").replace("\\", "/")
    if not candidate:
        return {"ok": False, "error": "no_local_file", "patterns": patterns, "description": description}

    matched = next((pat for pat in patterns if re.search(pat, candidate)), None)
    return {
        "ok": bool(matched),
        "file": candidate,
        "matched_pattern": matched,
        "patterns": patterns,
        "description": description,
    }


def _jsonl_schema_fingerprint(path: Path, max_lines: int) -> dict[str, Any]:
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0
    total_lines: int = 0

    # Read tail-ish by keeping only last max_lines lines (simple but OK for monitoring).
    lines: list[str] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            lines.append(line)
            if len(lines) > max_lines:
                lines.pop(0)

    for raw in lines:
        total_lines += 1
        s = raw.strip()
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            parse_errors += 1
            continue
        if not isinstance(obj, dict):
            continue
        t = obj.get("type")
        event_type = t if isinstance(t, str) and t else "<missing-type>"
        type_counts[event_type] = type_counts.get(event_type, 0) + 1
        ks = type_keys.setdefault(event_type, set())
        for k in obj.keys():
            ks.add(k)

    return {
        "file": str(path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "parsed_lines": total_lines,
        "parse_errors": parse_errors,
    }


_ROLE_MAP = {
    "user": "user", "human": "user",
    "assistant": "assistant", "model": "assistant",
    "system": "system",
}


def _cursor_transcript_schema_fingerprint(path: Path, max_lines: int) -> dict[str, Any]:
    """
    Schema fingerprint for Cursor agent transcript JSONL files.

    Cursor transcripts use `role` (user/assistant) as the top-level discriminator
    instead of `type`. We bucket by normalized role AND by content block type
    (prefixed `content.<type>`) so _schema_diff() detects both structural and
    content-level drift.

    Role normalization matches CursorSessionParser.swift:187-193:
      user/human -> user, assistant/model -> assistant, system -> system, else -> assistant
    """
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0
    total_lines: int = 0

    lines: list[str] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            lines.append(line)
            if len(lines) > max_lines:
                lines.pop(0)

    for raw in lines:
        total_lines += 1
        s = raw.strip()
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            parse_errors += 1
            continue
        if not isinstance(obj, dict):
            continue

        # Bucket top-level keys by normalized role
        raw_role = obj.get("role")
        role_key = raw_role.lower() if isinstance(raw_role, str) else ""
        role = _ROLE_MAP.get(role_key, "assistant")
        type_counts[role] = type_counts.get(role, 0) + 1
        ks = type_keys.setdefault(role, set())
        for k in obj.keys():
            ks.add(k)

        # Bucket content block keys by content type
        msg = obj.get("message")
        if isinstance(msg, dict):
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    ct = block.get("type")
                    if not isinstance(ct, str) or not ct:
                        ct = "<missing-content-type>"
                    bucket = f"content.{ct}"
                    type_counts[bucket] = type_counts.get(bucket, 0) + 1
                    cks = type_keys.setdefault(bucket, set())
                    for k in block.keys():
                        cks.add(k)

    return {
        "file": str(path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "parsed_lines": total_lines,
        "parse_errors": parse_errors,
    }


def _gemini_session_json_schema_fingerprint(path: Path, max_messages: int) -> dict[str, Any]:
    """
    Best-effort schema fingerprint for Gemini CLI session JSON.

    Gemini sessions are JSON (not JSONL) and usually include a `messages` array where each
    message has a `type` field (e.g. `user`, `gemini`). We bucket keys by message `type`,
    plus a `root` bucket for top-level session keys.
    """
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0
    parsed_messages: int = 0

    try:
        root = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {
            "file": str(path),
            "type_counts": {},
            "type_keys": {},
            "parsed_messages": 0,
            "parse_errors": 1,
        }

    def _add(event_type: str, obj: dict[str, Any]) -> None:
        type_counts[event_type] = type_counts.get(event_type, 0) + 1
        ks = type_keys.setdefault(event_type, set())
        for k in obj.keys():
            ks.add(k)

    if isinstance(root, dict):
        _add("root", root)
        messages = root.get("messages")
        if isinstance(messages, list):
            for item in messages[: max(0, int(max_messages))]:
                if not isinstance(item, dict):
                    continue
                t = item.get("type")
                event_type = t if isinstance(t, str) and t else "<missing-type>"
                _add(event_type, item)
                parsed_messages += 1
    elif isinstance(root, list):
        for item in root[: max(0, int(max_messages))]:
            if not isinstance(item, dict):
                continue
            t = item.get("type")
            event_type = t if isinstance(t, str) and t else "<missing-type>"
            _add(event_type, item)
            parsed_messages += 1

    return {
        "file": str(path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "parsed_messages": parsed_messages,
        "parse_errors": parse_errors,
    }


def _opencode_storage_root_for_session_file(session_path: Path) -> Path | None:
    # Typical layout: ~/.local/share/opencode/storage/session/<project>/ses_*.json
    for parent in session_path.parents:
        try:
            if (parent / "session").exists() and (parent / "message").exists() and (parent / "part").exists():
                return parent
        except OSError:
            continue
    return None


def _opencode_fixture_file_schema_fingerprint(path: Path) -> dict[str, Any]:
    """
    Fingerprint a single OpenCode JSON file from fixtures.

    We bucket keys by "record kind" so message/part schema changes are visible separately
    from session record schema changes.
    """
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0

    try:
        obj = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {"file": str(path), "type_counts": {}, "type_keys": {}, "parse_errors": 1}

    if not isinstance(obj, dict):
        return {"file": str(path), "type_counts": {}, "type_keys": {}, "parse_errors": 0}

    p = str(path).replace("\\", "/")
    if "/storage_v2/session/" in p or "/storage_legacy/session/" in p:
        event_type = "session"
    elif "/storage_v2/message/" in p:
        role = obj.get("role")
        event_type = f"message.{role}" if isinstance(role, str) and role else "message"
    elif "/storage_v2/part/" in p:
        part_type = obj.get("type")
        event_type = f"part.{part_type}" if isinstance(part_type, str) and part_type else "part"
    else:
        event_type = "opencode_json"

    type_counts[event_type] = 1
    type_keys[event_type] = set(obj.keys())

    return {
        "file": str(path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "parse_errors": parse_errors,
    }


def _opencode_storage_session_tree_schema_fingerprint(
    session_path: Path, *, max_messages: int, max_parts: int
) -> dict[str, Any]:
    """
    Fingerprint a local OpenCode v2 session by scanning:
    - session record (storage/session/**/ses_*.json)
    - message records (storage/message/<sessionId>/msg_*.json)
    - part records (storage/part/<messageId>/*.json)
    """
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0
    message_files_parsed: int = 0
    part_files_parsed: int = 0

    def _add(event_type: str, obj: dict[str, Any]) -> None:
        type_counts[event_type] = type_counts.get(event_type, 0) + 1
        ks = type_keys.setdefault(event_type, set())
        for k in obj.keys():
            ks.add(k)

    try:
        session_obj = json.loads(session_path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {
            "file": str(session_path),
            "type_counts": {},
            "type_keys": {},
            "message_files_parsed": 0,
            "part_files_parsed": 0,
            "parse_errors": 1,
        }

    if isinstance(session_obj, dict):
        _add("session", session_obj)

    session_id = session_obj.get("id") if isinstance(session_obj, dict) else None
    if not isinstance(session_id, str) or not session_id:
        return {
            "file": str(session_path),
            "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
            "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
            "message_files_parsed": 0,
            "part_files_parsed": 0,
            "parse_errors": parse_errors,
        }

    storage_root = _opencode_storage_root_for_session_file(session_path)
    if storage_root is None:
        return {
            "file": str(session_path),
            "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
            "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
            "message_files_parsed": 0,
            "part_files_parsed": 0,
            "parse_errors": parse_errors,
            "warning": "storage_root_not_found",
        }

    msg_dir = storage_root / "message" / session_id
    if not msg_dir.exists():
        return {
            "file": str(session_path),
            "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
            "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
            "message_files_parsed": 0,
            "part_files_parsed": 0,
            "parse_errors": parse_errors,
            "warning": "message_dir_not_found",
        }

    total_parts_budget = max(0, int(max_parts))
    msg_budget = max(0, int(max_messages))
    for msg_file in sorted(msg_dir.glob("msg_*.json"))[:msg_budget]:
        try:
            msg_obj = json.loads(msg_file.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            parse_errors += 1
            continue
        if not isinstance(msg_obj, dict):
            continue
        role = msg_obj.get("role")
        event_type = f"message.{role}" if isinstance(role, str) and role else "message"
        _add(event_type, msg_obj)
        message_files_parsed += 1

        mid = msg_obj.get("id")
        if not isinstance(mid, str) or not mid:
            continue
        part_dir = storage_root / "part" / mid
        if not part_dir.exists():
            continue
        if total_parts_budget <= 0:
            continue
        part_files = sorted(part_dir.glob("*.json"))
        for part_file in part_files:
            if total_parts_budget <= 0:
                break
            try:
                part_obj = json.loads(part_file.read_text(encoding="utf-8", errors="replace"))
            except Exception:
                parse_errors += 1
                total_parts_budget -= 1
                continue
            total_parts_budget -= 1
            if not isinstance(part_obj, dict):
                continue
            part_type = part_obj.get("type")
            et = f"part.{part_type}" if isinstance(part_type, str) and part_type else "part"
            _add(et, part_obj)
            part_files_parsed += 1

    return {
        "file": str(session_path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "message_files_parsed": message_files_parsed,
        "part_files_parsed": part_files_parsed,
        "parse_errors": parse_errors,
    }


def _opencode_sqlite_latest_session_schema_fingerprint(
    db_path: Path, *, max_messages: int, max_parts: int
) -> dict[str, Any]:
    """
    Fingerprint OpenCode's current SQLite backend (opencode.db).

    The Swift app reads the SQLite tables and maps records into the same logical
    session/message/part model as the older storage/ JSON tree. Keep these
    schema buckets normalized to the fixture keys so version checks report real
    format drift, not storage implementation details like snake_case columns.
    """
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors = 0
    message_rows_parsed = 0
    part_rows_parsed = 0

    def _add(event_type: str, obj: dict[str, Any]) -> None:
        type_counts[event_type] = type_counts.get(event_type, 0) + 1
        ks = type_keys.setdefault(event_type, set())
        for k, v in obj.items():
            if v is not None:
                ks.add(k)

    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
    except Exception as exc:
        return {
            "file": str(db_path),
            "type_counts": {},
            "type_keys": {},
            "message_rows_parsed": 0,
            "part_rows_parsed": 0,
            "parse_errors": 1,
            "error": f"sqlite_open_failed: {exc}",
        }

    try:
        session_row = conn.execute(
            """
            SELECT id, project_id, parent_id, slug, directory, title, version,
                   time_created, time_updated, summary_additions, summary_deletions,
                   summary_files, summary_diffs
            FROM session
            WHERE time_archived IS NULL
            ORDER BY time_updated DESC
            LIMIT 1;
            """
        ).fetchone()
        if session_row is None:
            return {
                "file": str(db_path),
                "type_counts": {},
                "type_keys": {},
                "message_rows_parsed": 0,
                "part_rows_parsed": 0,
                "parse_errors": 0,
                "warning": "no_sessions_found",
            }

        session_id = str(session_row["id"])
        session_obj: dict[str, Any] = {
            "id": session_id,
            "projectID": session_row["project_id"],
            "parentID": session_row["parent_id"],
            "slug": session_row["slug"],
            "directory": session_row["directory"],
            "title": session_row["title"],
            "version": session_row["version"],
            "time": {
                "created": session_row["time_created"],
                "updated": session_row["time_updated"],
            },
        }
        if any(session_row[k] is not None for k in ("summary_additions", "summary_deletions", "summary_files")):
            session_obj["summary"] = {
                "additions": session_row["summary_additions"],
                "deletions": session_row["summary_deletions"],
                "files": session_row["summary_files"],
            }
        if session_row["summary_diffs"] is not None:
            session_obj["summaryDiffs"] = session_row["summary_diffs"]
        _add("session", session_obj)

        message_rows = conn.execute(
            """
            SELECT id, session_id, data
            FROM message
            WHERE session_id = ?
            ORDER BY time_created, id
            LIMIT ?;
            """,
            (session_id, max(0, int(max_messages))),
        ).fetchall()

        total_parts_budget = max(0, int(max_parts))
        for msg_row in message_rows:
            try:
                msg_obj = json.loads(str(msg_row["data"]))
            except Exception:
                parse_errors += 1
                continue
            if not isinstance(msg_obj, dict):
                continue
            msg_obj = dict(msg_obj)
            msg_obj.setdefault("id", msg_row["id"])
            msg_obj.setdefault("sessionID", msg_row["session_id"])
            role = msg_obj.get("role")
            event_type = f"message.{role}" if isinstance(role, str) and role else "message"
            _add(event_type, msg_obj)
            message_rows_parsed += 1

            if total_parts_budget <= 0:
                continue
            part_rows = conn.execute(
                """
                SELECT id, message_id, session_id, data
                FROM part
                WHERE message_id = ?
                ORDER BY time_created, id
                LIMIT ?;
                """,
                (msg_row["id"], total_parts_budget),
            ).fetchall()
            for part_row in part_rows:
                try:
                    part_obj = json.loads(str(part_row["data"]))
                except Exception:
                    parse_errors += 1
                    total_parts_budget -= 1
                    continue
                total_parts_budget -= 1
                if not isinstance(part_obj, dict):
                    continue
                part_obj = dict(part_obj)
                part_obj.setdefault("id", part_row["id"])
                part_obj.setdefault("messageID", part_row["message_id"])
                part_obj.setdefault("sessionID", part_row["session_id"])
                part_type = part_obj.get("type")
                event_type = f"part.{part_type}" if isinstance(part_type, str) and part_type else "part"
                _add(event_type, part_obj)
                part_rows_parsed += 1
    except Exception as exc:
        parse_errors += 1
        return {
            "file": str(db_path),
            "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
            "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
            "message_rows_parsed": message_rows_parsed,
            "part_rows_parsed": part_rows_parsed,
            "parse_errors": parse_errors,
            "error": f"sqlite_query_failed: {exc}",
        }
    finally:
        conn.close()

    return {
        "file": str(db_path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "message_rows_parsed": message_rows_parsed,
        "part_rows_parsed": part_rows_parsed,
        "parse_errors": parse_errors,
    }


def _baseline_type_keys_for_agent(agent_name: str, baseline_paths: list[str]) -> dict[str, list[str]]:
    # Baseline should represent the current "normal" format; ignore schema_drift fixtures.
    filtered = [p for p in baseline_paths if isinstance(p, str) and p and "schema_drift" not in p]
    fps: list[dict[str, Any]] = []

    if agent_name in ("codex", "claude", "copilot", "droid"):
        for p in filtered:
            if not p.endswith(".jsonl"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_jsonl_schema_fingerprint(bp, max_lines=5000))
    elif agent_name == "gemini":
        for p in filtered:
            if not p.endswith(".json"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_gemini_session_json_schema_fingerprint(bp, max_messages=5000))
    elif agent_name == "opencode":
        for p in filtered:
            if not p.endswith(".json"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_opencode_fixture_file_schema_fingerprint(bp))
    elif agent_name == "openclaw":
        for p in filtered:
            if not p.endswith(".jsonl"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_jsonl_schema_fingerprint(bp, max_lines=5000))
    elif agent_name == "cursor":
        for p in filtered:
            if not p.endswith(".jsonl"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_cursor_transcript_schema_fingerprint(bp, max_lines=5000))

    return _merge_type_keys(fps)


def _merge_type_keys(fingerprints: list[dict[str, Any]]) -> dict[str, list[str]]:
    merged: dict[str, set[str]] = {}
    for fp in fingerprints:
        tk = fp.get("type_keys") if isinstance(fp, dict) else None
        if not isinstance(tk, dict):
            continue
        for t, keys in tk.items():
            if not isinstance(t, str):
                continue
            if not isinstance(keys, list):
                continue
            bucket = merged.setdefault(t, set())
            for k in keys:
                if isinstance(k, str):
                    bucket.add(k)
    return {t: sorted(list(keys)) for t, keys in sorted(merged.items())}


def _schema_diff(
    *, observed_type_keys: dict[str, list[str]], baseline_type_keys: dict[str, list[str]]
) -> dict[str, Any]:
    observed_types = set(observed_type_keys.keys())
    baseline_types = set(baseline_type_keys.keys())
    unknown_types = sorted(observed_types - baseline_types)
    missing_types = sorted(baseline_types - observed_types)

    unknown_keys: dict[str, list[str]] = {}
    missing_keys: dict[str, list[str]] = {}
    for t in sorted(observed_types | baseline_types):
        o = set(observed_type_keys.get(t, []))
        b = set(baseline_type_keys.get(t, []))
        extra = sorted(o - b)
        miss = sorted(b - o)
        if extra:
            unknown_keys[t] = extra
        if miss:
            missing_keys[t] = miss

    unknown_only_is_empty = (not unknown_types and not unknown_keys)
    return {
        "unknown_types": unknown_types,
        "missing_types": missing_types,
        "unknown_keys": unknown_keys,
        "missing_keys": missing_keys,
        "unknown_only_is_empty": unknown_only_is_empty,
        "is_empty": (not unknown_types and not missing_types and not unknown_keys and not missing_keys),
    }


def _run_probe_script(probe: dict[str, Any], out_dir: Path, verbose: bool) -> dict[str, Any]:
    label = probe.get("label") or "probe"
    argv = probe.get("argv")
    timeout = int(probe.get("timeout_seconds") or 60)
    parse_kind = probe.get("parse")

    if not isinstance(argv, list) or not all(isinstance(x, str) for x in argv):
        return {"label": label, "ok": False, "error": "invalid_probe_argv"}

    argv = list(argv)

    # Special case: droid probe expects an output directory appended after "--out"
    if argv and argv[-1] == "--out":
        argv.append(str(out_dir / "droid"))

    rc, stdout, stderr = _run_cmd(argv, timeout=timeout)

    (out_dir / f"{label}.argv.json").write_text(json.dumps(argv, indent=2) + "\n", encoding="utf-8")
    (out_dir / f"{label}.stdout.txt").write_text(stdout + "\n", encoding="utf-8")
    (out_dir / f"{label}.stderr.txt").write_text(stderr + "\n", encoding="utf-8")

    parsed: dict[str, Any] | None = None
    if parse_kind == "claude_usage_json" or parse_kind == "codex_status_json":
        try:
            parsed = json.loads(stdout) if stdout else None
        except Exception:
            parsed = None
    elif parse_kind == "claude_status_json":
        try:
            parsed = json.loads(stdout) if stdout else None
        except Exception:
            parsed = None
    elif parse_kind == "droid_schema_report":
        # The probe script itself writes schema_report.json in its output directory.
        report_path = out_dir / "droid" / "schema_report.json"
        if report_path.exists():
            try:
                parsed = json.loads(report_path.read_text(encoding="utf-8"))
            except Exception:
                parsed = None
    elif parse_kind == "capture_latest_sessions":
        # capture_latest_agent_sessions.py prints paths; we just record stdout.
        parsed = {"captured": stdout.splitlines()}
    elif parse_kind == "cursor_sqlite_json":
        try:
            parsed = json.loads(stdout) if stdout else None
        except Exception:
            parsed = None

    ok = rc == 0
    if parse_kind == "claude_usage_json":
        ok = ok and isinstance(parsed, dict) and bool(parsed.get("ok") is True)
    if parse_kind == "codex_status_json":
        ok = ok and isinstance(parsed, dict)
    if parse_kind == "claude_status_json":
        ok = ok and isinstance(parsed, dict) and bool(parsed.get("ok") is True)
    if parse_kind == "cursor_sqlite_json":
        ok = ok and isinstance(parsed, dict) and bool(parsed.get("ok") is True)

    if verbose and not ok:
        print(f"Probe {label} failed (exit={rc}).", file=sys.stderr)

    return {
        "label": label,
        "argv": argv,
        "exit_code": rc,
        "ok": ok,
        "parse": parse_kind,
        "parsed": parsed,
        "stdout_file": str(out_dir / f"{label}.stdout.txt"),
        "stderr_file": str(out_dir / f"{label}.stderr.txt"),
    }


def _fetch_upstream(source: dict[str, Any], timeout: int) -> dict[str, Any]:
    kind = source.get("kind")
    if kind == "github_latest_release":
        repo = source.get("repo")
        if not isinstance(repo, str) or not repo:
            return {"ok": False, "error": "missing_repo"}
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        try:
            obj = _http_get_json(url, timeout=timeout)
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            return {"ok": False, "error": "fetch_failed", "detail": str(exc), "url": url}
        if not isinstance(obj, dict):
            return {"ok": False, "error": "invalid_response", "url": url}
        tag = obj.get("tag_name")
        name = obj.get("name")
        body = obj.get("body")
        raw = tag if isinstance(tag, str) else (name if isinstance(name, str) else "")
        ver = _extract_semver(raw) or None
        return {
            "ok": True,
            "version": ver,
            "url": url,
            "html_url": obj.get("html_url"),
            "tag_name": tag,
            "name": name,
            "body": body,
            "published_at": obj.get("published_at"),
        }

    if kind == "npm_latest":
        pkg = source.get("package")
        if not isinstance(pkg, str) or not pkg:
            return {"ok": False, "error": "missing_package"}
        encoded = urllib.parse.quote(pkg, safe="")
        url = f"https://registry.npmjs.org/{encoded}/latest"
        try:
            obj = _http_get_json(url, timeout=timeout)
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            return {"ok": False, "error": "fetch_failed", "detail": str(exc), "url": url}
        ver = obj.get("version") if isinstance(obj, dict) else None
        ver_s = ver if isinstance(ver, str) else None
        ver_s = _extract_semver(ver_s or "") or ver_s
        return {"ok": True, "version": ver_s, "url": url}

    if kind == "url_regex_semver_max":
        url = source.get("url")
        pattern = source.get("pattern")
        if not isinstance(url, str) or not isinstance(pattern, str):
            return {"ok": False, "error": "missing_url_or_pattern"}
        try:
            text = _http_get_text(url, timeout=timeout)
        except urllib.error.URLError as exc:
            return {"ok": False, "error": "fetch_failed", "detail": str(exc), "url": url}
        rx = re.compile(pattern)
        versions: list[Semver] = []
        for m in rx.finditer(text):
            raw = m.group(1) if m.groups() else m.group(0)
            v = Semver.parse(raw)
            if v:
                versions.append(v)
        if not versions:
            return {"ok": False, "error": "no_versions_found", "url": url}
        best = max(versions)
        return {"ok": True, "version": str(best), "url": url}

    return {"ok": False, "error": "unsupported_source_kind", "kind": kind}


def _apply_stale_override(
    *,
    severity: str,
    recommendation: str,
    installed_newer_than_verified: bool,
    schema_matches_baseline: bool | None,
    sample_freshness: dict[str, Any] | None,
    probe_failed: bool,
) -> tuple[str, str]:
    """Spec §3.3: block auto-downgrade when the weekly sample is stale.

    Mirrors the bump_verified_version auto-downgrade guards — only fires
    when the downgrade would have fired (severity is low/medium, probe
    succeeded, installed > verified, schema matches baseline) AND the
    sample is stale. Preserves high severity and probe-failure
    recommendations untouched.
    """
    if severity not in ("low", "medium"):
        return severity, recommendation
    if probe_failed:
        return severity, recommendation
    if not installed_newer_than_verified:
        return severity, recommendation
    if schema_matches_baseline is not True:
        return severity, recommendation
    if not isinstance(sample_freshness, dict):
        return severity, recommendation
    if sample_freshness.get("is_stale") is not True:
        return severity, recommendation
    return "medium", "run_prebump_validator"


def _format_summary_line(
    *,
    agent_name: str,
    severity: str,
    verified: str | None,
    installed: str | None,
    upstream: str | None,
    recommendation: str,
    sample_freshness: dict[str, Any] | None,
) -> str:
    base = (
        f"{agent_name}: severity={severity} "
        f"verified={verified or 'unknown'} "
        f"installed={installed or 'unknown'} "
        f"upstream={upstream or 'unknown'} "
        f"rec={recommendation}"
    )
    if not isinstance(sample_freshness, dict):
        return base
    is_stale = sample_freshness.get("is_stale")
    reason = sample_freshness.get("stale_reason")
    token = "stale=true" if is_stale else "stale=false"
    if isinstance(reason, str) and reason:
        token = f"{token}({reason})"
    return f"{base} {token}"


def _build_prebump_report_entry(
    *,
    agent_name: str,
    driver_name: str,
    ok: bool,
    session_path: Path | None,
    stdout_file: Path | None,
    stderr_file: Path | None,
    error: str | None,
    schema_diff: dict[str, Any] | None,
    fresh_session_matches_baseline: bool | None,
    sample_freshness: dict[str, Any] | None,
    auth_warnings: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "agent": agent_name,
        "driver": driver_name,
        "ok": ok,
        "session_path": str(session_path) if session_path else None,
        "stdout_file": str(stdout_file) if stdout_file else None,
        "stderr_file": str(stderr_file) if stderr_file else None,
        "error": error,
        "evidence": {
            "schema_matches_baseline": fresh_session_matches_baseline,
            "fresh_session_matches_baseline": fresh_session_matches_baseline,
            # Spec §3.1: true ONLY when prebump produced fresh evidence
            # AND it matched baseline.
            "fresh_evidence_available": fresh_session_matches_baseline is True,
            "schema_diff": schema_diff,
            "sample_freshness": sample_freshness,
            "auth_warnings": list(auth_warnings or []),
        },
    }


def _exit_code_for_prebump(entries: list[dict[str, Any]]) -> int:
    worst = 0
    for e in entries:
        if e.get("fatal") == "config":
            worst = max(worst, 4)
            continue
        if not e.get("ok"):
            worst = max(worst, 3)
            continue
        ev = e.get("evidence") or {}
        if ev.get("fresh_session_matches_baseline") is False:
            worst = max(worst, 2)
    return worst


class _DiscoveryViolation(Exception):
    """Raised when a driver result violates discover_session contract."""


def _session_path_matches_glob(session_path: Path, root: Path, pattern: str) -> bool:
    """Return True if session_path is among the files yielded by root.glob(pattern).

    Delegates glob walking to pathlib itself (root.glob) so ** spans
    nested directories regardless of the host interpreter's pattern
    semantics. Resolves both sides so symlinked sandbox HOMEs compare
    equal.

    Performance: root.glob(pattern) walks the directory tree on every
    call. That is fine for per-agent prebump runs (one session per run,
    tiny sandbox HOME) but must not be used in hot loops — keep it
    scoped to post-run validation.
    """
    try:
        session_resolved = session_path.resolve()
    except (OSError, RuntimeError):
        return False
    for candidate in root.glob(pattern):
        try:
            if candidate.resolve() == session_resolved:
                return True
        except (OSError, RuntimeError):
            continue
    return False


def _validate_session_discovery(session_path: Path, contract: dict, sandbox: Path) -> None:
    """F4: validate session_path against the agent's discover_session contract.

    Checks (each failure raises _DiscoveryViolation):
      1. session_path is under one of contract['roots'], where each root
         is interpreted relative to *sandbox* (sandbox-HOME substitution).
      2. session_path is yielded by root.glob(pattern) for one of the
         declared (root, glob) pairs — see _session_path_matches_glob.
      3. The file parses as JSONL and contains at least one line per
         type in contract['required_types'] (matched on the per-line
         'type' field).

    Discovery violations are mapped to exit 3 (driver-failed) by the
    caller — the driver produced the wrong artifact.

    Note on key tolerance: this runtime validator accepts BOTH modern
    ("roots"/"globs") and legacy ("roots_relative_to_sandbox"/"glob")
    config keys so older on-disk configs keep validating cleanly. The
    config gate in _run_prebump deliberately only accepts the modern
    form — the asymmetry is intentional; do not "fix" it.
    """
    if not isinstance(contract, dict):
        return  # no contract declared → skip (see residual risk note)
    try:
        session_path = session_path.resolve()
    except OSError as exc:
        raise _DiscoveryViolation(f"cannot resolve session_path: {exc}") from exc

    roots = contract.get("roots") or contract.get("roots_relative_to_sandbox") or []
    # Resolve the declared roots to absolute sandbox-relative paths once.
    resolved_roots: list[Path] = []
    for root_spec in roots:
        resolved_roots.append((sandbox / str(root_spec).lstrip("/")).resolve())
    if resolved_roots:
        ok = False
        for root in resolved_roots:
            try:
                session_path.relative_to(root)
                ok = True
                break
            except ValueError:
                continue
        if not ok:
            raise _DiscoveryViolation(
                f"session {session_path} is not under any declared root in {roots}"
            )

    globs = contract.get("globs")
    if not globs:
        single = contract.get("glob")
        globs = [single] if single else []
    if globs and resolved_roots:
        # Iterate every (root, glob) pair; succeed on the first match.
        matched = False
        for root in resolved_roots:
            for pattern in globs:
                if _session_path_matches_glob(session_path, root, pattern):
                    matched = True
                    break
            if matched:
                break
        if not matched:
            raise _DiscoveryViolation(
                f"session {session_path} does not match any (root, glob) pair "
                f"in roots={roots} globs={globs}"
            )

    required_types = list(contract.get("required_types") or [])
    if required_types:
        seen: set[str] = set()
        try:
            with session_path.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError as exc:
                        raise _DiscoveryViolation(
                            f"session {session_path} is not valid JSONL: {exc}"
                        ) from exc
                    t = obj.get("type") if isinstance(obj, dict) else None
                    if isinstance(t, str):
                        seen.add(t)
        except OSError as exc:
            raise _DiscoveryViolation(f"cannot read session: {exc}") from exc
        missing = [t for t in required_types if t not in seen]
        if missing:
            raise _DiscoveryViolation(
                f"session {session_path} missing required types {missing}; saw {sorted(seen)}"
            )


def _run_prebump(
    args,
    cfg: dict[str, Any],
    *,
    report_dir: Path,
    verified_map: dict[str, str | None],
    evidence: dict[str, list[str]],
) -> int:
    import agent_watch_prebump_drivers as drv_mod

    prebump_dir = report_dir.parent / (report_dir.name + "-prebump")
    prebump_dir.mkdir(parents=True, exist_ok=True)

    agents_cfg = cfg.get("agents") or {}
    configured_prebump_agents = {
        name for name, acfg in agents_cfg.items()
        if isinstance(acfg, dict) and isinstance(acfg.get("prebump"), dict)
    }
    requested = list(args.agent or [])
    if requested:
        unknown = [a for a in requested if a not in configured_prebump_agents]
        if unknown:
            import sys as _sys
            _sys.stderr.write(
                "agent_watch --mode prebump: rejected agent(s) "
                f"{unknown}: not in configured prebump set "
                f"{sorted(configured_prebump_agents)}\n"
            )
            return 4
        selected = set(requested)
    else:
        selected = set(configured_prebump_agents)

    prebump_agents = {name: agents_cfg[name] for name in selected}
    if not prebump_agents:
        return 0

    # F1/A: discovery-contract config gate. Every selected agent must
    # declare a well-formed prebump.discover_session contract using the
    # modern roots/globs keys. Collect ALL failures across the selected
    # set before bailing so the user can fix everything in one pass.
    gate_failures: list[dict[str, Any]] = []
    for _name, _acfg in prebump_agents.items():
        _pb = _acfg.get("prebump") or {}
        _ds = _pb.get("discover_session")
        if not isinstance(_ds, dict):
            gate_failures.append({
                "agent": _name,
                "driver": _pb.get("driver"),
                "ok": False,
                "error": f"config_gate:{_name}: prebump.discover_session missing or not a dict",
                "fatal": "config",
                "evidence": {},
            })
            continue
        _roots = _ds.get("roots")
        _globs = _ds.get("globs")
        _req = _ds.get("required_types", [])
        _reasons: list[str] = []
        if not isinstance(_roots, list) or len(_roots) < 1:
            _reasons.append("roots must be a non-empty list")
        if not isinstance(_globs, list) or len(_globs) < 1:
            _reasons.append("globs must be a non-empty list")
        # required_types is OPTIONAL: missing key or empty list is fine
        # (Copilot declares required_types: [] by design).
        if "required_types" in _ds and not isinstance(_req, list):
            _reasons.append("required_types must be a list when present")
        if _reasons:
            import sys as _sys
            _msg = f"config_gate:{_name}: " + "; ".join(_reasons)
            _sys.stderr.write(
                f"agent_watch --mode prebump: {_msg}\n"
            )
            gate_failures.append({
                "agent": _name,
                "driver": _pb.get("driver"),
                "ok": False,
                "error": _msg,
                "fatal": "config",
                "evidence": {},
            })
    if gate_failures:
        # Do not run any driver; let the user fix all config errors at
        # once. Write a report entry per failing agent and exit 4.
        report = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "mode": "prebump",
            "report_dir": _safe_relpath(prebump_dir),
            "results": {e["agent"]: e for e in gate_failures},
        }
        (prebump_dir / "report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return 4

    entries: list[dict[str, Any]] = []
    now_epoch = datetime.now(timezone.utc).timestamp()
    real_home = Path(os.environ.get("HOME", str(Path.home())))

    for agent_name, agent_cfg in prebump_agents.items():
        pb = agent_cfg["prebump"]
        driver_name = pb.get("driver")
        driver = drv_mod.DRIVERS.get(driver_name) if isinstance(driver_name, str) else None
        agent_out = prebump_dir / agent_name
        agent_out.mkdir(parents=True, exist_ok=True)

        if driver is None:
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": f"unknown_driver:{driver_name}",
                "fatal": "config",
                "evidence": {},
            })
            continue

        try:
            sandbox = drv_mod.make_sandbox(parent=agent_out, label=agent_name)
        except Exception as exc:
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": f"sandbox_create_failed:{exc}",
                "fatal": "config",
                "evidence": {},
            })
            continue

        # F2: prepare_auth is the only auth path. Drivers receive env.
        try:
            env, auth_warnings = drv_mod.prepare_auth(
                prebump_cfg=pb, sandbox=sandbox, real_home=real_home,
            )
        except drv_mod.HygieneError as exc:
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": f"hygiene_failed:{exc}",
                "fatal": "config",
                "evidence": {},
            })
            drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
            continue

        # P2: surface prepare_auth advisory warnings (e.g. 90-day stale
        # credential) to stderr immediately so operators see them at
        # emit-time. They are also threaded into evidence.auth_warnings
        # below for the report audit trail.
        for _warn in auth_warnings:
            import sys as _sys
            _sys.stderr.write(f"agent_watch prebump [{agent_name}]: {_warn}\n")

        prompt = str(pb.get("prompt") or "")
        # F6: CLI flag wins by default; fall back to per-agent config; then global default.
        if args.timeout_seconds is not None:
            timeout = int(args.timeout_seconds)
        else:
            timeout = int(pb.get("timeout_seconds") or DEFAULT_TIMEOUT_SECONDS)

        try:
            result = driver.run(sandbox, env, prompt, timeout)
        except drv_mod.HygieneError as exc:
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": f"hygiene_failed:{exc}",
                "fatal": "config",
                "evidence": {},
            })
            drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
            continue
        except Exception as exc:
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": f"driver_exception:{exc}",
                "evidence": {},
            })
            drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
            continue

        # Copilot hermeticity gate: sandbox_breach → fatal=config (exit 4)
        # unless --allow-real-home was explicitly passed.
        if (
            not result.ok
            and isinstance(result.error, str)
            and result.error.startswith("sandbox_breach")
        ):
            if not args.allow_real_home:
                entries.append({
                    "agent": agent_name,
                    "driver": driver_name,
                    "ok": False,
                    "error": result.error,
                    "fatal": "config",
                    "stdout_file": str(result.stdout_file),
                    "stderr_file": str(result.stderr_file),
                    "evidence": {"auth_warnings": list(auth_warnings)},
                })
                drv_mod.teardown_sandbox(sandbox, keep=True)
                continue
            # --allow-real-home: re-run the driver with real HOME so the
            # session lands under the user's actual home directory.
            import sys as _sys
            _sys.stderr.write(
                f"agent_watch prebump [{agent_name}]: sandbox_breach detected, "
                f"--allow-real-home set, re-running with real HOME\n"
            )
            drv_mod.teardown_sandbox(sandbox, keep=args.keep_sandbox)
            env["HOME"] = str(real_home)
            try:
                result = driver.run(sandbox, env, prompt, timeout)
            except drv_mod.HygieneError as exc:
                entries.append({
                    "agent": agent_name,
                    "driver": driver_name,
                    "ok": False,
                    "error": f"hygiene_failed:{exc}",
                    "fatal": "config",
                    "evidence": {},
                })
                continue
            except Exception as exc:
                entries.append({
                    "agent": agent_name,
                    "driver": driver_name,
                    "ok": False,
                    "error": f"driver_exception:{exc}",
                    "evidence": {},
                })
                continue
            # For the re-run, discovery validation must use real_home
            # as the sandbox parameter since roots are HOME-relative.
            sandbox = real_home

        # P1: ok=True must be backed by an actual session file. A driver
        # that returns ok=True with session_path=None or a path that does
        # not exist has silently failed — treat as driver-failed so
        # _exit_code_for_prebump returns 3 instead of letting the run
        # pass the gate on no fresh evidence.
        if result.ok and (result.session_path is None or not result.session_path.exists()):
            entries.append({
                "agent": agent_name,
                "driver": driver_name,
                "ok": False,
                "error": "no_session_produced",
                "evidence": {
                    "auth_warnings": list(auth_warnings),
                },
            })
            drv_mod.teardown_sandbox(sandbox, keep=(args.keep_sandbox or True))
            continue

        # F4: validate the session against the discover_session contract.
        if result.ok and result.session_path and result.session_path.exists():
            try:
                _validate_session_discovery(
                    result.session_path,
                    pb.get("discover_session") or {},
                    sandbox,
                )
            except _DiscoveryViolation as exc:
                entries.append({
                    "agent": agent_name,
                    "driver": driver_name,
                    "ok": False,
                    "error": f"discovery_violation:{exc}",
                    "evidence": {},
                })
                drv_mod.teardown_sandbox(sandbox, keep=(args.keep_sandbox or True))
                continue

        schema_diff: dict[str, Any] | None = None
        fresh_matches: bool | None = None
        if result.ok and result.session_path and result.session_path.exists():
            matrix_key = {
                "codex": "codex_cli", "claude": "claude_code", "copilot": "copilot_cli",
                "droid": "droid", "gemini": "gemini_cli", "opencode": "opencode",
                "openclaw": "openclaw",
            }.get(agent_name)
            baseline_paths = evidence.get(matrix_key or "", []) if matrix_key else []
            baseline_type_keys = _baseline_type_keys_for_agent(agent_name, baseline_paths)
            if agent_name == "gemini":
                fp = _gemini_session_json_schema_fingerprint(result.session_path, max_messages=5000)
            elif agent_name == "opencode":
                fp = _opencode_storage_session_tree_schema_fingerprint(
                    result.session_path, max_messages=250, max_parts=2500
                )
            else:
                fp = _jsonl_schema_fingerprint(result.session_path, max_lines=5000)
            if baseline_type_keys:
                schema_diff = _schema_diff(
                    observed_type_keys=fp.get("type_keys") or {},
                    baseline_type_keys=baseline_type_keys,
                )
                fresh_matches = bool(schema_diff.get("unknown_only_is_empty"))
            else:
                fresh_matches = True  # no baseline → nothing diffs

        cli_path, cli_mtime = _resolve_cli_binary_mtime(
            agent_cfg.get("installed_version_cmd") if isinstance(agent_cfg.get("installed_version_cmd"), list) else None
        )
        sample_mtime = None
        if result.session_path and result.session_path.exists():
            try:
                sample_mtime = float(result.session_path.stat().st_mtime)
            except OSError:
                sample_mtime = None
        window_days = int(((agent_cfg.get("weekly") or {}).get("freshness_window_days") or 14))
        sf = _compute_sample_freshness(
            sample_mtime=sample_mtime,
            cli_binary_path=cli_path,
            cli_binary_mtime=cli_mtime,
            freshness_window_seconds=window_days * 86400,
            now_epoch=now_epoch,
            mode_context="normal",
            force_fresh=bool(getattr(args, "force_fresh", False)),
        )

        entry = _build_prebump_report_entry(
            agent_name=agent_name,
            driver_name=driver_name,
            ok=bool(result.ok),
            session_path=result.session_path,
            stdout_file=result.stdout_file,
            stderr_file=result.stderr_file,
            error=result.error,
            schema_diff=schema_diff,
            fresh_session_matches_baseline=fresh_matches,
            sample_freshness=sf,
            auth_warnings=auth_warnings,
        )
        entries.append(entry)
        drv_mod.teardown_sandbox(sandbox, keep=(args.keep_sandbox or not result.ok))

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "mode": "prebump",
        "report_dir": _safe_relpath(prebump_dir),
        "results": {e["agent"]: e for e in entries},
    }
    (prebump_dir / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    rc = _exit_code_for_prebump(entries)
    print(f"Agent watch (prebump) report: {prebump_dir / 'report.json'}")
    for e in entries:
        ev = e.get("evidence") or {}
        fsmb = ev.get("fresh_session_matches_baseline")
        print(f"{e['agent']}: driver={e.get('driver')} ok={e.get('ok')} fresh_matches_baseline={fsmb} error={e.get('error')}")
    return rc


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["daily", "weekly", "prebump"], required=True)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--timeout", type=int, default=12)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--skip-update", action="store_true",
                        help="Skip installed-version and upstream-fetch checks (agents already updated locally)")
    parser.add_argument("--force-fresh", action="store_true",
                        help="Suppress staleness for this run; records stale_reason=forced_fresh")
    parser.add_argument("--agent", action="append", default=[], help="Repeatable. Restricts prebump to the listed agents.")
    parser.add_argument("--keep-sandbox", action="store_true", help="Keep prebump sandbox directories for debugging.")
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=None,
        help=(
            "Per-driver timeout for prebump runs (seconds). Precedence: "
            "CLI flag overrides per-agent config; falls back to "
            "agents.<name>.prebump.timeout_seconds, then DEFAULT_TIMEOUT_SECONDS."
        ),
    )
    parser.add_argument("--allow-real-home", action="store_true", help="Allow copilot (and other home_override agents) to fall back to real HOME after an explicit sandbox-leak diagnostic.")
    args = parser.parse_args(argv)

    cfg_path = Path(args.config)
    cfg = _read_json(cfg_path)
    report_root = Path(cfg.get("report_root") or "scripts/probe_scan_output/agent_watch")
    report_dir = report_root / _now_utc_slug()
    report_dir.mkdir(parents=True, exist_ok=True)

    matrix_versions = _read_verified_versions_from_matrix(Path("docs/agent-support/agent-support-matrix.yml"))
    matrix_obj = Path("docs/agent-support/agent-support-matrix.yml").read_text(encoding="utf-8", errors="replace")
    # Map config agent names to matrix keys
    verified_map = {
        "codex": matrix_versions.get("codex_cli"),
        "claude": matrix_versions.get("claude_code"),
        "opencode": matrix_versions.get("opencode"),
        "droid": matrix_versions.get("droid"),
        "gemini": matrix_versions.get("gemini_cli"),
        "copilot": matrix_versions.get("copilot_cli"),
        "openclaw": matrix_versions.get("openclaw"),
        "cursor": matrix_versions.get("cursor"),
    }

    # Extract evidence fixtures from matrix YAML (minimal parser for `agents.*.evidence_fixtures:` lists).
    evidence: dict[str, list[str]] = {}
    in_agents = False
    current_agent: str | None = None
    in_evidence = False
    for raw in matrix_obj.splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("agents:"):
            in_agents = True
            current_agent = None
            in_evidence = False
            continue
        if not in_agents:
            continue
        m_agent = re.match(r"^\s{2}([a-zA-Z0-9_]+):\s*$", line)
        if m_agent:
            current_agent = m_agent.group(1)
            in_evidence = False
            continue
        if current_agent is None:
            continue
        if re.match(r"^\s{4}evidence_fixtures:\s*$", line):
            in_evidence = True
            evidence[current_agent] = []
            continue
        if in_evidence:
            m_item = re.match(r'^\s{6}-\s+"?(.*?)"?\s*$', line)
            if m_item:
                evidence[current_agent].append(m_item.group(1))
                continue
            # Exit evidence block when indentation changes back to 4 spaces (new field) or 2 (new agent).
            if re.match(r"^\s{4}\w+:", line) or re.match(r"^\s{2}\w+:", line):
                in_evidence = False

    if args.mode == "prebump":
        return _run_prebump(args, cfg, report_dir=report_dir, verified_map=verified_map, evidence=evidence)

    results: dict[str, Any] = {}
    summary_lines: list[str] = []
    any_actionable = False

    for agent_name, agent_cfg in (cfg.get("agents") or {}).items():
        cadence = (agent_cfg.get("cadence") or {})
        if args.mode == "daily" and not cadence.get("daily", False):
            continue
        if args.mode == "weekly" and not cadence.get("weekly", False):
            continue

        agent_out = report_dir / agent_name
        agent_out.mkdir(parents=True, exist_ok=True)

        verified = verified_map.get(agent_name)
        verified_semver = _extract_semver(verified or "") if verified else None

        installed_cmd = agent_cfg.get("installed_version_cmd")
        installed_rc, installed_stdout, installed_stderr = (0, "", "skipped")
        installed: str | None = None
        if not args.skip_update:
            installed_rc, installed_stdout, installed_stderr = (127, "", "missing installed_version_cmd")
            if isinstance(installed_cmd, list) and all(isinstance(x, str) for x in installed_cmd):
                installed_rc, installed_stdout, installed_stderr = _run_cmd(installed_cmd, timeout=10)
            installed = _extract_semver(installed_stdout) or (installed_stdout.split()[0] if installed_stdout else None)

        upstream_sources = agent_cfg.get("upstream") or []
        upstream: str | None = None
        upstream_source_used: dict[str, Any] | None = None
        upstream_errors: list[dict[str, Any]] = []

        if not args.skip_update and isinstance(upstream_sources, list):
            for s in upstream_sources:
                if not isinstance(s, dict):
                    continue
                res = _fetch_upstream(s, timeout=args.timeout)
                if res.get("ok"):
                    upstream = res.get("version")
                    upstream_source_used = res
                    break
                upstream_errors.append(res)

        schema_keywords = list((agent_cfg.get("risk_keywords") or {}).get("schema") or [])
        usage_keywords = list((agent_cfg.get("risk_keywords") or {}).get("usage") or [])
        notes_text = json.dumps(upstream_source_used, ensure_ascii=False) if upstream_source_used else ""

        schema_hits = _keyword_hits(notes_text, schema_keywords)
        usage_hits = _keyword_hits(notes_text, usage_keywords)

        upstream_newer_than_verified = False
        installed_newer_than_verified = False
        if verified_semver and upstream:
            cmp_uv = _compare_semver(upstream, verified_semver)
            upstream_newer_than_verified = (cmp_uv == 1)
        if verified_semver and installed:
            cmp_iv = _compare_semver(installed, verified_semver)
            installed_newer_than_verified = (cmp_iv == 1)

        monitoring_failed = False
        if not args.skip_update and upstream_sources and upstream is None:
            monitoring_failed = True

        weekly_details: dict[str, Any] | None = None
        probe_failed = False
        probe_failed_but_upstream_degraded = False
        discovery_contract_failed = False
        schema_matches_baseline: bool | None = None
        schema_diff: dict[str, Any] | None = None
        if args.mode == "weekly":
            weekly_details = {}
            local_schema_cfg = (agent_cfg.get("weekly") or {}).get("local_schema")
            discovery_contract_cfg = (agent_cfg.get("weekly") or {}).get("discovery_path_contract")
            if isinstance(local_schema_cfg, dict):
                kind = local_schema_cfg.get("kind")
                roots = list(local_schema_cfg.get("roots") or [])
                glob = str(local_schema_cfg.get("glob") or "**/*")
                matrix_key = {
                    "codex": "codex_cli",
                    "claude": "claude_code",
                    "copilot": "copilot_cli",
                    "droid": "droid",
                    "gemini": "gemini_cli",
                    "opencode": "opencode",
                    "openclaw": "openclaw",
                    "cursor": "cursor",
                }.get(agent_name)
                baseline_paths = evidence.get(matrix_key or "", []) if matrix_key else []
                baseline_type_keys = _baseline_type_keys_for_agent(agent_name, baseline_paths)

                local_fp: dict[str, Any] | None = None
                newest: Path | None = None

                if kind == "jsonl_newest":
                    max_lines = int(local_schema_cfg.get("max_lines") or 2500)
                    required_types = list(local_schema_cfg.get("required_types") or [])
                    exclude_globs_cfg = local_schema_cfg.get("exclude_globs")
                    exclude_globs = [g for g in exclude_globs_cfg if isinstance(g, str)] if isinstance(exclude_globs_cfg, list) else None
                    if required_types:
                        newest = _newest_file_with_types(
                            roots, glob, required_types, max_lines=400, exclude_globs=exclude_globs
                        )
                    else:
                        newest = _newest_file(roots, glob, exclude_globs=exclude_globs)
                    if newest:
                        local_fp = _jsonl_schema_fingerprint(newest, max_lines=max_lines)
                elif kind == "gemini_session_json_newest":
                    max_messages = int(local_schema_cfg.get("max_messages") or 2500)
                    newest = _newest_file(roots, glob)
                    if newest:
                        local_fp = _gemini_session_json_schema_fingerprint(newest, max_messages=max_messages)
                elif kind == "opencode_storage_latest_session":
                    max_messages = int(local_schema_cfg.get("max_messages") or 250)
                    max_parts = int(local_schema_cfg.get("max_parts") or 2500)
                    newest = _newest_file(roots, glob)
                    if newest:
                        local_fp = _opencode_storage_session_tree_schema_fingerprint(
                            newest, max_messages=max_messages, max_parts=max_parts
                        )
                elif kind == "opencode_latest_session":
                    max_messages = int(local_schema_cfg.get("max_messages") or 250)
                    max_parts = int(local_schema_cfg.get("max_parts") or 2500)
                    db_roots = list(local_schema_cfg.get("db_roots") or ["~/.local/share/opencode/opencode.db"])
                    db_candidates = [_expand_path(str(p)) for p in db_roots if isinstance(p, str)]
                    db_candidates = [p for p in db_candidates if p.exists()]
                    if db_candidates:
                        newest = max(db_candidates, key=lambda p: p.stat().st_mtime)
                        local_fp = _opencode_sqlite_latest_session_schema_fingerprint(
                            newest, max_messages=max_messages, max_parts=max_parts
                        )
                    else:
                        newest = _newest_file(roots, glob)
                        if newest:
                            local_fp = _opencode_storage_session_tree_schema_fingerprint(
                                newest, max_messages=max_messages, max_parts=max_parts
                            )
                elif kind == "cursor_transcript_newest":
                    max_lines = int(local_schema_cfg.get("max_lines") or 2500)
                    newest = _newest_file(roots, glob)
                    if newest:
                        local_fp = _cursor_transcript_schema_fingerprint(newest, max_lines=max_lines)

                if local_fp is not None:
                    weekly_details["local_schema"] = local_fp
                    if baseline_type_keys:
                        schema_diff = _schema_diff(
                            observed_type_keys=local_fp.get("type_keys") or {},
                            baseline_type_keys=baseline_type_keys,
                        )
                        schema_matches_baseline = bool(schema_diff.get("unknown_only_is_empty"))
                        weekly_details["baseline_schema"] = {
                            "fixtures": [p for p in baseline_paths if isinstance(p, str) and "schema_drift" not in p],
                            "type_keys": baseline_type_keys,
                        }
                        weekly_details["schema_diff"] = schema_diff
                else:
                    weekly_details["local_schema"] = {"error": "no_files_found", "roots": roots, "glob": glob, "kind": kind}

                if isinstance(discovery_contract_cfg, dict):
                    local_file = None
                    if isinstance(local_fp, dict):
                        local_file_value = local_fp.get("file")
                        if isinstance(local_file_value, str):
                            local_file = local_file_value
                    contract_result = _check_discovery_path_contract(local_file, discovery_contract_cfg)
                    weekly_details["discovery_path_contract"] = contract_result
                    discovery_contract_failed = bool(local_file) and not bool(contract_result.get("ok"))

            probes_cfg = (agent_cfg.get("weekly") or {}).get("probes") or []
            probe_results: list[dict[str, Any]] = []
            if isinstance(probes_cfg, list):
                for p in probes_cfg:
                    if not isinstance(p, dict):
                        continue
                    probe_results.append(_run_probe_script(p, agent_out, verbose=args.verbose))
            if probe_results:
                weekly_details["probes"] = probe_results
                probe_failed = any(not pr.get("ok") for pr in probe_results)
            probe_failed = probe_failed or discovery_contract_failed
            if agent_name == "claude":
                status = next((pr for pr in probe_results if pr.get("label") == "claude_status"), None)
                usage = next((pr for pr in probe_results if pr.get("label") == "claude_usage_probe"), None)
                status_parsed = (status or {}).get("parsed") if isinstance(status, dict) else None
                if isinstance(status_parsed, dict):
                    indicator = status_parsed.get("indicator")
                    incidents = status_parsed.get("incidents_count")
                    degraded = (isinstance(indicator, str) and indicator not in ("none", "unknown")) or (
                        isinstance(incidents, int) and incidents > 0
                    )
                    usage_ok = bool((usage or {}).get("ok")) if isinstance(usage, dict) else True
                    if degraded and not usage_ok:
                        probe_failed_but_upstream_degraded = True

        severity, recommendation = _pick_severity(
            upstream_newer_than_verified=upstream_newer_than_verified,
            installed_newer_than_verified=installed_newer_than_verified,
            monitoring_failed=monitoring_failed,
            schema_hits=schema_hits,
            usage_hits=usage_hits,
            probe_failed=probe_failed,
            probe_failed_but_upstream_degraded=probe_failed_but_upstream_degraded,
        )

        sample_freshness: dict[str, Any] | None = None
        if args.mode == "weekly":
            window_days_cfg = int(((agent_cfg.get("weekly") or {}).get("freshness_window_days") or 14))
            window_seconds = window_days_cfg * 86400
            sample_mtime_epoch: float | None = None
            if isinstance(weekly_details, dict):
                local_schema_obj = weekly_details.get("local_schema")
                if isinstance(local_schema_obj, dict):
                    fpath = local_schema_obj.get("file")
                    if isinstance(fpath, str):
                        try:
                            st = os.stat(fpath)
                            sample_mtime_epoch = float(st.st_mtime)
                            local_schema_obj["mtime_epoch"] = sample_mtime_epoch
                            local_schema_obj["mtime_utc"] = _epoch_to_utc_iso(sample_mtime_epoch)
                        except OSError:
                            pass
            cli_path, cli_mtime = _resolve_cli_binary_mtime(installed_cmd if isinstance(installed_cmd, list) else None)
            mode_context = "skip_update" if args.skip_update else "normal"
            sample_freshness = _compute_sample_freshness(
                sample_mtime=sample_mtime_epoch,
                cli_binary_path=cli_path,
                cli_binary_mtime=cli_mtime,
                freshness_window_seconds=window_seconds,
                now_epoch=datetime.now(timezone.utc).timestamp(),
                mode_context=mode_context,
                force_fresh=bool(getattr(args, "force_fresh", False)),
            )

        # If we have concrete evidence that the newest local schema matches our fixture baseline,
        # downgrade "installed newer" to low and suggest bumping verified version.
        if (
            args.mode == "weekly"
            and severity in ("medium", "low")
            and installed_newer_than_verified
            and schema_matches_baseline is True
            and not probe_failed
        ):
            severity = "low"
            recommendation = "bump_verified_version"

        if args.mode == "weekly":
            severity, recommendation = _apply_stale_override(
                severity=severity,
                recommendation=recommendation,
                installed_newer_than_verified=installed_newer_than_verified,
                schema_matches_baseline=schema_matches_baseline,
                sample_freshness=sample_freshness,
                probe_failed=probe_failed,
            )

        # Daily runs should only bother the user when something looks risky/urgent.
        # Low severity (newer version with no risk signal) is recorded silently.
        if args.mode == "weekly":
            actionable = severity != "none"
        else:
            actionable = severity in ("medium", "high")
        any_actionable = any_actionable or actionable

        results[agent_name] = {
            "verified_version": verified,
            "installed": {
                "argv": installed_cmd,
                "exit_code": installed_rc,
                "stdout": installed_stdout,
                "stderr": installed_stderr,
                "parsed_version": installed,
            },
            "upstream": {
                "parsed_version": upstream,
                "source_used": upstream_source_used,
                "errors": upstream_errors[:3],
            },
            "diff": {
                "upstream_newer_than_verified": upstream_newer_than_verified,
                "installed_newer_than_verified": installed_newer_than_verified,
            },
            "risk": {
                "schema_keyword_hits": schema_hits,
                "usage_keyword_hits": usage_hits,
                "monitoring_failed": monitoring_failed,
            },
            "weekly": weekly_details,
            "evidence": {
                "schema_matches_baseline": schema_matches_baseline,
                "schema_diff": schema_diff,
                "sample_freshness": sample_freshness,
                "fresh_evidence_available": False,
            },
            "severity": severity,
            "recommendation": recommendation,
        }

        if severity != "none":
            summary_lines.append(
                _format_summary_line(
                    agent_name=agent_name,
                    severity=severity,
                    verified=verified,
                    installed=installed,
                    upstream=upstream,
                    recommendation=recommendation,
                    sample_freshness=sample_freshness,
                )
            )

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "mode": args.mode,
        "config": _safe_relpath(cfg_path),
        "report_dir": _safe_relpath(report_dir),
        "results": results,
    }

    report_path = report_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    # Output policy:
    # - daily: print only when actionable
    # - weekly: always print a short summary
    if args.mode == "weekly" or any_actionable:
        print(f"Agent watch ({args.mode}) report: {report_path}")
        for line in summary_lines[:40]:
            print(line)

    if args.mode == "daily" and not any_actionable:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
