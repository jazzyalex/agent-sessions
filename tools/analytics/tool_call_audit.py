#!/usr/bin/env python3
import os
import sys
import json
import argparse
import math
from datetime import datetime, timedelta, timezone


def parse_args():
    p = argparse.ArgumentParser(description="Audit tool_call counts across date ranges using real session logs.")
    p.add_argument("--codex-root", default=os.path.join(os.path.expanduser("~"), ".codex", "sessions"), help="Codex sessions root (default: ~/.codex/sessions)")
    p.add_argument("--claude-root", default=os.path.join(os.path.expanduser("~"), ".claude"), help="Claude sessions root (default: ~/.claude)")
    p.add_argument("--days", nargs="*", type=int, default=[1, 7, 30, 90], help="List of day windows to compute (end is now)")
    p.add_argument("--max-files", type=int, default=0, help="Optional cap on number of files per source to scan (0 = all)")
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


TOOL_CALL_TYPES = {"tool_call", "tool-call", "toolcall", "tool_use", "tool-use", "function_call"}
TOOL_RESULT_TYPES = {"tool_result", "tool-result", "toolresult", "function_result"}


def decode_epoch_like(x):
    try:
        v = float(x)
    except Exception:
        return None
    # Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
    if v > 1e14:
        v = v / 1_000_000.0
    elif v > 1e11:
        v = v / 1_000.0
    try:
        return datetime.fromtimestamp(v, tz=timezone.utc)
    except Exception:
        return None


def decode_date(obj):
    # number-like
    d = decode_epoch_like(obj)
    if d:
        return d

    if isinstance(obj, str):
        s = obj.strip()
        # digits-only string → numeric epoch
        if s.isdigit():
            d = decode_epoch_like(s)
            if d:
                return d
        # ISO8601 with optional Z
        try:
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            return datetime.fromisoformat(s)
        except Exception:
            pass
        # Common fallbacks
        fmts = [
            "%Y-%m-%d %H:%M:%S%z",
            "%Y-%m-%d %H:%M:%S",
            "%Y/%m/%d %H:%M:%S%z",
            "%Y/%m/%d %H:%M:%S",
        ]
        for f in fmts:
            try:
                return datetime.strptime(s, f).replace(tzinfo=timezone.utc)
            except Exception:
                pass
    return None


TS_KEYS = [
    "timestamp", "time", "ts", "created", "created_at", "datetime", "date",
    "event_time", "eventTime", "iso_timestamp", "when", "at"
]


def event_kind_and_ts(line):
    try:
        obj = json.loads(line)
    except Exception:
        return ("meta", None)

    ts = None
    for k in TS_KEYS:
        if k in obj:
            ts = decode_date(obj.get(k)) or ts
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None
    if ts is None and payload:
        for k in TS_KEYS:
            if k in payload:
                ts = decode_date(payload.get(k)) or ts

    typ = None
    if isinstance(obj.get("type"), str):
        typ = obj["type"]
    elif isinstance(obj.get("event"), str):
        typ = obj["event"]
    if payload and isinstance(payload.get("type"), str):
        typ = typ or payload.get("type")

    role = obj.get("role") or (payload.get("role") if payload else None)
    kind = None
    if typ:
        t = str(typ).lower()
        if t in TOOL_CALL_TYPES:
            kind = "tool_call"
        elif t in TOOL_RESULT_TYPES:
            kind = "tool_result"
        elif t in {"error", "err"}:
            kind = "error"
        elif t in {"meta", "system", "environment_context", "environment-context", "env_context"}:
            kind = "meta"
    if not kind and role:
        r = str(role).lower()
        if r == "user":
            kind = "user"
        elif r == "assistant":
            kind = "assistant"
        elif r == "tool":
            kind = "tool_result"
        elif r == "system":
            kind = "meta"
    if not kind:
        kind = "meta"
    return (kind, ts)


def scan_file(path, max_lines=0):
    events = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                kind, ts = event_kind_and_ts(line)
                events.append((kind, ts))
                if max_lines and i + 1 >= max_lines:
                    break
    except Exception:
        pass
    return events


def discover_codex_files(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn.startswith("rollout-") and fn.endswith(".jsonl"):
                out.append(os.path.join(dirpath, fn))
    out.sort(reverse=True)
    return out


def discover_claude_files(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            if ext in (".jsonl", ".ndjson"):
                out.append(os.path.join(dirpath, fn))
    # sort by mtime desc
    out.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return out


def within(ts, start, end):
    if ts is None:
        return False
    if start and ts < start:
        return False
    if end and ts >= end:
        return False
    return True


def count_tool_calls(events, start, end, strategy="prev_only"):
    # strategies: prev_only, conservative, session_broken
    if strategy == "session_broken":
        # if any event OR coarse fallback is within range, count all tool_calls in file
        any_in = any(within(ts, start, end) for (_, ts) in events if ts is not None)
        if not any_in:
            return 0
        return sum(1 for (k, _) in events if k == "tool_call")

    if strategy == "conservative":
        return sum(1 for (k, ts) in events if k == "tool_call" and within(ts, start, end))

    # prev_only: use previous known timestamp for missing ts
    prev = None
    count = 0
    for (k, ts) in events:
        if ts is not None:
            prev = ts
        if k == "tool_call":
            eff = ts or prev
            if eff is not None and within(eff, start, end):
                count += 1
    return count


def main():
    args = parse_args()
    now = datetime.now(timezone.utc)
    ranges = [(d, now - timedelta(days=d), now) for d in args.days]

    sources = []
    if os.path.isdir(args.codex_root):
        codex_files = discover_codex_files(args.codex_root)
        if args.max_files:
            codex_files = codex_files[: args.max_files]
        sources.append(("Codex", codex_files))
    if os.path.isdir(args.claude_root):
        claude_files = discover_claude_files(args.claude_root)
        if args.max_files:
            claude_files = claude_files[: args.max_files]
        sources.append(("Claude", claude_files))

    if not sources:
        print("No session roots found. Checked:")
        print("  Codex:", args.codex_root)
        print("  Claude:", args.claude_root)
        sys.exit(1)

    print("Scanning files…")
    total_by_strategy = {"session_broken": 0, "conservative": 0, "prev_only": 0}
    per_range = {s: {d: 0 for (d, _, _) in ranges} for s in total_by_strategy.keys()}
    # Optional per-file details for the longest window
    per_file_prev_only = {d: [] for (d, _, _) in ranges}

    # quick stats
    events_total = 0
    events_with_ts = 0
    tool_calls_total = 0
    tool_calls_with_ts = 0

    for (label, files) in sources:
        for fp in files:
            evs = scan_file(fp)
            if not evs:
                continue
            events_total += len(evs)
            events_with_ts += sum(1 for (_, ts) in evs if ts is not None)
            tcs = [(k, ts) for (k, ts) in evs if k == "tool_call"]
            tool_calls_total += len(tcs)
            tool_calls_with_ts += sum(1 for (_, ts) in tcs if ts is not None)

            for (days, start, end) in ranges:
                c_b = count_tool_calls(evs, start, end, strategy="session_broken")
                c_c = count_tool_calls(evs, start, end, strategy="conservative")
                c_p = count_tool_calls(evs, start, end, strategy="prev_only")
                per_range["session_broken"][days] += c_b
                per_range["conservative"][days] += c_c
                per_range["prev_only"][days] += c_p
                if c_p:
                    per_file_prev_only[days].append((fp, c_p))

    print()
    print("DATASET STATS")
    print(f"  Events total: {events_total}")
    print(f"  Events with timestamps: {events_with_ts} ({(events_with_ts/max(1,events_total))*100:.1f}%)")
    print(f"  tool_call total: {tool_calls_total}")
    print(f"  tool_call with timestamps: {tool_calls_with_ts} ({(tool_calls_with_ts/max(1,tool_calls_total))*100:.1f}%)")
    print()
    print("COUNTS BY RANGE")
    header = ["Days", "Broken(session)", "Conservative", "PrevOnly(fill)"]
    print("\t".join(header))
    for (days, _, _) in ranges:
        row = [str(days), str(per_range["session_broken"][days]), str(per_range["conservative"][days]), str(per_range["prev_only"][days])]
        print("\t".join(row))

    if args.verbose:
        print()
        for (days, _, _) in ranges[-1:]:
            files = sorted(per_file_prev_only[days], key=lambda x: x[1], reverse=True)[:20]
            print(f"Top files by PrevOnly counts in last {days} days:")
            for fp, cnt in files:
                print(f"  {cnt:5d}  {fp}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
