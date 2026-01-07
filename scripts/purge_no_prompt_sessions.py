#!/usr/bin/env python3
"""
Purge sessions that show up as "No prompt" in AgentSessions.

These are typically agent-CLI housekeeping transcripts (no assistant messages),
e.g. Codex rollout logs that only captured session_meta/preamble, or Claude
local-command-only logs (/usage, /model, etc.).

Safety rules (enforced):
- Dry-run by default.
- Two-signal match required for purge:
  1) index.db says title == "No prompt"
  2) parsed JSONL contains no assistant messages
- Restricts files to known agent roots (~/.codex/sessions and ~/.claude/projects).
- Requires --execute and a --confirm string that includes the exact count.
- Moves to a quarantine folder by default (recommended); hard delete requires
  --hard-delete.
- Writes a timestamped manifest under scripts/probe_scan_output/purge_no_prompt_sessions/.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


def _now_utc_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _read_jsonl(path: Path) -> Iterable[dict]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except OSError:
        return


def _has_any_assistant_codex(path: Path) -> bool:
    for obj in _read_jsonl(path):
        t = obj.get("type")
        if t == "response_item":
            payload = obj.get("payload") or {}
            if payload.get("type") == "message" and payload.get("role") == "assistant":
                return True
        if t == "event_msg":
            payload = obj.get("payload") or {}
            if payload.get("role") == "assistant":
                return True
    return False


def _has_any_assistant_claude(path: Path) -> bool:
    for obj in _read_jsonl(path):
        if obj.get("type") == "assistant":
            return True
    return False


def _sample(items: list, k: int) -> list:
    if not items:
        return []
    if len(items) <= k:
        return items
    return random.sample(items, k)


def _write_manifest(out_dir: Path, manifest: dict) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


@dataclass(frozen=True)
class Row:
    session_id: str
    source: str
    path: Path
    title: str


@dataclass(frozen=True)
class Candidate:
    row: Row
    root_ok: bool
    no_assistant: bool
    exists: bool


def _index_db_path(arg: str) -> Path:
    return Path(os.path.expandvars(arg)).expanduser()


def _query_no_prompt_rows(db_path: Path, include_blank: bool) -> list[Row]:
    if not db_path.exists():
        raise SystemExit(f"index.db not found: {db_path}")

    con = sqlite3.connect(str(db_path))
    try:
        cur = con.cursor()
        if include_blank:
            sql = (
                "SELECT session_id, source, path, title "
                "FROM session_meta "
                "WHERE title='No prompt' OR title IS NULL OR trim(title)=''"
            )
        else:
            sql = "SELECT session_id, source, path, title FROM session_meta WHERE title='No prompt'"
        rows = cur.execute(sql).fetchall()
        out: list[Row] = []
        for session_id, source, path, title in rows:
            if not isinstance(session_id, str) or not isinstance(source, str) or not isinstance(path, str):
                continue
            if title is None:
                title = ""
            out.append(Row(session_id=session_id, source=source, path=Path(path), title=str(title)))
        return out
    finally:
        con.close()


def _allowed_roots() -> dict[str, Path]:
    home = Path.home()
    return {
        "codex": (home / ".codex" / "sessions").resolve(),
        "claude": (home / ".claude" / "projects").resolve(),
    }


def _is_under(path: Path, root: Path) -> bool:
    try:
        path = path.resolve()
    except OSError:
        return False
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _collect_candidates(rows: list[Row]) -> tuple[list[Candidate], dict[str, int]]:
    roots = _allowed_roots()
    counts: dict[str, int] = {"unknown_source": 0, "missing": 0, "outside_root": 0, "has_assistant": 0}
    candidates: list[Candidate] = []

    for row in rows:
        allowed_root = roots.get(row.source)
        if allowed_root is None:
            counts["unknown_source"] += 1
            continue

        exists = row.path.exists()
        if not exists:
            counts["missing"] += 1
            candidates.append(Candidate(row=row, root_ok=False, no_assistant=False, exists=False))
            continue

        root_ok = _is_under(row.path, allowed_root)
        if not root_ok:
            counts["outside_root"] += 1
            candidates.append(Candidate(row=row, root_ok=False, no_assistant=False, exists=True))
            continue

        if row.source == "codex":
            has_assistant = _has_any_assistant_codex(row.path)
        else:
            has_assistant = _has_any_assistant_claude(row.path)

        if has_assistant:
            counts["has_assistant"] += 1
        candidates.append(Candidate(row=row, root_ok=True, no_assistant=(not has_assistant), exists=True))

    return candidates, counts


def _default_quarantine_root() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "AgentSessions"
        / "Archives"
        / "purged-no-prompt"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--db",
        default=str(Path.home() / "Library" / "Application Support" / "AgentSessions" / "index.db"),
        help="Path to AgentSessions index.db (default: ~/Library/Application Support/AgentSessions/index.db).",
    )
    parser.add_argument(
        "--include-blank",
        action="store_true",
        help='Also match blank/null titles (in addition to exact "No prompt").',
    )
    parser.add_argument("--execute", action="store_true", help="Actually purge matched session files.")
    parser.add_argument(
        "--confirm",
        default="",
        help='Confirmation string that must equal "delete <N> sessions" for the computed N.',
    )
    parser.add_argument(
        "--quarantine-root",
        default=str(_default_quarantine_root()),
        help="Where to quarantine moved sessions (default: AgentSessions/Archives/purged-no-prompt).",
    )
    parser.add_argument(
        "--hard-delete",
        action="store_true",
        help="Hard delete instead of quarantining (requires a second explicit run).",
    )
    args = parser.parse_args(argv)

    db_path = _index_db_path(args.db)
    rows = _query_no_prompt_rows(db_path, include_blank=bool(args.include_blank))
    candidates, skipped_counts = _collect_candidates(rows)

    eligible = [c for c in candidates if c.exists and c.root_ok and c.no_assistant]
    skipped = [c for c in candidates if c not in eligible]

    by_source: dict[str, int] = {}
    for c in eligible:
        by_source[c.row.source] = by_source.get(c.row.source, 0) + 1

    out_dir = Path("scripts") / "probe_scan_output" / "purge_no_prompt_sessions" / _now_utc_slug()
    manifest = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "db": str(db_path),
        "include_blank": bool(args.include_blank),
        "mode": "execute" if args.execute else "dry_run",
        "hard_delete": bool(args.hard_delete),
        "counts": {
            "rows_from_db": len(rows),
            "eligible": len(eligible),
            "skipped": len(skipped),
            "eligible_by_source": by_source,
            "skipped_breakdown": skipped_counts,
        },
        "samples": {
            "eligible_paths": [str(c.row.path) for c in _sample(eligible, 20)],
            "skipped_paths": [str(c.row.path) for c in _sample(skipped, 10)],
        },
        "eligible": [
            {"source": c.row.source, "session_id": c.row.session_id, "path": str(c.row.path), "title": c.row.title}
            for c in eligible
        ],
    }
    manifest_path = _write_manifest(out_dir, manifest)

    print(f"DB: {db_path}")
    print(f"Mode: {'execute' if args.execute else 'dry-run'}")
    print(f"Match: title == 'No prompt'{' OR blank/null' if args.include_blank else ''}")
    print(f"Eligible (two-signal, safe): {len(eligible)}  by_source={by_source}")
    print(f"Skipped: {len(skipped)}  breakdown={skipped_counts}")
    if manifest["samples"]["eligible_paths"]:
        print("Eligible sample (up to 20):")
        for p in manifest["samples"]["eligible_paths"]:
            print(f"  {p}")
    if manifest["samples"]["skipped_paths"]:
        print("Skipped sample (up to 10):")
        for p in manifest["samples"]["skipped_paths"]:
            print(f"  {p}")
    print(f"Manifest: {manifest_path}")

    if not args.execute:
        print("Dry-run only. To execute, pass --execute and --confirm \"delete <N> sessions\".")
        return 0

    expected = f"delete {len(eligible)} sessions"
    if args.confirm.strip() != expected:
        print(f"Refusing to execute: --confirm must be exactly: {expected!r}", file=os.sys.stderr)
        return 2

    if not eligible:
        print("Nothing eligible to purge.")
        return 0

    if args.hard_delete:
        # We intentionally require the user/agent to do a second explicit run for hard delete.
        for c in eligible:
            try:
                c.row.path.unlink()
            except OSError as exc:
                print(f"Failed to delete {c.row.path}: {exc}", file=os.sys.stderr)
        print(f"Hard-deleted {len(eligible)} session files.")
        return 0

    quarantine_root = Path(os.path.expandvars(args.quarantine_root)).expanduser().resolve()
    quarantine_dir = quarantine_root / out_dir.name
    quarantine_dir.mkdir(parents=True, exist_ok=True)

    roots = _allowed_roots()
    for c in eligible:
        src_root = roots[c.row.source]
        rel = c.row.path.resolve().relative_to(src_root)
        dst = quarantine_dir / c.row.source / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.move(str(c.row.path), str(dst))
        except OSError as exc:
            print(f"Failed to move {c.row.path}: {exc}", file=os.sys.stderr)
    print(f"Moved {len(eligible)} session files to quarantine: {quarantine_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))

