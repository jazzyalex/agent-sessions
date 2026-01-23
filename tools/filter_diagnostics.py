#!/usr/bin/env python3
"""
Filter diagnostics (dry-run) for Agent Sessions.

Purpose:
  - Explain why sessions are "hidden by filters" using the same preference keys
    the app uses (HideZeroMessageSessions, HideLowMessageSessions, ShowHousekeepingSessions,
    UnifiedHasCommandsOnly, ShowSystemProbeSessions).
  - Produce a small confusion-matrix style summary + a few examples per bucket.

Safety:
  - Read-only.
  - Does not enumerate $HOME broadly; it only reads:
      - ~/Library/Application Support/AgentSessions/index.db (if present)
      - ~/Library/Preferences/com.triada.AgentSessions.plist (if present)
      - Known agent roots for optional file-count sanity checks.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import sqlite3
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


BUNDLE_ID = "com.triada.AgentSessions"

# Preference keys (must match PreferencesConstants.swift)
KEY_HIDE_ZERO = "HideZeroMessageSessions"
KEY_HIDE_LOW = "HideLowMessageSessions"
KEY_SHOW_HOUSEKEEPING = "ShowHousekeepingSessions"
KEY_HAS_COMMANDS_ONLY = "UnifiedHasCommandsOnly"
KEY_SHOW_SYSTEM_PROBES = "ShowSystemProbeSessions"


@dataclass(frozen=True)
class Prefs:
    hide_zero: bool
    hide_low: bool
    show_housekeeping: bool
    has_commands_only: bool
    show_system_probes: bool


@dataclass(frozen=True)
class Row:
    session_id: str
    source: str
    path: str
    title: str
    is_housekeeping: bool
    messages: int
    commands: int


def read_prefs() -> Prefs:
    plist_path = Path.home() / "Library" / "Preferences" / f"{BUNDLE_ID}.plist"
    data = {}
    if plist_path.exists():
        try:
            with plist_path.open("rb") as f:
                data = plistlib.load(f) or {}
        except Exception:
            data = {}

    def b(key: str, default: bool) -> bool:
        if key not in data:
            return default
        v = data.get(key)
        if isinstance(v, bool):
            return v
        if isinstance(v, int):
            return bool(v)
        return default

    # Defaults mirror the app’s @AppStorage defaults and the "nil means true" logic where applicable.
    return Prefs(
        hide_zero=b(KEY_HIDE_ZERO, True),
        hide_low=b(KEY_HIDE_LOW, True),
        show_housekeeping=b(KEY_SHOW_HOUSEKEEPING, False),
        has_commands_only=b(KEY_HAS_COMMANDS_ONLY, False),
        show_system_probes=b(KEY_SHOW_SYSTEM_PROBES, False),
    )


def index_db_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "AgentSessions" / "index.db"


def fetch_session_meta(db_path: Path) -> list[Row]:
    con = sqlite3.connect(str(db_path))
    try:
        cur = con.cursor()
        cur.execute(
            """
            SELECT
              session_id,
              source,
              path,
              COALESCE(title, ''),
              COALESCE(is_housekeeping, 0),
              COALESCE(messages, 0),
              COALESCE(commands, 0)
            FROM session_meta
            """
        )
        rows: list[Row] = []
        for session_id, source, path, title, is_housekeeping, messages, commands in cur.fetchall():
            rows.append(
                Row(
                    session_id=str(session_id),
                    source=str(source),
                    path=str(path),
                    title=str(title),
                    is_housekeeping=bool(is_housekeeping),
                    messages=int(messages) if messages is not None else 0,
                    commands=int(commands) if commands is not None else 0,
                )
            )
        return rows
    finally:
        con.close()


def optional_disk_counts() -> dict[str, int]:
    """
    Best-effort sanity check: how many session files exist on disk per source root.
    This is not authoritative for filtering (that comes from index.db).
    """
    counts: dict[str, int] = {}

    codex_root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
    codex_sessions = codex_root / "sessions"
    if codex_sessions.exists():
        counts["codex"] = sum(1 for _ in codex_sessions.rglob("rollout-*.jsonl"))

    claude_projects = Path.home() / ".claude" / "projects"
    if claude_projects.exists():
        counts["claude"] = sum(1 for p in claude_projects.rglob("*") if p.is_file() and p.suffix.lower() in {".jsonl", ".ndjson"})

    gemini_root = Path.home() / ".gemini" / "tmp"
    if gemini_root.exists():
        counts["gemini"] = sum(1 for _ in gemini_root.rglob("session-*.json"))

    opencode_root = Path.home() / ".opencode"
    if opencode_root.exists():
        counts["opencode"] = sum(1 for p in opencode_root.rglob("*") if p.is_file() and p.suffix.lower() in {".jsonl", ".ndjson", ".json"})

    copilot_root = Path.home() / ".copilot" / "session-state"
    if copilot_root.exists():
        counts["copilot"] = sum(1 for _ in copilot_root.rglob("*.jsonl"))

    droid_root = Path.home() / ".droid" / "sessions"
    if droid_root.exists():
        counts["droid"] = sum(1 for p in droid_root.rglob("*") if p.is_file() and p.suffix.lower() in {".jsonl", ".ndjson", ".json"})

    return counts


def classify_hidden_reasons(row: Row, prefs: Prefs) -> set[str]:
    """
    Compute which filters would hide this session (independently, like a confusion matrix).
    Note: The app applies probe hiding upstream in source-specific indexers. In the DB snapshot,
    probe rows may exist, so we treat "probe" as a possible reason here.
    """
    reasons: set[str] = set()

    # Housekeeping
    if (not prefs.show_housekeeping) and row.is_housekeeping:
        reasons.add("housekeeping")

    # Message count filtering (UnifiedSessionIndexer exceptions: OpenCode not filtered by msg-count)
    if row.source != "opencode":
        if prefs.hide_zero and row.messages <= 0:
            reasons.add("zero_msgs")
        if prefs.hide_low and 0 < row.messages <= 2:
            reasons.add("low_msgs")

    # Strict tool-call-only filter:
    # For Codex/OpenCode/Copilot/Droid, the app will accept lightweight commands count.
    # For Claude/Gemini, the app requires parsed tool_call events; DB rows are "lightweight",
    # so this filter is effectively "hide all Claude/Gemini" when ON.
    if prefs.has_commands_only:
        if row.source in {"codex", "opencode", "copilot", "droid"}:
            if row.commands <= 0:
                reasons.add("no_tool_calls")
        elif row.source in {"claude", "gemini"}:
            reasons.add("no_tool_calls")

    # Probe hiding is upstream in live indexers; DB snapshot may still include them.
    # We cannot reliably detect probes from DB alone (depends on per-source rules), so we only
    # note the preference state for context rather than labeling rows as probes.
    return reasons


def print_prefs(p: Prefs) -> None:
    print("Preferences (effective):")
    print(f"  - {KEY_HIDE_ZERO} = {p.hide_zero}")
    print(f"  - {KEY_HIDE_LOW} = {p.hide_low}")
    print(f"  - {KEY_SHOW_HOUSEKEEPING} = {p.show_housekeeping}")
    print(f"  - {KEY_HAS_COMMANDS_ONLY} = {p.has_commands_only}")
    print(f"  - {KEY_SHOW_SYSTEM_PROBES} = {p.show_system_probes}")


def summarize(rows: Iterable[Row], prefs: Prefs, max_examples: int) -> None:
    rows = list(rows)
    total = len(rows)

    by_source: dict[str, list[Row]] = defaultdict(list)
    for r in rows:
        by_source[r.source].append(r)

    print("\nIndex DB summary (session_meta):")
    for source in sorted(by_source.keys()):
        print(f"  - {source}: {len(by_source[source])}")
    print(f"  - total: {total}")

    # Confusion-matrix buckets
    reason_counts: dict[str, int] = defaultdict(int)
    visible: list[Row] = []
    hidden: list[tuple[Row, set[str]]] = []

    for r in rows:
        reasons = classify_hidden_reasons(r, prefs)
        if not reasons:
            visible.append(r)
        else:
            hidden.append((r, reasons))
            for reason in reasons:
                reason_counts[reason] += 1

    print("\nVisibility (based on preferences):")
    print(f"  - visible: {len(visible)}")
    print(f"  - hidden:  {len(hidden)}")

    if total > 0:
        pct = 100.0 * len(hidden) / total
        print(f"  - hidden_pct: {pct:.1f}%")

    print("\nHidden-by-reason (not mutually exclusive):")
    for reason in sorted(reason_counts.keys()):
        print(f"  - {reason}: {reason_counts[reason]}")

    # Examples: show sessions hidden for exactly one reason (helps spot surprises)
    buckets: dict[str, list[Row]] = defaultdict(list)
    multi: list[Row] = []
    for r, reasons in hidden:
        if len(reasons) == 1:
            buckets[next(iter(reasons))].append(r)
        else:
            multi.append(r)

    def print_examples(label: str, items: list[Row]) -> None:
        if not items:
            return
        print(f"\nExamples: {label} (up to {max_examples})")
        for r in items[:max_examples]:
            title = (r.title or "").strip()
            title = title if title else "(empty title)"
            print(f"  - {r.source} msgs={r.messages} cmds={r.commands} hk={int(r.is_housekeeping)} :: {title} :: {Path(r.path).name}")

    for reason in ["housekeeping", "zero_msgs", "low_msgs", "no_tool_calls"]:
        print_examples(reason, buckets.get(reason, []))

    if multi:
        print_examples("multiple reasons", multi)

    # Suspicion heuristics: housekeeping sessions with lots of messages or commands
    suspicious = [
        r
        for r, reasons in hidden
        if ("housekeeping" in reasons) and (r.messages >= 6 or r.commands >= 1)
    ]
    if suspicious:
        suspicious.sort(key=lambda rr: (rr.commands, rr.messages), reverse=True)
        print(f"\nSuspicious housekeeping (hk=1 but msgs>=6 or cmds>=1): {len(suspicious)} (up to {max_examples})")
        for r in suspicious[:max_examples]:
            title = (r.title or "").strip()
            title = title if title else "(empty title)"
            print(f"  - {r.source} msgs={r.messages} cmds={r.commands} :: {title} :: {r.path}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Dry-run diagnostics for Agent Sessions filtering.")
    ap.add_argument("--max-examples", type=int, default=8, help="Max examples printed per bucket.")
    ap.add_argument("--no-disk-counts", action="store_true", help="Skip optional on-disk file-count sanity checks.")
    ap.add_argument("--matrix", action="store_true", help="Print a small visibility matrix for HideZero/HideLow combinations.")
    ap.add_argument("--hide-zero", dest="hide_zero", action="store_true", default=None, help="Override: hide 0-message sessions.")
    ap.add_argument("--show-zero", dest="hide_zero", action="store_false", default=None, help="Override: show 0-message sessions.")
    ap.add_argument("--hide-low", dest="hide_low", action="store_true", default=None, help="Override: hide 1–2 message sessions.")
    ap.add_argument("--show-low", dest="hide_low", action="store_false", default=None, help="Override: show 1–2 message sessions.")
    ap.add_argument("--show-housekeeping", dest="show_housekeeping", action="store_true", default=None, help="Override: include housekeeping-only sessions.")
    ap.add_argument("--hide-housekeeping", dest="show_housekeeping", action="store_false", default=None, help="Override: hide housekeeping-only sessions.")
    ap.add_argument("--tool-calls-only", dest="has_commands_only", action="store_true", default=None, help="Override: require tool calls (strict).")
    ap.add_argument("--allow-no-tool-calls", dest="has_commands_only", action="store_false", default=None, help="Override: do not require tool calls.")
    ap.add_argument("--show-probes", dest="show_system_probes", action="store_true", default=None, help="Override: include probe sessions.")
    ap.add_argument("--hide-probes", dest="show_system_probes", action="store_false", default=None, help="Override: hide probe sessions.")
    args = ap.parse_args()

    base = read_prefs()
    prefs = Prefs(
        hide_zero=base.hide_zero if args.hide_zero is None else bool(args.hide_zero),
        hide_low=base.hide_low if args.hide_low is None else bool(args.hide_low),
        show_housekeeping=base.show_housekeeping if args.show_housekeeping is None else bool(args.show_housekeeping),
        has_commands_only=base.has_commands_only if args.has_commands_only is None else bool(args.has_commands_only),
        show_system_probes=base.show_system_probes if args.show_system_probes is None else bool(args.show_system_probes),
    )
    print_prefs(prefs)

    db_path = index_db_path()
    if not db_path.exists():
        print(f"\n[ERROR] index.db not found: {db_path}")
        print("Open the app once to build the index, then re-run this tool.")
        return 2

    rows = fetch_session_meta(db_path)
    if not rows:
        print(f"\n[WARN] session_meta is empty: {db_path}")
        return 0

    if not args.no_disk_counts:
        disk = optional_disk_counts()
        if disk:
            print("\nOn-disk session file counts (best-effort):")
            for k in sorted(disk.keys()):
                print(f"  - {k}: {disk[k]}")

    summarize(rows, prefs, max_examples=max(1, args.max_examples))

    if args.matrix:
        print("\nVisibility matrix (HideZero x HideLow):")
        combos = [
            (False, False),
            (True, False),
            (False, True),
            (True, True),
        ]
        for hz, hl in combos:
            p = Prefs(
                hide_zero=hz,
                hide_low=hl,
                show_housekeeping=prefs.show_housekeeping,
                has_commands_only=prefs.has_commands_only,
                show_system_probes=prefs.show_system_probes,
            )
            total = len(rows)
            hidden = 0
            for r in rows:
                if classify_hidden_reasons(r, p):
                    hidden += 1
            visible = total - hidden
            print(f"  - hideZero={hz} hideLow={hl} -> visible={visible} hidden={hidden}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
