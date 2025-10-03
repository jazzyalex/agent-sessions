#!/usr/bin/env python3
"""
Pick a few Claude Code sessions from a Claude logs root and print
tab-separated rows: sessionId<TAB>cwd<TAB>file

Usage:
  tools/pick_claude_sessions.py --root ./.claude --limit 3

If --root is omitted, uses $CLAUDE_ROOT or $HOME/.claude.
Searches **/*.jsonl and **/*.ndjson under the resolved root.
"""

import argparse
import glob
import json
import os
from pathlib import Path
from datetime import datetime, timezone


def ts_of_event(e):
    for key in ("timestamp", "time", "ts", "created", "created_at"):
        if key in e:
            v = e[key]
            try:
                if isinstance(v, (int, float)):
                    if v > 1e14:
                        v = v / 1_000_000
                    elif v > 1e11:
                        v = v / 1_000
                    return datetime.fromtimestamp(v, tz=timezone.utc)
                if isinstance(v, str):
                    dt = datetime.fromisoformat(v.replace('Z', '+00:00'))
                    # Normalize to aware UTC
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    return dt.astimezone(timezone.utc)
            except Exception:
                continue
    return None


def parse_first_n(path: Path, n=40):
    sid = None
    cwd = None
    first_ts = None
    last_ts = None
    count = 0
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            for i, line in enumerate(f):
                s = line.strip()
                if not s:
                    continue
                count += 1
                if i < n:
                    try:
                        e = json.loads(s)
                    except Exception:
                        continue
                    if sid is None:
                        sid = e.get('sessionId') or e.get('session_id') or e.get('id')
                        if 'payload' in e and isinstance(e['payload'], dict):
                            sid = sid or e['payload'].get('sessionId') or e['payload'].get('session_id')
                    if cwd is None:
                        cwd = e.get('cwd')
                        if 'payload' in e and isinstance(e['payload'], dict):
                            cwd = cwd or e['payload'].get('cwd')
                    ts = ts_of_event(e)
                    if ts:
                        if first_ts is None or ts < first_ts:
                            first_ts = ts
                        if last_ts is None or ts > last_ts:
                            last_ts = ts
    except Exception:
        return None
    return {
        'file': path,
        'sessionId': sid,
        'cwd': cwd,
        'first_ts': first_ts,
        'last_ts': last_ts,
        'count': count,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=None)
    ap.add_argument('--limit', type=int, default=3)
    args = ap.parse_args()

    root = None
    if args.root:
        root = Path(args.root)
    elif os.getenv('CLAUDE_ROOT'):
        root = Path(os.getenv('CLAUDE_ROOT'))
    else:
        root = Path.home() / '.claude'

    patterns = [str(root / '**' / '*.jsonl'), str(root / '**' / '*.ndjson')]
    files = []
    for p in patterns:
        files.extend(glob.glob(p, recursive=True))
    files = sorted(set(Path(f) for f in files), key=lambda p: p.stat().st_mtime, reverse=True)

    rows = []
    for fp in files:
        m = parse_first_n(fp)
        if m:
            rows.append(m)

    # Sort by last_ts desc, then file mtime
    def sort_key(r):
        dt = r['last_ts']
        if dt is None:
            dt = datetime.min.replace(tzinfo=timezone.utc)
        else:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        return (dt, r['file'].stat().st_mtime)

    rows.sort(key=sort_key, reverse=True)

    print("sessionId\tcwd\tfile")
    for r in rows[: args.limit]:
        sid = r['sessionId'] or ''
        cwd = r['cwd'] or ''
        print(f"{sid}\t{cwd}\t{r['file']}")


if __name__ == '__main__':
    main()
