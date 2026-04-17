#!/usr/bin/env python3
"""
Capture the most recently modified local agent session artifacts into a repo-local folder.

This is intended for "auto mode" evidence collection when upstream session formats drift:
- Gemini: copy the newest `session-*.json` from `~/.gemini/tmp/**/(chats/)?`.
- OpenCode: copy the newest `ses_*.json` plus the referenced message/part trees from
  `~/.local/share/opencode/storage/**`.
- OpenClaw: copy the newest `*.jsonl` under OpenClaw/clawdbot session roots:
  `$OPENCLAW_STATE_DIR/agents/*/sessions/` (or `~/.openclaw` / `~/.clawdbot`).

It does not modify or delete any source files.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
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
    opencode_root = Path.home() / ".local" / "share" / "opencode"
    db_path = opencode_root / "opencode.db"
    if db_path.exists():
        out_root = dest_root / "opencode"
        out_db = out_root / "opencode.db"
        _safe_copy(db_path, out_db)
        results: list[CaptureResult] = [CaptureResult(agent="opencode", source=db_path, destination=out_db)]
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(db_path) + suffix)
            if sidecar.exists():
                dst = out_root / sidecar.name
                _safe_copy(sidecar, dst)
                results.append(CaptureResult(agent="opencode", source=sidecar, destination=dst))

        # Write a small JSON evidence export for review without opening the DB.
        export_path = out_root / "latest_session_export.json"
        try:
            export_path.parent.mkdir(parents=True, exist_ok=True)
            export_path.write_text(json.dumps(_export_latest_opencode_sqlite_session(db_path), indent=2), encoding="utf-8")
            results.append(CaptureResult(agent="opencode", source=db_path, destination=export_path))
        except Exception:
            pass
        return results

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


def _export_latest_opencode_sqlite_session(db_path: Path) -> dict:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            """
            SELECT id, project_id, parent_id, slug, directory, title, version, time_created, time_updated
            FROM session
            WHERE time_archived IS NULL
            ORDER BY time_updated DESC
            LIMIT 1;
            """
        ).fetchone()
        if row is None:
            return {"backend": "sqlite", "db": str(db_path), "session": None, "messages": [], "parts": []}
        session_id = row["id"]
        messages = [
            {"id": r["id"], "session_id": r["session_id"], "data": json.loads(r["data"])}
            for r in conn.execute(
                "SELECT id, session_id, data FROM message WHERE session_id = ? ORDER BY time_created, id LIMIT 20;",
                (session_id,),
            )
        ]
        message_ids = [m["id"] for m in messages]
        parts = []
        for message_id in message_ids:
            for r in conn.execute(
                "SELECT id, message_id, session_id, data FROM part WHERE message_id = ? ORDER BY time_created, id LIMIT 50;",
                (message_id,),
            ):
                parts.append({"id": r["id"], "message_id": r["message_id"], "session_id": r["session_id"], "data": json.loads(r["data"])})
        return {
            "backend": "sqlite",
            "db": str(db_path),
            "session": dict(row),
            "messages": messages,
            "parts": parts,
        }
    finally:
        conn.close()


def _openclaw_root_candidates() -> list[Path]:
    candidates: list[Path] = []

    env_root = os.getenv("OPENCLAW_STATE_DIR")
    if env_root:
        candidates.append(Path(env_root).expanduser())

    home = Path.home()
    candidates.append(home / ".openclaw")
    candidates.append(home / ".clawdbot")
    return candidates


def _iter_openclaw_session_files() -> list[Path]:
    out: list[Path] = []
    for candidate in _openclaw_root_candidates():
        if not candidate.exists():
            continue

        agent_root = candidate / "agents"
        scan_roots = [agent_root] if agent_root.exists() else [candidate]
        for scan_root in scan_roots:
            if not scan_root.exists():
                continue
            for p in scan_root.rglob("*.jsonl"):
                if p.name.endswith(".jsonl.lock"):
                    continue
                if ".jsonl.deleted." in p.name:
                    continue
                if ".jsonl.reset." in p.name:
                    continue
                if p.suffix != ".jsonl":
                    continue
                if "sessions" not in p.parts:
                    continue
                # Swift-side discovery enumerates only the flat `sessions/` directory
                # (no subdirectory descent). Mirror that here so the weekly probe
                # never picks up reset/backup snapshots the viewer cannot see.
                try:
                    sessions_idx = len(p.parts) - 1 - list(reversed(p.parts)).index("sessions")
                except ValueError:
                    continue
                if len(p.parts) - sessions_idx != 2:
                    continue
                out.append(p)
    return sorted(out, key=lambda p: p.stat().st_mtime if p.exists() else 0.0, reverse=True)


def capture_openclaw(dest_root: Path) -> list[CaptureResult]:
    candidates = _iter_openclaw_session_files()
    if not candidates:
        return []

    src = _newest(candidates)
    if src is None:
        return []

    # Preserve relative `agents/<agentId>/sessions/...` paths when possible.
    rel = Path(src.name)
    if "agents" in src.parts:
        parts = list(src.parts)
        try:
            idx = parts.index("agents")
            if idx + 1 < len(parts):
                rel = Path(*parts[idx:])
        except ValueError:
            rel = Path(src.name)

    dst = dest_root / "openclaw" / rel
    _safe_copy(src, dst)
    return [CaptureResult(agent="openclaw", source=src, destination=dst)]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--agent",
        action="append",
        choices=["gemini", "opencode", "openclaw"],
        help="Agent(s) to capture (default: all supported local agents).",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output directory (default: scripts/agent_captures/<UTC timestamp>/).",
    )
    args = parser.parse_args(argv)

    agents = args.agent or ["gemini", "opencode", "openclaw"]
    out = Path(args.out) if args.out else Path("scripts") / "agent_captures" / _now_utc_slug()
    out.mkdir(parents=True, exist_ok=True)

    # Record local CLI versions (best-effort; these do not necessarily appear in session JSON).
    versions = {
        "gemini": _try_version(["gemini", "--version"]) or _try_version(["gemini", "-v"]),
        "opencode": _try_version(["opencode", "--version"]) or _try_version(["opencode", "-v"]),
        "openclaw": _try_version(["openclaw", "--version"]) or _try_version(["openclaw", "-v"]),
    }
    (out / "versions.json").write_text(json.dumps(versions, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    captured: list[CaptureResult] = []
    if "gemini" in agents:
        captured.extend(capture_gemini(out))
    if "opencode" in agents:
        captured.extend(capture_opencode(out))
    if "openclaw" in agents:
        captured.extend(capture_openclaw(out))

    if not captured:
        # Empty capture is benign: the user simply has no live sessions for any
        # selected agent on this host (e.g. all OpenClaw sessions were reset or
        # deleted, leaving only `backup/` and `.jsonl.reset.*` snapshots which
        # the Swift-side discovery correctly ignores). Treat this as a successful
        # run that yielded no samples; monitoring can notice the empty list and
        # fall back to fixture baselines without escalating severity.
        print("No live sessions captured (no matching files found).", file=sys.stderr)
        print("(Versions recorded; no session files copied.)")
        print(f"Versions: {out / 'versions.json'}")
        return 0

    for item in captured:
        print(f"{item.agent}: {item.source} -> {item.destination}")
    print(f"Versions: {out / 'versions.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
