#!/usr/bin/env python3
"""Measure local AI-agent session stores. Aggregates only — never content.

Outputs JSON with per-agent stats: session counts, bytes, events,
user-visible messages, text-vs-overhead ratio, parse timings, field coverage.
"""
import json, os, sqlite3, sys, time
from pathlib import Path

HOME = Path.home()
OUT = {}

def walk_strings(obj, keys=("text",), out=None):
    """Sum lengths of string values under given key names, recursively."""
    if out is None:
        out = [0]
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in keys and isinstance(v, str):
                out[0] += len(v)
            else:
                walk_strings(v, keys, out)
    elif isinstance(obj, list):
        for v in obj:
            walk_strings(v, keys, out)
    return out[0]

def has_key(obj, key, depth=0):
    if depth > 6:
        return False
    if isinstance(obj, dict):
        if key in obj and obj[key] not in (None, ""):
            return True
        return any(has_key(v, key, depth + 1) for v in obj.values())
    if isinstance(obj, list):
        return any(has_key(v, key, depth + 1) for v in obj)
    return False

def scan_jsonl_corpus(name, files, classify):
    """classify(obj) -> role string: 'user'|'assistant'|'tool'|'meta'|'other'"""
    stats = dict(agent=name, format="jsonl", sessions=len(files), total_bytes=0,
                 events=0, bad_lines=0, user_msgs=0, assistant_msgs=0,
                 tool_events=0, meta_events=0, other_events=0,
                 visible_text_chars=0, model_field_events=0, ts_field_events=0,
                 largest_session_bytes=0, parse_seconds=0.0,
                 first_mtime=None, last_mtime=None)
    t0 = time.time()
    for f in files:
        try:
            sz = f.stat().st_size
            mt = f.stat().st_mtime
        except OSError:
            continue
        stats["total_bytes"] += sz
        stats["largest_session_bytes"] = max(stats["largest_session_bytes"], sz)
        stats["first_mtime"] = mt if stats["first_mtime"] is None else min(stats["first_mtime"], mt)
        stats["last_mtime"] = mt if stats["last_mtime"] is None else max(stats["last_mtime"], mt)
        try:
            with open(f, "rb") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    stats["events"] += 1
                    try:
                        obj = json.loads(line)
                    except Exception:
                        stats["bad_lines"] += 1
                        continue
                    role = classify(obj)
                    if role == "user":
                        stats["user_msgs"] += 1
                    elif role == "assistant":
                        stats["assistant_msgs"] += 1
                    elif role == "tool":
                        stats["tool_events"] += 1
                    elif role == "meta":
                        stats["meta_events"] += 1
                    else:
                        stats["other_events"] += 1
                    if role in ("user", "assistant"):
                        stats["visible_text_chars"] += walk_strings(obj, ("text",))
                        # plain string content
                        m = obj.get("message") if isinstance(obj, dict) else None
                        for holder in (obj, m):
                            if isinstance(holder, dict) and isinstance(holder.get("content"), str):
                                stats["visible_text_chars"] += len(holder["content"])
                    if isinstance(obj, dict):
                        if has_key(obj, "model"):
                            stats["model_field_events"] += 1
                        if has_key(obj, "timestamp") or has_key(obj, "ts") or has_key(obj, "created_at"):
                            stats["ts_field_events"] += 1
        except OSError:
            continue
    stats["parse_seconds"] = round(time.time() - t0, 2)
    return stats

# ---------- Claude Code ----------
def classify_claude(o):
    t = o.get("type")
    if o.get("isMeta") or t in ("summary", "file-history-snapshot", "queued-message"):
        return "meta"
    if t == "user":
        m = o.get("message", {})
        c = m.get("content")
        if isinstance(c, list) and c and all(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return "tool"
        return "user"
    if t == "assistant":
        return "assistant"
    if t in ("system",):
        return "meta"
    return "other"

claude_files = list((HOME / ".claude" / "projects").glob("*/*.jsonl"))
OUT["claude_code"] = scan_jsonl_corpus("Claude Code", claude_files, classify_claude)

# ---------- Codex ----------
def classify_codex(o):
    t = o.get("type")
    p = o.get("payload") if isinstance(o.get("payload"), dict) else {}
    pt = p.get("type")
    if t in ("session_meta", "turn_context", "compacted") or pt in ("session_meta", "turn_context"):
        return "meta"
    if pt == "message":
        role = p.get("role")
        if role == "user":
            return "user"
        if role == "assistant":
            return "assistant"
    if pt in ("function_call", "function_call_output", "local_shell_call",
              "custom_tool_call", "custom_tool_call_output", "web_search_call"):
        return "tool"
    if pt == "reasoning":
        return "other"
    if t == "event_msg":
        et = p.get("type")
        if et == "user_message":
            return "user"
        if et == "agent_message":
            return "assistant"
        return "meta"
    return "other"

codex_files = list((HOME / ".codex" / "sessions").glob("*/*/*/rollout-*.jsonl"))
OUT["codex"] = scan_jsonl_corpus("Codex", codex_files, classify_codex)

# ---------- Cursor agent transcripts ----------
def classify_cursor(o):
    t = (o.get("type") or o.get("role") or "").lower()
    if t in ("user", "human", "user_message"):
        return "user"
    if t in ("assistant", "ai", "agent", "assistant_message"):
        return "assistant"
    if "tool" in t or "shell" in t or "command" in t:
        return "tool"
    if t in ("meta", "summary", "session"):
        return "meta"
    return "other"

cursor_files = list((HOME / ".cursor" / "projects").glob("*/agent-transcripts/*/*.jsonl"))
OUT["cursor"] = scan_jsonl_corpus("Cursor Agent", cursor_files, classify_cursor)
# count cursor chat dbs
cursor_dbs = list((HOME / ".cursor" / "chats").glob("*/*/store.db"))
OUT["cursor"]["metadata_dbs"] = len(cursor_dbs)
OUT["cursor"]["metadata_db_bytes"] = sum(f.stat().st_size for f in cursor_dbs if f.exists())

# ---------- Copilot CLI ----------
def classify_copilot(o):
    t = (o.get("type") or o.get("role") or "").lower()
    if "user" in t:
        return "user"
    if "assistant" in t or "agent" in t or "completion" in t:
        return "assistant"
    if "tool" in t or "shell" in t or "command" in t:
        return "tool"
    if t in ("meta", "session", "state", "info"):
        return "meta"
    return "other"

cop_root = HOME / ".copilot" / "session-state"
cop_files = list(cop_root.glob("*/events.jsonl")) + list(cop_root.glob("*.jsonl"))
OUT["copilot"] = scan_jsonl_corpus("Copilot CLI", cop_files, classify_copilot)

# ---------- SQLite stores ----------
def sqlite_stats(name, db_path, queries):
    st = dict(agent=name, format="sqlite", db_bytes=None, tables={}, parse_seconds=0.0)
    p = Path(db_path)
    if not p.exists():
        st["missing"] = True
        return st
    st["db_bytes"] = p.stat().st_size
    for ext in ("-wal", "-shm"):
        q = Path(str(p) + ext)
        if q.exists():
            st["db_bytes"] += q.stat().st_size
    t0 = time.time()
    try:
        con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
        cur = con.cursor()
        names = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        st["table_names"] = names
        for t in names:
            try:
                st["tables"][t] = cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
            except Exception as e:
                st["tables"][t] = f"err:{type(e).__name__}"
        for key, sql in queries.items():
            try:
                st[key] = cur.execute(sql).fetchone()[0]
            except Exception as e:
                st[key] = f"err:{type(e).__name__}"
        con.close()
    except Exception as e:
        st["error"] = f"{type(e).__name__}: {e}"
    st["parse_seconds"] = round(time.time() - t0, 2)
    return st

OUT["opencode"] = sqlite_stats("OpenCode", HOME / ".local/share/opencode/opencode.db", {})
OUT["hermes"] = sqlite_stats("Hermes", HOME / ".hermes/state.db", {})

# derived ratios
for k, s in OUT.items():
    if s.get("format") == "jsonl" and s.get("user_msgs"):
        s["bytes_per_user_msg"] = round(s["total_bytes"] / s["user_msgs"])
        s["visible_text_ratio"] = round(s["visible_text_chars"] / max(1, s["total_bytes"]), 4)
        s["events_per_session"] = round(s["events"] / max(1, s["sessions"]), 1)
        s["model_field_pct"] = round(100 * s["model_field_events"] / max(1, s["events"]), 1)
        s["ts_field_pct"] = round(100 * s["ts_field_events"] / max(1, s["events"]), 1)

print(json.dumps(OUT, indent=2))
