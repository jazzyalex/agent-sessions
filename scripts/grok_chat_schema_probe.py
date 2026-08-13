#!/usr/bin/env python3
"""Read-only schema probe for Grok CLI session stores under ~/.grok/sessions.

Mirrors scripts/droid_stream_schema_probe.py: it reports the observed shape of
the on-disk format so a parser is written against evidence rather than guesses.

Usage:
    python3 scripts/grok_chat_schema_probe.py [--root ~/.grok/sessions] [--sample N]
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import pathlib
import sys


def iter_sessions(root: pathlib.Path):
    for bucket in sorted(root.iterdir()):
        if not bucket.is_dir():
            continue
        for session in sorted(bucket.iterdir()):
            if session.is_dir() and (session / "summary.json").exists():
                yield bucket, session


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="~/.grok/sessions")
    ap.add_argument("--sample", type=int, default=0, help="limit sessions scanned")
    args = ap.parse_args()

    root = pathlib.Path(os.path.expanduser(args.root))
    if not root.is_dir():
        print(f"no such root: {root}", file=sys.stderr)
        return 1

    sessions = list(iter_sessions(root))
    if args.sample:
        sessions = sessions[: args.sample]

    print(f"root: {root}")
    print(f"sessions with summary.json: {len(sessions)}")

    summary_keys = collections.Counter()
    file_presence = collections.Counter()
    chat_types = collections.Counter()
    content_shapes = collections.Counter()
    format_versions = collections.Counter()
    models = collections.Counter()
    missing_chat = 0

    for _bucket, session in sessions:
        for entry in session.iterdir():
            file_presence[entry.name] += 1

        try:
            summary = json.loads((session / "summary.json").read_text())
        except Exception:
            continue
        for k in summary:
            summary_keys[k] += 1
        format_versions[summary.get("chat_format_version")] += 1
        if summary.get("current_model_id"):
            models[summary["current_model_id"]] += 1

        chat = session / "chat_history.jsonl"
        if not chat.exists():
            missing_chat += 1
            continue
        with chat.open(errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    chat_types["UNPARSEABLE"] += 1
                    continue
                t = obj.get("type", "?")
                chat_types[t] += 1
                content = obj.get("content")
                if isinstance(content, str):
                    content_shapes[f"{t}:str"] += 1
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict):
                            content_shapes[f"{t}:{part.get('type', '?')}"] += 1
                elif content is None:
                    content_shapes[f"{t}:none"] += 1

    def dump(title, counter, limit=25):
        print(f"\n--- {title} ---")
        for k, v in counter.most_common(limit):
            print(f"  {str(k):<34} {v}")

    print(f"\nsessions missing chat_history.jsonl: {missing_chat}")
    dump("summary.json keys", summary_keys)
    dump("chat_format_version", format_versions)
    dump("current_model_id", models)
    dump("files present in session dirs", file_presence, 30)
    dump("chat_history record types", chat_types)
    dump("content part shapes (type:part)", content_shapes, 30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
