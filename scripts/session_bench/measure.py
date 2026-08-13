#!/usr/bin/env python3
"""Session-Bench measurement extractor.

Given a session artifact, recompute the numbers the manifest records:
physical bytes, record count, largest single record, and (for JSONL) the
content-key share — strings under a published list of content-like keys as
a fraction of total bytes. This is the format-specific extractor layer
between raw artifacts and measurements-*.json; the v2 milestone is to feed
it automatically from harness execution.

Usage:
  python3 scripts/session_bench/measure.py <path.jsonl> [more paths...]
  python3 scripts/session_bench/measure.py --sqlite <db> --tables t1,t2 --json-col data

Content-key share uses the same key heuristic as the corpus study: UTF-8
bytes of string values under content-like keys (text/content/message/
thinking/output/result/value/summary/reasoning/stdout/markdown) over total
bytes. It counts work product AND any bookkeeping stored under those keys;
approximate by design, and the manifest cites it as such.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

CONTENT_KEYS = {"text", "content", "message", "thinking", "output", "result",
                "value", "summary", "reasoning", "stdout", "markdown"}


def content_bytes(o) -> int:
    total = 0
    if isinstance(o, dict):
        for k, v in o.items():
            if k in CONTENT_KEYS and isinstance(v, str):
                total += len(v.encode("utf-8"))
            else:
                total += content_bytes(v)
    elif isinstance(o, list):
        for v in o:
            total += content_bytes(v)
    return total


def measure_jsonl(path: Path) -> dict:
    raw = path.read_bytes()
    lines = [l for l in raw.split(b"\n") if l.strip()]
    cb = 0
    types: dict[str, int] = {}
    for l in lines:
        try:
            o = json.loads(l)
        except ValueError:
            continue
        cb += content_bytes(o)
        t = str(o.get("type") or o.get("role") or "?")
        types[t] = types.get(t, 0) + 1
    return {
        "path": str(path),
        "bytes": len(raw),
        "records": len(lines),
        "max_record_bytes": max((len(l) for l in lines), default=0),
        "content_bytes": cb,
        "content_share_pct": round(100.0 * cb / max(len(raw), 1), 1),
        "record_types": dict(sorted(types.items(), key=lambda kv: -kv[1])),
    }


def measure_sqlite(db: Path, tables: list[str], json_col: str) -> dict:
    # Read-only URI so inspecting an artifact can never create or alter
    # database files. Note mode=ro does not see uncheckpointed WAL rows;
    # for the row counts and maxima measured here that trade is correct
    # for an immutable measurement, and WAL size is reported separately.
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    out = {"path": str(db), "file_bytes": db.stat().st_size, "tables": {}}
    wal = db.with_name(db.name + "-wal")
    if wal.exists():
        out["wal_bytes"] = wal.stat().st_size
    for t in tables:
        rows = con.execute(
            f"SELECT COUNT(*), COALESCE(MAX(LENGTH(CAST({json_col} AS BLOB))),0),"
            f" COALESCE(SUM(LENGTH(CAST({json_col} AS BLOB))),0) FROM {t}").fetchone()
        out["tables"][t] = {"rows": rows[0], "max_row_bytes": rows[1], "total_row_bytes": rows[2]}
    con.close()
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--sqlite")
    ap.add_argument("--tables", default="")
    ap.add_argument("--json-col", default="data")
    args = ap.parse_args(argv)
    results = []
    for p in args.paths:
        results.append(measure_jsonl(Path(p)))
    if args.sqlite:
        tables = [t for t in args.tables.split(",") if t]
        results.append(measure_sqlite(Path(args.sqlite), tables, args.json_col))
    json.dump(results, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
