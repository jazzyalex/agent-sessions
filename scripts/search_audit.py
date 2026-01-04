#!/usr/bin/env python3
"""
Audit Instant vs Deep search coverage using the local AgentSessions index.db.

This script compares:
  - Instant: whether the query appears in `session_search.text` (what FTS indexes)
  - Raw file: whether the query appears inside text-like fields vs tool-output-like fields

It helps explain "Instant missed but Deep found" (tool output) vs true indexing gaps (message text).
"""

import argparse
import json
import os
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


TEXT_KEYS = {
    "text",
    "content",
    "message",
    "summary",
    "title",
}

TOOL_OUTPUT_KEYS = {
    "stdout",
    "stderr",
    "result",
    "output",
    "toolOutput",
    "tool_output",
}


@dataclass(frozen=True)
class SessionRow:
    session_id: str
    source: str
    path: str
    mtime: Optional[int]
    size: Optional[int]


@dataclass(frozen=True)
class RawMatch:
    any_hit: bool
    text_hit: bool
    tool_hit: bool


def default_db_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "AgentSessions" / "index.db"


def open_db(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=? LIMIT 1",
        (name,),
    ).fetchone()
    return row is not None


def fetch_sessions(
    conn: sqlite3.Connection,
    sources: Optional[Sequence[str]],
    limit: int,
) -> List[SessionRow]:
    where = ""
    params: List[Any] = []
    if sources:
        where = f"WHERE source IN ({','.join(['?'] * len(sources))})"
        params.extend(list(sources))

    rows = conn.execute(
        f"""
        SELECT session_id, source, path, mtime, size
        FROM session_meta
        {where}
        ORDER BY COALESCE(mtime, 0) DESC
        LIMIT ?
        """,
        (*params, limit),
    ).fetchall()
    return [
        SessionRow(
            session_id=r["session_id"],
            source=r["source"],
            path=r["path"],
            mtime=r["mtime"],
            size=r["size"],
        )
        for r in rows
    ]


def fetch_session_search_text(conn: sqlite3.Connection, session_id: str) -> Optional[str]:
    row = conn.execute(
        "SELECT text FROM session_search WHERE session_id=? LIMIT 1",
        (session_id,),
    ).fetchone()
    if not row:
        return None
    return row["text"]


def fts_hit_set(conn: sqlite3.Connection, query: str, sources: Optional[Sequence[str]]) -> Optional[set]:
    if not table_exists(conn, "session_search_fts"):
        return None

    where = ""
    params: List[Any] = [query]
    if sources:
        where = f"AND session_search.source IN ({','.join(['?'] * len(sources))})"
        params.extend(list(sources))

    rows = conn.execute(
        f"""
        SELECT session_search.session_id AS session_id
        FROM session_search_fts
        JOIN session_search ON session_search_fts.rowid = session_search.rowid
        WHERE session_search_fts MATCH ?
        {where}
        """,
        tuple(params),
    ).fetchall()
    return {r["session_id"] for r in rows}


def _value_to_searchable_string(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float, bool)):
        return str(v)
    try:
        return json.dumps(v, ensure_ascii=False, sort_keys=True)
    except Exception:
        return str(v)


def _scan_json_obj(obj: Any, q: str) -> RawMatch:
    ql = q.lower()
    text_hit = False
    tool_hit = False

    stack: List[Any] = [obj]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            for k, v in cur.items():
                if isinstance(v, (dict, list)):
                    stack.append(v)
                    continue
                if not isinstance(k, str):
                    continue
                sval = _value_to_searchable_string(v)
                if not sval:
                    continue
                if ql not in sval.lower():
                    continue
                if k in TOOL_OUTPUT_KEYS:
                    tool_hit = True
                if k in TEXT_KEYS:
                    text_hit = True
                if tool_hit and text_hit:
                    return RawMatch(any_hit=True, text_hit=True, tool_hit=True)
        elif isinstance(cur, list):
            for v in cur:
                if isinstance(v, (dict, list)):
                    stack.append(v)
    return RawMatch(any_hit=(text_hit or tool_hit), text_hit=text_hit, tool_hit=tool_hit)


def scan_raw_file(path: Path, query: str) -> RawMatch:
    if not path.exists():
        return RawMatch(any_hit=False, text_hit=False, tool_hit=False)

    suffix = path.suffix.lower()
    if suffix == ".jsonl":
        try:
            with path.open("r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    m = _scan_json_obj(obj, query)
                    if m.any_hit:
                        return m
        except Exception:
            return RawMatch(any_hit=False, text_hit=False, tool_hit=False)
        return RawMatch(any_hit=False, text_hit=False, tool_hit=False)

    if suffix == ".json":
        try:
            with path.open("r", encoding="utf-8", errors="replace") as f:
                obj = json.load(f)
            return _scan_json_obj(obj, query)
        except Exception:
            return RawMatch(any_hit=False, text_hit=False, tool_hit=False)

    # Unknown formats: best-effort string scan only.
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return RawMatch(any_hit=False, text_hit=False, tool_hit=False)
    return RawMatch(any_hit=(query.lower() in raw.lower()), text_hit=False, tool_hit=False)


def bucket_name(instant_hit: bool, raw: RawMatch) -> str:
    if instant_hit and raw.any_hit:
        return "both_hit"
    if instant_hit and not raw.any_hit:
        return "instant_only (stale index / non-text match)"
    if not instant_hit and raw.tool_hit:
        return "raw_tool_only (Deep Search should find)"
    if not instant_hit and raw.text_hit:
        return "raw_text_only (Instant indexing gap)"
    if not instant_hit and raw.any_hit:
        return "raw_other_only (unknown keys)"
    return "miss"


def main() -> int:
    ap = argparse.ArgumentParser(description="Audit Instant vs Deep search coverage.")
    ap.add_argument("query", help="Search term (single token works best for FTS audit).")
    ap.add_argument("--db", default=str(default_db_path()), help="Path to index.db.")
    ap.add_argument(
        "--sources",
        default="codex,claude,gemini,opencode,copilot,droid",
        help="Comma-separated sources to include.",
    )
    ap.add_argument("--limit", type=int, default=250, help="Max sessions to scan (newest-first).")
    ap.add_argument("--samples", type=int, default=3, help="Sample paths per bucket.")
    args = ap.parse_args()

    db_path = Path(args.db).expanduser()
    if not db_path.exists():
        raise SystemExit(f"index.db not found at {db_path}")

    sources = [s.strip() for s in args.sources.split(",") if s.strip()]
    conn = open_db(db_path)
    try:
        sessions = fetch_sessions(conn, sources=sources, limit=args.limit)
        fts_hits = fts_hit_set(conn, args.query, sources=sources)
        if fts_hits is None:
            print("[note] session_search_fts not present; using substring checks only.")

        buckets: Dict[str, List[Tuple[SessionRow, str]]] = {}
        instant_hits = 0
        for s in sessions:
            text = fetch_session_search_text(conn, s.session_id) or ""
            instant_hit = args.query.lower() in text.lower()
            if fts_hits is not None:
                instant_hit = instant_hit or (s.session_id in fts_hits)
            if instant_hit:
                instant_hits += 1

            raw = scan_raw_file(Path(s.path), args.query)
            b = bucket_name(instant_hit, raw)
            buckets.setdefault(b, []).append((s, s.path))

        total = len(sessions)
        print(f"Query: {args.query!r}")
        print(f"Sessions scanned: {total}")
        print(f"Instant hits (substring/FTS): {instant_hits}")
        print("")
        print("Buckets:")
        for name in sorted(buckets.keys(), key=lambda k: (-len(buckets[k]), k)):
            print(f"  - {name}: {len(buckets[name])}")

        print("")
        for name in sorted(buckets.keys(), key=lambda k: (-len(buckets[k]), k)):
            rows = buckets[name]
            if not rows:
                continue
            print(f"[{name}]")
            for s, p in rows[: args.samples]:
                print(f"  - {s.source}: {s.session_id}  {p}")
            if len(rows) > args.samples:
                print(f"  … +{len(rows) - args.samples} more")
            print("")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

