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


def _newest_file(roots: list[str], glob: str) -> Path | None:
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


def _newest_file_with_types(roots: list[str], glob: str, required_types: list[str], max_lines: int) -> Path | None:
    candidates: list[Path] = []
    for r in roots:
        root = _expand_path(r)
        if not root.exists():
            continue
        candidates.extend(root.glob(glob) if "*" in glob and "/" not in glob else root.rglob(glob))
    candidates = [c for c in candidates if c.is_file()]
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    wanted = {t for t in required_types if isinstance(t, str) and t}
    for p in candidates:
        if _jsonl_contains_any_type(p, wanted, max_lines=max_lines):
            return p
    return None


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

    ok = rc == 0
    if parse_kind == "claude_usage_json":
        ok = ok and isinstance(parsed, dict) and bool(parsed.get("ok") is True)
    if parse_kind == "codex_status_json":
        ok = ok and isinstance(parsed, dict)
    if parse_kind == "claude_status_json":
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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["daily", "weekly"], required=True)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--timeout", type=int, default=12)
    parser.add_argument("--verbose", action="store_true")
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
        installed_rc, installed_stdout, installed_stderr = (127, "", "missing installed_version_cmd")
        if isinstance(installed_cmd, list) and all(isinstance(x, str) for x in installed_cmd):
            installed_rc, installed_stdout, installed_stderr = _run_cmd(installed_cmd, timeout=10)
        installed = _extract_semver(installed_stdout) or (installed_stdout.split()[0] if installed_stdout else None)

        upstream_sources = agent_cfg.get("upstream") or []
        upstream: str | None = None
        upstream_source_used: dict[str, Any] | None = None
        upstream_errors: list[dict[str, Any]] = []

        if isinstance(upstream_sources, list):
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
        if upstream_sources and upstream is None:
            monitoring_failed = True

        weekly_details: dict[str, Any] | None = None
        probe_failed = False
        probe_failed_but_upstream_degraded = False
        schema_matches_baseline: bool | None = None
        schema_diff: dict[str, Any] | None = None
        if args.mode == "weekly":
            weekly_details = {}
            local_schema_cfg = (agent_cfg.get("weekly") or {}).get("local_schema")
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
                }.get(agent_name)
                baseline_paths = evidence.get(matrix_key or "", []) if matrix_key else []
                baseline_type_keys = _baseline_type_keys_for_agent(agent_name, baseline_paths)

                local_fp: dict[str, Any] | None = None
                newest: Path | None = None

                if kind == "jsonl_newest":
                    max_lines = int(local_schema_cfg.get("max_lines") or 2500)
                    required_types = list(local_schema_cfg.get("required_types") or [])
                    if required_types:
                        newest = _newest_file_with_types(roots, glob, required_types, max_lines=400)
                    else:
                        newest = _newest_file(roots, glob)
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
            },
            "severity": severity,
            "recommendation": recommendation,
        }

        if severity != "none":
            summary_lines.append(
                f"{agent_name}: severity={severity} verified={verified or 'unknown'} installed={installed or 'unknown'} upstream={upstream or 'unknown'} rec={recommendation}"
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
