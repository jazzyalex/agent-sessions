#!/usr/bin/env python3
"""Regenerate the Codex C6/C7 receipt from a PINNED artifact list.

The artifact set is fixed by filename (recorded in the receipt), never
re-selected by mtime — re-running against the same files must reproduce the
same counts. The raw artifacts are private (they live in the local Codex
session store); the receipt therefore pins identity (full SHA-256) and the
exact query so the observation is auditable the moment the artifacts are
shared or spot-checked.

Usage:
  python3 scripts/session_bench/receipt_codex_c6c7.py <rollout.jsonl>... > receipt.md
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


def count(path: Path) -> dict:
    """Structured counts only: record types and payload keys, never substring
    matches — conversation text that merely mentions a field name must not
    count as a structural record."""
    reasoning = with_summary = sub_agent = parent_thread = 0
    for raw in path.open(errors="replace"):
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        payload = obj.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        if payload.get("type") == "reasoning":
            reasoning += 1
            summary = payload.get("summary") or []
            if any(isinstance(x, dict) and x.get("type") == "summary_text"
                   and x.get("text") for x in summary):
                with_summary += 1
        if payload.get("type") == "sub_agent_activity":
            sub_agent += 1
        if "parent_thread_id" in payload:
            parent_thread += 1
    return {
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "reasoning": reasoning,
        "with_summary_text": with_summary,
        "sub_agent_activity_records": sub_agent,
        "parent_thread_id_key_records": parent_thread,
    }


def main(argv: list[str]) -> int:
    rows = [count(Path(p)) for p in argv]
    tot = {k: sum(r[k] for r in rows)
           for k in ("reasoning", "with_summary_text",
                     "sub_agent_activity_records", "parent_thread_id_key_records")}
    print("# Receipt: Codex C6/C7 verification (pinned artifact set, 2026-08-12)")
    print()
    print("Query: this script (`receipt_codex_c6c7.py`), verbatim — per line,")
    print("parse JSON; count payload.type=='reasoning' records and those whose")
    print("payload.summary contains a summary_text entry with non-empty text;")
    print("count records with payload.type=='sub_agent_activity' and records")
    print("whose payload carries a parent_thread_id KEY. Structured fields")
    print("only — text that merely mentions a field name does not count.")
    print()
    print("The artifact set is pinned by filename and full SHA-256. The raw")
    print("files are private local session data; identity and query are")
    print("published so the counts are auditable on inspection.")
    print()
    for r in rows:
        print(f"- `{r['file']}`")
        print(f"  sha256: `{r['sha256']}`")
        print(f"  reasoning {r['reasoning']}, with summary_text {r['with_summary_text']}, "
              f"sub_agent_activity records {r['sub_agent_activity_records']}, "
              f"parent_thread_id-keyed records {r['parent_thread_id_key_records']}")
    pct = 100 * tot["with_summary_text"] // max(tot["reasoning"], 1)
    print()
    print(f"Totals: reasoning records {tot['reasoning']:,}, with non-empty "
          f"summary_text {tot['with_summary_text']:,} ({pct}%), "
          f"sub_agent_activity records {tot['sub_agent_activity_records']}, "
          f"parent_thread_id-keyed records {tot['parent_thread_id_key_records']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
