# Cursor Agent-Watch Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cursor as the 8th monitored agent in the agent-watch system with JSONL transcript fingerprinting, a SQLite health probe, and full matrix/ledger/config tracking.

**Architecture:** New `_cursor_transcript_schema_fingerprint()` function in `agent_watch.py` buckets JSONL lines by normalized `role` and content block `type`. A new `scripts/cursor_sqlite_probe.py` script verifies the SQLite chat database is healthy. Both are wired into the existing weekly scan machinery alongside the 7 existing agents.

**Tech Stack:** Python 3 (agent_watch.py, cursor_sqlite_probe.py), YAML (matrix/ledger), JSON (config), JSONL (fixtures)

**Spec:** `docs/superpowers/specs/2026-04-12-cursor-agent-watch-design.md`

---

## File Map

| File | Action |
|---|---|
| `scripts/agent_watch.py` | Modify — add fingerprinter, wire verified_map + weekly dispatcher + baseline + probe handler |
| `scripts/cursor_sqlite_probe.py` | Create — SQLite meta-table health check |
| `docs/agent-support/agent-watch-config.json` | Modify — add `cursor` agent entry |
| `docs/agent-support/agent-support-matrix.yml` | Modify — add `cursor` agent |
| `docs/agent-support/agent-support-ledger.yml` | Modify — initial Cursor entry |
| `docs/agent-json-tracking.md` | Modify — log entry |
| `docs/agent-support/workflow.md` | Modify — "seven" → "eight" |
| `Resources/Fixtures/stage0/agents/cursor/small.jsonl` | Create |
| `Resources/Fixtures/stage0/agents/cursor/large.jsonl` | Create |
| `Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl` | Create |
| `Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl` | Create |
| `Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl` | Create |
| `skills/agent-session-format-check/SKILL.md` | Modify — add Cursor sections |
| `.claude/skills/agent-session-format-check.md` | Modify — add Cursor to contracts table |

---

## Task 1: Fixtures

**Files:**
- Create: `Resources/Fixtures/stage0/agents/cursor/small.jsonl`
- Create: `Resources/Fixtures/stage0/agents/cursor/large.jsonl`
- Create: `Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl`
- Create: `Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl`
- Create: `Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl`

- [ ] **Step 1: Create small.jsonl**

```jsonl
{"role":"user","message":{"content":[{"type":"text","text":"List the files."}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Here are the files."}]}}
{"role":"user","message":{"content":[{"type":"text","text":"Run ls."}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Running ls."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
```

- [ ] **Step 2: Create large.jsonl**

```jsonl
{"role":"user","message":{"content":[{"type":"text","text":"What files are here?"}]}}
{"role":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me check the directory."},{"type":"text","text":"I will list the files."},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
{"role":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file1.txt\nfile2.txt"}]}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"There are two files."}]}}
{"role":"user","message":{"content":[{"type":"text","text":"Read file1.txt."}]}}
{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"file1.txt"}}]}}
{"role":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"hello world"}]}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"The file contains: hello world."}]}}
{"role":"user","message":{"content":[{"type":"text","text":"Thanks."}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"You are welcome."}]}}
```

Note: `thinking` and `tool_result` are synthetic (not yet observed locally). They provide aspirational baseline coverage so future appearance in live sessions doesn't trigger false drift.

- [ ] **Step 3: Create schema_drift.jsonl** (empty placeholder)

The file should exist but be empty — the fingerprinter skips empty lines. This placeholder is updated in future weekly cycles when actual drift is detected.

Create an empty file at `Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl`.

- [ ] **Step 4: Create subagent fixtures**

`Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl`:
```jsonl
{"role":"user","message":{"content":[{"type":"text","text":"Run a subagent."}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Spawning subagent."},{"type":"tool_use","name":"Agent","input":{"prompt":"List files"}}]}}
```

`Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl`:
```jsonl
{"role":"user","message":{"content":[{"type":"text","text":"List files"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"file1.txt\nfile2.txt"}]}}
```

- [ ] **Step 5: Commit**

```bash
git add Resources/Fixtures/stage0/agents/cursor/
git commit -m "test(cursor): add stage0 fixtures for agent-watch baseline

small.jsonl: minimal text + tool_use coverage
large.jsonl: full coverage incl. thinking, tool_result (synthetic baseline)
schema_drift.jsonl: empty placeholder
subagent/: exercises subagent discovery path

Why: agent-watch needs fixtures to fingerprint Cursor schema baseline"
```

---

## Task 2: Add `_cursor_transcript_schema_fingerprint()` to `agent_watch.py`

**Files:**
- Modify: `scripts/agent_watch.py` — insert after `_jsonl_schema_fingerprint()` (after line ~460)

- [ ] **Step 1: Insert the new function**

In `scripts/agent_watch.py`, after the closing `}` of `_jsonl_schema_fingerprint()` (around line 460), add:

```python
def _cursor_transcript_schema_fingerprint(path: Path, max_lines: int) -> dict[str, Any]:
    """
    Schema fingerprint for Cursor agent transcript JSONL files.

    Cursor transcripts use `role` (user/assistant) as the top-level discriminator
    instead of `type`. We bucket by normalized role AND by content block type
    (prefixed `content.<type>`) so _schema_diff() detects both structural and
    content-level drift.

    Role normalization matches CursorSessionParser.swift:187-193:
      user/human -> user, assistant/model -> assistant, system -> system, else -> assistant
    """
    _ROLE_MAP = {
        "user": "user", "human": "user",
        "assistant": "assistant", "model": "assistant",
        "system": "system",
    }

    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    parse_errors: int = 0
    total_lines: int = 0

    lines: list[str] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.strip():
                continue
            lines.append(line)
            if len(lines) > max_lines:
                lines.pop(0)

    for raw in lines:
        total_lines += 1
        s = raw.strip()
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            parse_errors += 1
            continue
        if not isinstance(obj, dict):
            continue

        # Bucket top-level keys by normalized role
        raw_role = (obj.get("role") or "")
        role = _ROLE_MAP.get(raw_role.lower(), "assistant") if isinstance(raw_role, str) else "assistant"
        type_counts[role] = type_counts.get(role, 0) + 1
        ks = type_keys.setdefault(role, set())
        for k in obj.keys():
            ks.add(k)

        # Bucket content block keys by content type
        msg = obj.get("message")
        if isinstance(msg, dict):
            content = msg.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    ct = block.get("type")
                    if not isinstance(ct, str) or not ct:
                        ct = "<missing-content-type>"
                    bucket = f"content.{ct}"
                    type_counts[bucket] = type_counts.get(bucket, 0) + 1
                    cks = type_keys.setdefault(bucket, set())
                    for k in block.keys():
                        cks.add(k)

    return {
        "file": str(path),
        "type_counts": {k: type_counts[k] for k in sorted(type_counts)},
        "type_keys": {k: sorted(list(type_keys[k])) for k in sorted(type_keys)},
        "parsed_lines": total_lines,
        "parse_errors": parse_errors,
    }
```

- [ ] **Step 2: Verify it runs cleanly on a fixture**

```bash
cd /Users/alexm/Repository/Codex-History
python3 -c "
from pathlib import Path
import sys; sys.path.insert(0, 'scripts')
import agent_watch as aw
import json
fp = aw._cursor_transcript_schema_fingerprint(
    Path('Resources/Fixtures/stage0/agents/cursor/large.jsonl'), max_lines=2500)
print(json.dumps(fp, indent=2))
"
```

Expected output contains `type_keys` with keys: `user`, `assistant`, `content.text`, `content.tool_use`, `content.tool_result`, `content.thinking` — no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/agent_watch.py
git commit -m "feat(monitoring): add _cursor_transcript_schema_fingerprint()

Role-based JSONL fingerprinter for Cursor transcripts. Normalizes
role aliases (human->user, model->assistant) to match CursorSessionParser.
Content blocks bucketed as content.<type> for drift detection.

Why: foundation for wiring Cursor into weekly schema scan"
```

---

## Task 3: Wire Cursor into `agent_watch.py` dispatch

**Files:**
- Modify: `scripts/agent_watch.py` — four locations

- [ ] **Step 1: Add to `verified_map` (~line 1544)**

Find the `verified_map = {` block and add `cursor`:

```python
    verified_map = {
        "codex": matrix_versions.get("codex_cli"),
        "claude": matrix_versions.get("claude_code"),
        "opencode": matrix_versions.get("opencode"),
        "droid": matrix_versions.get("droid"),
        "gemini": matrix_versions.get("gemini_cli"),
        "copilot": matrix_versions.get("copilot_cli"),
        "openclaw": matrix_versions.get("openclaw"),
        "cursor": matrix_versions.get("cursor"),
    }
```

- [ ] **Step 2: Add to matrix-key evidence mapping (~line 1670)**

Find the dict mapping config agent names to matrix YAML keys and add `cursor`:

```python
                    "codex": "codex_cli",
                    "claude": "claude_code",
                    "copilot": "copilot_cli",
                    "droid": "droid",
                    "gemini": "gemini_cli",
                    "opencode": "opencode",
                    "openclaw": "openclaw",
                    "cursor": "cursor",
```

- [ ] **Step 3: Add `cursor_transcript_newest` branch to weekly dispatcher (~line 1702)**

Find the `elif kind == "opencode_storage_latest_session":` block. After its closing block (after line ~1709), add:

```python
                elif kind == "cursor_transcript_newest":
                    max_lines = int(local_schema_cfg.get("max_lines") or 2500)
                    newest = _newest_file(roots, glob)
                    if newest:
                        local_fp = _cursor_transcript_schema_fingerprint(newest, max_lines=max_lines)
```

- [ ] **Step 4: Add Cursor branch to `_baseline_type_keys_for_agent` (~line 729)**

Find the `elif agent_name == "openclaw":` branch. After it, add:

```python
    elif agent_name == "cursor":
        for p in filtered:
            if not p.endswith(".jsonl"):
                continue
            bp = Path(p)
            if bp.exists():
                fps.append(_cursor_transcript_schema_fingerprint(bp, max_lines=5000))
```

- [ ] **Step 5: Add `cursor_sqlite_json` probe parse handler (~line 823)**

Find the `elif parse_kind == "capture_latest_sessions":` block. After it, add:

```python
    elif parse_kind == "cursor_sqlite_json":
        try:
            parsed = json.loads(stdout) if stdout else None
        except Exception:
            parsed = None
```

Also add the `ok` check after the existing `ok` checks (around line 833):

```python
    if parse_kind == "cursor_sqlite_json":
        ok = ok and isinstance(parsed, dict) and bool(parsed.get("ok") is True)
```

- [ ] **Step 6: Verify the wiring compiles**

```bash
cd /Users/alexm/Repository/Codex-History
python3 -c "import scripts.agent_watch" 2>&1 || python3 scripts/agent_watch.py --help
```

Expected: no import errors.

- [ ] **Step 7: Commit**

```bash
git add scripts/agent_watch.py
git commit -m "feat(monitoring): wire Cursor into agent_watch weekly dispatch

- verified_map: cursor reads from matrix.cursor
- weekly dispatcher: cursor_transcript_newest kind -> _cursor_transcript_schema_fingerprint
- evidence mapping: cursor -> cursor matrix key
- baseline fingerprinter: cursor branch uses role-based function
- probe handler: cursor_sqlite_json parses probe stdout as JSON

Why: four dispatch points required for Cursor to participate fully in weekly scan"
```

---

## Task 4: SQLite probe script

**Files:**
- Create: `scripts/cursor_sqlite_probe.py`

- [ ] **Step 1: Create the script**

```python
#!/usr/bin/env python3
"""
cursor_sqlite_probe.py — Lightweight health check for Cursor SQLite chat databases.

Finds the newest store.db under ~/.cursor/chats/*/*/store.db, opens it,
verifies the meta table exists and returns parseable JSON metadata.

Exit codes:
  0 — ok
  1 — no store.db found
  2 — meta table missing or unreadable
  3 — unexpected schema (required keys absent)
"""
import glob
import json
import os
import sqlite3
import sys
from pathlib import Path


REQUIRED_META_KEYS = {"agentId", "name", "createdAt"}


def find_newest_store_db() -> Path | None:
    pattern = str(Path.home() / ".cursor" / "chats" / "*" / "*" / "store.db")
    candidates = glob.glob(pattern)
    if not candidates:
        return None
    return Path(max(candidates, key=os.path.getmtime))


def probe(db_path: Path) -> dict:
    try:
        con = sqlite3.connect(str(db_path))
    except Exception as e:
        return {"ok": False, "db_path": str(db_path), "error": f"open_failed: {e}", "exit_code": 2}

    try:
        cur = con.execute("SELECT value FROM meta WHERE key='0' LIMIT 1")
        row = cur.fetchone()
    except Exception as e:
        con.close()
        return {"ok": False, "db_path": str(db_path), "error": f"meta_read_failed: {e}", "exit_code": 2}

    con.close()

    if row is None:
        return {"ok": False, "db_path": str(db_path), "error": "meta_key_0_missing", "exit_code": 2}

    hex_value = row[0]
    try:
        raw = bytes.fromhex(hex_value).decode("utf-8")
        meta = json.loads(raw)
    except Exception as e:
        return {"ok": False, "db_path": str(db_path), "error": f"meta_decode_failed: {e}", "exit_code": 2}

    if not isinstance(meta, dict):
        return {"ok": False, "db_path": str(db_path), "error": "meta_not_dict", "exit_code": 3}

    meta_keys = sorted(meta.keys())
    missing = REQUIRED_META_KEYS - set(meta_keys)
    if missing:
        return {
            "ok": False,
            "db_path": str(db_path),
            "meta_keys": meta_keys,
            "error": f"missing_required_keys: {sorted(missing)}",
            "exit_code": 3,
        }

    return {"ok": True, "db_path": str(db_path), "meta_keys": meta_keys, "error": None, "exit_code": 0}


def main() -> int:
    db_path = find_newest_store_db()
    if db_path is None:
        result = {"ok": False, "db_path": None, "error": "no_store_db_found", "exit_code": 1}
        print(json.dumps(result))
        return 1

    result = probe(db_path)
    exit_code = result.pop("exit_code")
    print(json.dumps(result))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Make it executable and test it**

```bash
chmod +x scripts/cursor_sqlite_probe.py
python3 scripts/cursor_sqlite_probe.py
```

Expected: JSON output with `"ok": true`, a `db_path`, and `meta_keys` containing at least `agentId`, `name`, `createdAt`. Exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/cursor_sqlite_probe.py
git commit -m "feat(monitoring): add cursor_sqlite_probe.py

Lightweight health check for Cursor SQLite chat databases.
Finds newest store.db, verifies meta table, hex-decodes key=0 row,
checks required keys (agentId, name, createdAt).

Why: SQLite metadata is Cursor's supplementary backend; a simple
health probe catches store.db schema changes without deep fingerprinting"
```

---

## Task 5: Config, matrix, ledger, tracking

**Files:**
- Modify: `docs/agent-support/agent-watch-config.json`
- Modify: `docs/agent-support/agent-support-matrix.yml`
- Modify: `docs/agent-support/agent-support-ledger.yml`
- Modify: `docs/agent-json-tracking.md`
- Modify: `docs/agent-support/workflow.md`

- [ ] **Step 1: Add cursor entry to `agent-watch-config.json`**

In `docs/agent-support/agent-watch-config.json`, find the closing `}` of the `"openclaw"` entry (line ~331). Add a comma after it, then add:

```json
    "cursor": {
      "cadence": { "daily": false, "weekly": true },
      "installed_version_cmd": ["cursor", "--version"],
      "verified_version_source": "docs/agent-support/agent-support-matrix.yml#agents.cursor.max_verified_version",
      "upstream": [],
      "risk_keywords": {
        "schema": ["session", "transcript", "json", "jsonl", "agent-transcripts", "format", "tool_result", "thinking"],
        "usage": []
      },
      "weekly": {
        "local_schema": {
          "kind": "cursor_transcript_newest",
          "roots": ["~/.cursor/projects"],
          "glob": "**/agent-transcripts/**/*.jsonl",
          "max_lines": 2500
        },
        "freshness_window_days": 30,
        "discovery_path_contract": {
          "description": "Cursor transcripts under ~/.cursor/projects/*/agent-transcripts/*/*.jsonl",
          "patterns": ["/\\.cursor/projects/.+/agent-transcripts/.+\\.jsonl$"]
        },
        "probes": [
          {
            "kind": "script",
            "label": "cursor_sqlite_probe",
            "argv": ["./scripts/cursor_sqlite_probe.py"],
            "timeout_seconds": 30,
            "parse": "cursor_sqlite_json"
          }
        ]
      }
    }
```

- [ ] **Step 2: Add cursor to `agent-support-matrix.yml`**

At the end of the `agents:` block in `docs/agent-support/agent-support-matrix.yml`, add:

```yaml
  cursor:
    max_verified_version: "2026.04.12"
    version_field: "not_logged"
    evidence_fixtures:
      - "Resources/Fixtures/stage0/agents/cursor/small.jsonl"
      - "Resources/Fixtures/stage0/agents/cursor/large.jsonl"
      - "Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl"
      - "Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl"
      - "Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl"
```

Also update the `as_of_commit` and `as_of_date` header fields to today's commit and `2026-04-12`.

Also add a note to the `notes:` list:
```yaml
  - "2026-04-12: added cursor as 8th monitored agent. Initial verified version 2026.04.12 (date-based, no version embedded in transcripts)."
```

- [ ] **Step 3: Add initial entry to `agent-support-ledger.yml`**

Prepend a new entry at the top of the `entries:` list:

```yaml
  - agent_sessions_version: "2.10.1"
    as_of_date_utc: "2026-04-12"
    as_of_commit: "<current-commit-hash>"
    verified:
      cursor:
        sessions:
          max_verified_version: "2026.04.12"
          evidence:
            - "Resources/Fixtures/stage0/agents/cursor/small.jsonl"
            - "Resources/Fixtures/stage0/agents/cursor/large.jsonl"
            - "scripts/probe_scan_output/agent_watch/<slug>/report.json"
    notes:
      - "Initial Cursor monitoring setup. Date-based version (no CLI version embedded in transcripts)."
      - "cursor --version returns null (IDE not installed); expected steady state, not a failure."
      - "SQLite probe verifies ~/.cursor/chats/*/*/store.db meta table health."
      - "Subagent fixtures cover the agent-transcripts/<uuid>/subagents/<uuid>.jsonl path."
```

Replace `<current-commit-hash>` with the actual short hash after the final commit, and `<slug>` with the report dir from the first successful weekly scan.

- [ ] **Step 4: Add tracking log entry**

In `docs/agent-json-tracking.md`, prepend to the "Upstream Version Check Log" section:

```
- 2026-04-12: Added Cursor as 8th monitored agent. Initial verified version 2026.04.12 (date-based; Cursor does not embed CLI version in transcripts). Schema: role-based JSONL (user/assistant buckets + content.<type> sub-buckets). SQLite probe added for ~/.cursor/chats/ health. No prebump driver (no headless mode). Evidence: Resources/Fixtures/stage0/agents/cursor/, scripts/agent_watch.py, scripts/cursor_sqlite_probe.py, docs/agent-support/agent-watch-config.json, docs/agent-support/agent-support-matrix.yml.
```

- [ ] **Step 5: Update workflow.md**

In `docs/agent-support/workflow.md` line 26, change:
```
   - Weekly: release watch + probes for all seven agents.
```
to:
```
   - Weekly: release watch + probes for all eight agents.
```

- [ ] **Step 6: Commit**

```bash
git add docs/agent-support/agent-watch-config.json \
        docs/agent-support/agent-support-matrix.yml \
        docs/agent-support/agent-support-ledger.yml \
        docs/agent-json-tracking.md \
        docs/agent-support/workflow.md
git commit -m "docs(monitoring): register Cursor as 8th monitored agent

- agent-watch-config.json: cursor entry (cursor_transcript_newest + sqlite probe)
- agent-support-matrix.yml: cursor max_verified_version 2026.04.12
- agent-support-ledger.yml: initial cursor entry
- agent-json-tracking.md: initial Cursor monitoring log entry
- workflow.md: seven -> eight agents

Why: Cursor is a fully integrated session provider in AS; monitoring
was the only missing piece"
```

---

## Task 6: Skill doc updates

**Files:**
- Modify: `skills/agent-session-format-check/SKILL.md`
- Modify: `.claude/skills/agent-session-format-check.md`

- [ ] **Step 1: Add Cursor row to SKILL.md discovery contracts table**

In `skills/agent-session-format-check/SKILL.md` §4, find the contracts table and add a Cursor row:

```markdown
| Cursor   | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` |
```

- [ ] **Step 2: Add Cursor storage section to SKILL.md**

After the existing §3 (OpenCode Storage Changes), add a new section:

```markdown
---

## 3a  Cursor Storage

Cursor uses two storage backends:

- **JSONL transcripts** (`~/.cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl`) — primary session data, parsed by Agent Sessions. Subagent transcripts live in a `subagents/` subdirectory.
- **SQLite chat databases** (`~/.cursor/chats/<workspace-hash>/<uuid>/store.db`) — supplementary metadata (session name, model, timestamps). Key "0" in the `meta` table contains hex-encoded JSON.

The weekly scan fingerprints JSONL transcripts only. The SQLite probe (`cursor_sqlite_probe.py`) verifies the `meta` table is readable — it does not deep-fingerprint the database schema.

**What to watch for:**
- New top-level keys on `role: user/assistant` lines.
- New content block types beyond `text`, `tool_use`, `tool_result`, `thinking`.
- The `agent-transcripts/` directory being renamed or moved.
- SQLite probe failures indicating `meta` table schema changes.

**Note:** `cursor --version` returns null when the Cursor IDE is not installed. This is expected and not a monitoring failure.
```

- [ ] **Step 3: Add Cursor row to `.claude/skills/agent-session-format-check.md` quick-reference table**

Find the discovery contracts quick-reference table and add:

```markdown
| Cursor   | `~/.cursor/projects/**/.../agent-transcripts/**/*.jsonl` |
```

- [ ] **Step 4: Commit**

```bash
git add skills/agent-session-format-check/SKILL.md \
        .claude/skills/agent-session-format-check.md
git commit -m "docs(skill): add Cursor to agent-session-format-check skill

- Discovery contracts table: Cursor path
- New §3a: Cursor dual-backend storage notes (JSONL + SQLite)
- Quick-reference: Cursor row

Why: skill doc is the runbook for weekly checks; Cursor needs coverage"
```

---

## Task 7: Verification run

- [ ] **Step 1: Run the weekly scan**

```bash
cd /Users/alexm/Repository/Codex-History
./scripts/agent_watch.py --mode weekly --skip-update 2>&1
```

Expected stdout includes a line for cursor:
```
cursor: severity=none verified=2026.04.12 installed=None upstream=None ...
```

- [ ] **Step 2: Inspect the cursor section of the report**

```bash
python3 -c "
import json
from pathlib import Path
import glob
latest = max(glob.glob('scripts/probe_scan_output/agent_watch/*/report.json'))
r = json.load(open(latest))
c = r['results'].get('cursor', {})
print('severity:', c.get('severity'))
print('recommendation:', c.get('recommendation'))
print('schema_matches_baseline:', c.get('evidence', {}).get('schema_matches_baseline'))
print('discovery_ok:', c.get('weekly', {}).get('discovery_path_contract', {}).get('ok'))
print('sqlite_probe_ok:', next((p['ok'] for p in c.get('weekly', {}).get('probes', []) if p['label'] == 'cursor_sqlite_probe'), None))
"
```

Expected:
```
severity: none
recommendation: ignore
schema_matches_baseline: True
discovery_ok: True
sqlite_probe_ok: True
```

- [ ] **Step 3: Update ledger with actual report path**

Open `docs/agent-support/agent-support-ledger.yml` and replace `<slug>` in the cursor entry with the actual report directory slug (e.g. `20260412-190000Z`).

- [ ] **Step 4: Final commit**

```bash
git add docs/agent-support/agent-support-ledger.yml
git commit -m "docs(monitoring): record initial Cursor weekly scan evidence path

Why: ledger entry now points to real scan output"
```

---

## Self-Review

**Spec coverage:**
- §1 Fingerprinting function → Task 2 ✓
- §2 SQLite probe → Task 4 ✓
- §3 Config entry → Task 5 ✓
- §4 Fixtures (small, large, schema_drift, subagent) → Task 1 ✓
- §5a verified_map → Task 3 Step 1 ✓
- §5b weekly dispatcher → Task 3 Step 3 ✓
- §5c matrix-key evidence map → Task 3 Step 2 ✓
- §5d baseline fingerprinter → Task 3 Step 4 ✓
- §5e probe parse handler → Task 3 Step 5 ✓
- §6 Matrix/ledger/tracking → Task 5 ✓
- §7 Skill docs → Task 6 ✓
- workflow.md "seven→eight" → Task 5 Step 5 ✓
- Verification → Task 7 ✓

**Placeholder scan:** No TBDs found. The `<current-commit-hash>` and `<slug>` in Task 5 are intentional fill-in-after-execution markers, not placeholders.

**Type consistency:** `_cursor_transcript_schema_fingerprint()` is defined in Task 2 and called in Tasks 3 and 7. Signature is consistent throughout.
