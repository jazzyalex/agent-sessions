#!/usr/bin/env python3
"""
Capture the most recently modified Gemini/OpenCode session artifacts into a repo-local folder.

This is intended for "auto mode" evidence collection when upstream session formats drift:
- Gemini: copy the newest `session-*.json` from `~/.gemini/tmp/**/(chats/)?`.
- OpenCode: copy the newest `ses_*.json` plus the referenced message/part trees from
  `~/.local/share/opencode/storage/**`.

It does not modify or delete any source files.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class CaptureResult:
    agent: str
    source: Path
    destination: Path


def _now_utc_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _newest(paths: Iterable[Path]) -> Path | None:
    newest: Path | None = None
    newest_mtime: float = -1.0
    for p in paths:
        try:
            m = p.stat().st_mtime
        except OSError:
            continue
        if m > newest_mtime:
            newest_mtime = m
            newest = p
    return newest


def _safe_copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def _try_version(cmd: list[str]) -> str | None:
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    except OSError:
        return None
    out = (proc.stdout or "").strip()
    return out if out else None


def capture_gemini(dest_root: Path) -> list[CaptureResult]:
    gemini_root = Path.home() / ".gemini" / "tmp"
    if not gemini_root.exists():
        return []

    candidates = list(gemini_root.rglob("session-*.json"))
    if not candidates:
        return []

    # Prefer modern `.../<hash>/chats/session-*.json` when present.
    chats = [p for p in candidates if "chats" in p.parts]
    src = _newest(chats) or _newest(candidates)
    if src is None:
        return []

    out_dir = dest_root / "gemini"
    dst = out_dir / src.name
    _safe_copy(src, dst)
    return [CaptureResult(agent="gemini", source=src, destination=dst)]


def capture_opencode(dest_root: Path) -> list[CaptureResult]:
    storage_root = Path.home() / ".local" / "share" / "opencode" / "storage"
    sessions_root = storage_root / "session"
    if not sessions_root.exists():
        return []

    candidates = list(sessions_root.rglob("ses_*.json"))
    src = _newest(candidates)
    if src is None:
        return []

    try:
        session_obj = json.loads(src.read_text(encoding="utf-8"))
    except Exception:
        session_obj = {}
    session_id = session_obj.get("id") if isinstance(session_obj, dict) else None

    out_storage = dest_root / "opencode" / "storage"

    # Copy the session JSON at its relative storage path.
    dst_session = out_storage / src.relative_to(storage_root)
    _safe_copy(src, dst_session)

    results: list[CaptureResult] = [CaptureResult(agent="opencode", source=src, destination=dst_session)]

    # Copy migration file when present (indicates storage schema).
    migration = storage_root / "migration"
    if migration.exists():
        _safe_copy(migration, out_storage / "migration")

    if not session_id:
        return results

    # Copy all message records for this session.
    message_dir = storage_root / "message" / session_id
    if message_dir.exists():
        dst_message_dir = out_storage / "message" / session_id
        shutil.copytree(message_dir, dst_message_dir, dirs_exist_ok=True)

    # Copy part directories for each message referenced by the message records.
    if message_dir.exists():
        for msg_file in sorted(message_dir.glob("msg_*.json")):
            try:
                msg_obj = json.loads(msg_file.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(msg_obj, dict):
                continue
            mid = msg_obj.get("id")
            if not isinstance(mid, str) or not mid:
                continue
            part_dir = storage_root / "part" / mid
            if not part_dir.exists():
                continue
            dst_part_dir = out_storage / "part" / mid
            shutil.copytree(part_dir, dst_part_dir, dirs_exist_ok=True)

    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--agent",
        action="append",
        choices=["gemini", "opencode"],
        help="Agent(s) to capture (default: both).",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output directory (default: scripts/agent_captures/<UTC timestamp>/).",
    )
    args = parser.parse_args(argv)

    agents = args.agent or ["gemini", "opencode"]
    out = Path(args.out) if args.out else Path("scripts") / "agent_captures" / _now_utc_slug()
    out.mkdir(parents=True, exist_ok=True)

    # Record local CLI versions (best-effort; these do not necessarily appear in session JSON).
    versions = {
        "gemini": _try_version(["gemini", "--version"]) or _try_version(["gemini", "-v"]),
        "opencode": _try_version(["opencode", "--version"]) or _try_version(["opencode", "-v"]),
    }
    (out / "versions.json").write_text(json.dumps(versions, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    captured: list[CaptureResult] = []
    if "gemini" in agents:
        captured.extend(capture_gemini(out))
    if "opencode" in agents:
        captured.extend(capture_opencode(out))

    if not captured:
        print("No sessions captured (no matching files found).", file=sys.stderr)
        return 2

    for item in captured:
        print(f"{item.agent}: {item.source} -> {item.destination}")
    print(f"Versions: {out / 'versions.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

