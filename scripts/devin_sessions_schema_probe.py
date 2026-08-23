#!/usr/bin/env python3
"""Read-only schema probe for the Devin CLI session store.

Devin keeps every session in one SQLite database at
`~/.local/share/devin/cli/sessions.db`. Messages live in `message_nodes` as a
*forest*: each row carries `node_id` and `parent_node_id`, and `sessions`
records the tip of the live conversation in `main_chain_id`. Branches are
retries and edits, so rendering every row would replay abandoned turns.

This reports the shapes a parser has to handle, so the parser is written
against evidence rather than guesses.

Usage:
    python3 scripts/devin_sessions_schema_probe.py [--db PATH] [--sample N]
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sqlite3
import sys


def connect(path: str) -> sqlite3.Connection:
    uri = "file:%s?mode=ro" % path
    return sqlite3.connect(uri, uri=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="~/.local/share/devin/cli/sessions.db")
    ap.add_argument("--sample", type=int, default=12, help="sessions to walk in depth")
    args = ap.parse_args()

    path = os.path.expanduser(args.db)
    if not os.path.exists(path):
        print("no such database: %s" % path, file=sys.stderr)
        return 1

    db = connect(path)
    db.row_factory = sqlite3.Row

    total, hidden = db.execute(
        "SELECT COUNT(*), COALESCE(SUM(hidden), 0) FROM sessions").fetchone()
    # Collapse $HOME so a pasted report does not carry the operator's username.
    shown_path = path.replace(os.path.expanduser("~"), "~", 1)
    print("database: %s (%.1f GB)" % (shown_path, os.path.getsize(path) / 1e9))
    print("sessions: %d (%d hidden)" % (total, hidden))

    def dump(title, rows):
        print("\n--- %s ---" % title)
        for k, v in rows:
            print("  %-34s %s" % (k, v))

    dump("backend_type", db.execute(
        "SELECT backend_type, COUNT(*) FROM sessions GROUP BY 1 ORDER BY 2 DESC").fetchall())
    dump("agent_mode", db.execute(
        "SELECT agent_mode, COUNT(*) FROM sessions GROUP BY 1 ORDER BY 2 DESC").fetchall())
    dump("model", db.execute(
        "SELECT model, COUNT(*) FROM sessions GROUP BY 1 ORDER BY 2 DESC LIMIT 12").fetchall())
    dump("sessions with NULL title / main_chain_id", [
        ("title IS NULL", db.execute("SELECT COUNT(*) FROM sessions WHERE title IS NULL").fetchone()[0]),
        ("main_chain_id IS NULL", db.execute("SELECT COUNT(*) FROM sessions WHERE main_chain_id IS NULL").fetchone()[0]),
    ])

    # --- forest shape ----------------------------------------------------
    print("\n--- forest: main chain vs total nodes ---")
    print("  %-24s %8s %8s %8s %8s" % ("session", "nodes", "chain", "roots", "branch"))
    chain_ratio = []
    for row in db.execute(
        "SELECT id, main_chain_id FROM sessions ORDER BY last_activity_at DESC LIMIT ?",
        (args.sample,),
    ):
        sid = row["id"]
        parents = {
            r["node_id"]: r["parent_node_id"]
            for r in db.execute(
                "SELECT node_id, parent_node_id FROM message_nodes WHERE session_id = ?", (sid,))
        }
        if not parents:
            continue
        roots = sum(1 for p in parents.values() if p is None)
        counts = collections.Counter(p for p in parents.values() if p is not None)
        branch = sum(1 for c in counts.values() if c > 1)

        # walk main_chain_id back to its root
        chain = 0
        node = row["main_chain_id"]
        seen = set()
        while node is not None and node in parents and node not in seen:
            seen.add(node)
            chain += 1
            node = parents[node]
        print("  %-24s %8d %8d %8d %8d" % (sid[:24], len(parents), chain, roots, branch))
        if parents:
            chain_ratio.append(chain / len(parents))

    if chain_ratio:
        print("  main chain covers %.0f%%-%.0f%% of nodes (mean %.0f%%)" % (
            100 * min(chain_ratio), 100 * max(chain_ratio),
            100 * sum(chain_ratio) / len(chain_ratio)))

    # --- chat_message shapes ---------------------------------------------
    roles = collections.Counter()
    keys = collections.Counter()
    content_kinds = collections.Counter()
    # Value *types* per key, never values. This script is listed under
    # `evidence_tools` in the support matrix, which means a steward runs it and
    # pastes the output into a public issue — so nothing derived from a real
    # `chat_message` may reach stdout. Knowing that `assistant.content` is a str
    # and `user.images` is a list is what the reader actually needs; the text
    # itself was only ever incidental.
    value_types = collections.Counter()
    for row in db.execute(
        "SELECT chat_message FROM message_nodes ORDER BY row_id DESC LIMIT 20000"
    ):
        try:
            msg = json.loads(row["chat_message"])
        except Exception:
            roles["UNPARSEABLE"] += 1
            continue
        role = msg.get("role", "?")
        roles[role] += 1
        for k in msg:
            keys["%s.%s" % (role, k)] += 1
        content = msg.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict):
                    content_kinds["%s:%s" % (role, part.get("type", "?"))] += 1
        elif isinstance(content, str):
            content_kinds["%s:str" % role] += 1
        for k, v in msg.items():
            value_types["%s.%s: %s" % (role, k, type(v).__name__)] += 1

    dump("chat_message roles (last 20k nodes)", roles.most_common())
    dump("keys by role", keys.most_common(30))
    dump("content part kinds", content_kinds.most_common(20))
    dump("value types by key", value_types.most_common(40))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
