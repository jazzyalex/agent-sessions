# Format Sweep Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the weekly format sweep run unattended end to end except two gates, and make it physically unable to lose a finding.

**Architecture:** A new `agent_format_tracker.py` owns an append-only JSONL finding log and an orchestrator that drives the existing `agent_watch.py` through two weekly snapshots with installs and prebumps in between. `rebuild_stage0_baseline.py` splits into a pure `build_plan()` and a hash-verifying `apply_plan()`. Session enumeration moves into one shared corpus layer so frequency counts and baseline rebuilds read the same sources.

**Tech Stack:** Python 3 stdlib only (no new dependencies), pytest, existing `scripts/agent-watch-config.json` schema.

**Spec:** `docs/superpowers/plans/2026-08-31-format-sweep-automation-SPEC.md`

## Global Constraints

- **No Swift files are modified.** `AgentSessionsTests/Stage0GoldenFixturesTests.swift` is read and referenced only. (SPEC §10)
- **No new Python dependencies.** stdlib only; the sweep runs on a bare machine.
- **Two gates, never more.** Fixture apply and version claim. Backlog acceptance is post-sweep product triage, not a gate. (SPEC §6)
- **Unattended mode may build a plan; it may never apply one.** (SPEC §3.1)
- **Never install unless a session can be generated afterward.** (SPEC §5a, SKILL §1b)
- **Ledger patches must contain zero deletions.** (SPEC §3.2)
- **Pre-2026-09-01 content in `docs/agent-json-tracking.md` stays byte-for-byte frozen.** (SPEC §7)
- Tests live in `scripts/tests/`, import modules bare (`import agent_watch`) via the existing `conftest.py` path insert, and use `tmp_path`.
- Run tests with `pytest -q scripts/tests`. No Xcode build is required for any task here.

---

### Task 1: Tracker record protocol

**Files:**
- Create: `scripts/agent_format_tracker.py`
- Test: `scripts/tests/test_agent_format_tracker.py`

**Interfaces:**
- Consumes: nothing (foundation task)
- Produces: `append(path: Path, record: dict) -> str` returning the `record_id`; `read_all(path: Path) -> list[dict]`; `ValidationError`; constants `EVENTS = ("discovered","triaged","corrected","action_applied")`, `CONFIDENCE = ("verified","assumed")`, `SCHEMA_VERSION = 1`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_format_tracker.py
"""
The tracker exists because the 2026-08-31 sweep's findings survived only by manual
transcription. Every rule here pins something that went wrong that day.
"""
import json
import pytest

import agent_format_tracker as t


def test_append_returns_a_unique_record_id_and_writes_one_line(tmp_path):
    log = tmp_path / "tracker.jsonl"
    a = t.append(log, {"event": "discovered", "run_id": "r1", "agent": "codex",
                       "finding_id": "codex/x", "confidence": "verified",
                       "evidence": []})
    b = t.append(log, {"event": "discovered", "run_id": "r1", "agent": "codex",
                       "finding_id": "codex/y", "confidence": "verified",
                       "evidence": []})
    assert a != b
    rows = [json.loads(l) for l in log.read_text().splitlines()]
    assert [r["record_id"] for r in rows] == [a, b]
    assert all(r["schema_version"] == t.SCHEMA_VERSION for r in rows)


def test_confidence_is_mandatory(tmp_path):
    # "opencode: provider-side outage" was recorded on 2026-08-31 with the same
    # authority as measured fact, and was wrong. An unstamped claim is refused.
    with pytest.raises(t.ValidationError):
        t.append(tmp_path / "x.jsonl", {"event": "discovered", "run_id": "r",
                                        "agent": "a", "finding_id": "a/f",
                                        "evidence": []})


def test_ts_is_microsecond_utc(tmp_path):
    log = tmp_path / "tracker.jsonl"
    t.append(log, {"event": "discovered", "run_id": "r", "agent": "a",
                   "finding_id": "a/f", "confidence": "verified", "evidence": []})
    ts = json.loads(log.read_text())["ts"]
    assert ts.endswith("Z") and "." in ts and len(ts.split(".")[1]) == 7
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_format_tracker.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'agent_format_tracker'`

- [ ] **Step 3: Write minimal implementation**

```python
# scripts/agent_format_tracker.py
"""Append-only finding log for the agent format sweep.

JSONL, not YAML: on 2026-08-31 a ledger edit merged two YAML entries into one
mapping with duplicate keys, and YAML keeps the last -- the file parsed cleanly
while the newly written record vanished. An append-only JSONL log cannot merge.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import uuid
from pathlib import Path

SCHEMA_VERSION = 1
EVENTS = ("discovered", "triaged", "corrected", "action_applied")
CONFIDENCE = ("verified", "assumed")
_REQUIRED = ("event", "run_id", "agent", "finding_id", "confidence", "evidence")


class ValidationError(ValueError):
    pass


def _utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def _validate(rec: dict) -> None:
    for k in _REQUIRED:
        if k not in rec:
            raise ValidationError(f"missing required field: {k}")
    if rec["event"] not in EVENTS:
        raise ValidationError(f"unknown event: {rec['event']}")
    if rec["confidence"] not in CONFIDENCE:
        raise ValidationError(f"confidence must be one of {CONFIDENCE}")
    if not isinstance(rec["evidence"], list):
        raise ValidationError("evidence must be a list")


def append(path: Path, record: dict) -> str:
    rec = dict(record)
    _validate(rec)
    rec["schema_version"] = SCHEMA_VERSION
    rec["record_id"] = str(uuid.uuid4())
    rec["ts"] = _utc_now()
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(rec, sort_keys=True) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    return rec["record_id"]


def read_all(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_format_tracker.py`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_format_tracker.py scripts/tests/test_agent_format_tracker.py
git commit -m "feat(tracker): append-only JSONL finding log with mandatory confidence"
```

---

### Task 2: Durability and correction chains

**Files:**
- Modify: `scripts/agent_format_tracker.py`
- Test: `scripts/tests/test_agent_format_tracker.py`

**Interfaces:**
- Consumes: `append`, `read_all`, `ValidationError` from Task 1
- Produces: `supersedes` validation; `findings(path) -> dict[str, list[dict]]` grouping records by `finding_id` in append order

- [ ] **Step 1: Write the failing test**

```python
def test_supersedes_must_reference_an_existing_record_id(tmp_path):
    # The first spec draft referenced a second-resolution timestamp, which is not
    # unique. Identity is a UUID record_id.
    log = tmp_path / "t.jsonl"
    with pytest.raises(t.ValidationError):
        t.append(log, {"event": "corrected", "run_id": "r", "agent": "a",
                       "finding_id": "a/f", "confidence": "verified",
                       "evidence": [], "supersedes": "not-a-real-id"})


def test_correction_preserves_the_original(tmp_path):
    log = tmp_path / "t.jsonl"
    first = t.append(log, {"event": "discovered", "run_id": "r", "agent": "opencode",
                           "finding_id": "opencode/driver", "confidence": "assumed",
                           "evidence": [], "observation": "provider-side outage"})
    t.append(log, {"event": "corrected", "run_id": "r2", "agent": "opencode",
                   "finding_id": "opencode/driver", "confidence": "verified",
                   "evidence": ["log.txt"], "supersedes": first,
                   "observation": "credential_files was empty; sandbox had no auth"})
    chain = t.findings(log)["opencode/driver"]
    assert len(chain) == 2
    assert chain[0]["observation"] == "provider-side outage"
    assert chain[1]["supersedes"] == first


def test_concurrent_appends_do_not_interleave(tmp_path):
    import threading
    log = tmp_path / "t.jsonl"

    def w(i):
        t.append(log, {"event": "discovered", "run_id": "r", "agent": f"a{i}",
                       "finding_id": f"a{i}/f", "confidence": "verified", "evidence": []})

    threads = [threading.Thread(target=w, args=(i,)) for i in range(20)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    rows = t.read_all(log)
    assert len(rows) == 20
    assert len({r["record_id"] for r in rows}) == 20
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_format_tracker.py -k "supersedes or correction or concurrent"`
Expected: FAIL — `AttributeError: module 'agent_format_tracker' has no attribute 'findings'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/agent_format_tracker.py`:

```python
def _existing_ids(path: Path) -> set[str]:
    return {r["record_id"] for r in read_all(path)}


def findings(path: Path) -> dict[str, list[dict]]:
    """Group records by finding_id, preserving append order."""
    out: dict[str, list[dict]] = {}
    for r in read_all(path):
        out.setdefault(r["finding_id"], []).append(r)
    return out
```

In `append`, after `_validate(rec)`:

```python
    sup = rec.get("supersedes")
    if sup is not None and sup not in _existing_ids(path):
        raise ValidationError(f"supersedes references unknown record_id: {sup}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_format_tracker.py`
Expected: 6 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_format_tracker.py scripts/tests/test_agent_format_tracker.py
git commit -m "feat(tracker): validate correction chains by record_id"
```

---

### Task 3: Shared corpus layer

**Highest-risk task — SPEC §11.** `rebuild_stage0_baseline._all_sessions` reads only
`weekly.local_schema.roots` + `glob` and never `db_roots`, so for OpenCode it sweeps a
stale legacy JSON tree instead of `opencode.db`. Already filed at `docs/backlog.md:578`.
Every frequency measurement the triage depends on is wrong if this is wrong.

**Files:**
- Create: `scripts/agent_corpus.py`
- Modify: `scripts/rebuild_stage0_baseline.py:103-115` (`_all_sessions` delegates)
- Test: `scripts/tests/test_agent_corpus.py`

**Interfaces:**
- Consumes: nothing
- Produces: `enumerate_sessions(agent: str, cfg: dict, limit: int | None = None) -> list[Path]`; `count_field(agent, cfg, predicate) -> dict` returning `{"records": int, "sessions": int, "of_sessions": int}`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_corpus.py
"""
One enumeration path for weekly scanning, frequency counting and baseline rebuilds.
Filed as docs/backlog.md:578 -- the rebuild helper ignored db_roots and swept the
wrong OpenCode store, then reported "fixture already covers everything".
"""
import json

import agent_corpus


def _cfg(roots, glob="*.jsonl", db_roots=None):
    ls = {"roots": roots, "glob": glob}
    if db_roots:
        ls["db_roots"] = db_roots
    return {"agents": {"x": {"weekly": {"local_schema": ls}}}}


def test_enumerate_follows_db_roots_when_present(tmp_path):
    db = tmp_path / "store.db"
    db.write_bytes(b"SQLite format 3\x00")
    legacy = tmp_path / "legacy"
    legacy.mkdir()
    (legacy / "old.jsonl").write_text("{}\n")
    cfg = _cfg([str(legacy)], db_roots=[str(tmp_path)])
    found = agent_corpus.enumerate_sessions("x", cfg)
    assert db in found, "db_roots must be swept, not just roots/glob"


def test_count_field_reports_all_three_denominators(tmp_path):
    for i, rows in enumerate([[{"a": 1}, {"a": 2}], [{"b": 1}], [{"a": 3}]]):
        (tmp_path / f"s{i}.jsonl").write_text(
            "\n".join(json.dumps(r) for r in rows) + "\n")
    cfg = _cfg([str(tmp_path)])
    got = agent_corpus.count_field("x", cfg, lambda rec: "a" in rec)
    assert got == {"records": 3, "sessions": 2, "of_sessions": 3}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_corpus.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'agent_corpus'`

- [ ] **Step 3: Write minimal implementation**

```python
# scripts/agent_corpus.py
"""One session-enumeration path for every consumer.

Split sources exist: JSONL trees, SQLite stores (opencode.db, cursor store.db) and
bespoke layouts. rebuild_stage0_baseline used to read only roots+glob, which is how
it swept OpenCode's stale legacy tree and reported full coverage (docs/backlog.md:578).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Callable


def _local_schema(agent: str, cfg: dict) -> dict:
    return cfg.get("agents", {}).get(agent, {}).get("weekly", {}).get("local_schema", {}) or {}


def enumerate_sessions(agent: str, cfg: dict, limit: int | None = None) -> list[Path]:
    ls = _local_schema(agent, cfg)
    found: list[Path] = []
    for root in ls.get("db_roots") or []:
        p = Path(root).expanduser()
        found.extend(sorted(x for x in p.rglob("*.db") if x.is_file()))
    glob = ls.get("glob") or "**/*.jsonl"
    for root in ls.get("roots") or []:
        p = Path(root).expanduser()
        found.extend(sorted(x for x in p.glob(glob) if x.is_file()))
    found.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return found[:limit] if limit else found


def count_field(agent: str, cfg: dict, predicate: Callable[[dict], bool]) -> dict:
    records = sessions = examined = 0
    for path in enumerate_sessions(agent, cfg):
        if path.suffix == ".db":
            continue
        examined += 1
        hit = False
        for line in path.read_text(errors="replace").splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if predicate(rec):
                records += 1
                hit = True
        if hit:
            sessions += 1
    return {"records": records, "sessions": sessions, "of_sessions": examined}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_corpus.py`
Expected: 2 passed

- [ ] **Step 5: Point the rebuild tool at it**

In `scripts/rebuild_stage0_baseline.py`, replace the body of `_all_sessions` (line 103) with:

```python
def _all_sessions(agent: str, cfg: dict, limit: int | None) -> list[Path]:
    import agent_corpus
    return agent_corpus.enumerate_sessions(agent, cfg, limit)
```

- [ ] **Step 6: Run the full Python suite for regressions**

Run: `pytest -q scripts/tests`
Expected: all pass. If `test_steward_check.py` or a rebuild test fails, the corpus
layer changed which sessions are swept — that is the point, but confirm the change is
the OpenCode `db_roots` fix and not a regression for a JSONL agent.

- [ ] **Step 7: Commit**

```bash
git add scripts/agent_corpus.py scripts/tests/test_agent_corpus.py scripts/rebuild_stage0_baseline.py
git commit -m "fix(corpus): one enumeration path that honours db_roots"
```

---

### Task 4: Frozen-history renderer

**Files:**
- Create: `docs/agent-support/agent-format-tracker.jsonl` (empty)
- Modify: `docs/agent-json-tracking.md` (append markers only; existing content untouched)
- Modify: `scripts/agent_format_tracker.py`
- Test: `scripts/tests/test_agent_format_tracker_render.py`

**Interfaces:**
- Consumes: `findings`, `read_all` from Tasks 1-2
- Produces: `render(tracker: Path, doc: Path) -> str`; `check(tracker, doc) -> bool`; constants `BEGIN = "<!-- BEGIN tracker-derived history -->"`, `END = "<!-- END tracker-derived history -->"`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_format_tracker_render.py
"""
docs/agent-json-tracking.md holds years of hand-written history that cannot be
reconstructed from a tracker that did not exist when it happened. It is frozen;
the renderer owns only the marked section.
"""
import agent_format_tracker as t


def _doc(tmp_path, legacy="- 2026-08-21: hand written, must never change\n"):
    d = tmp_path / "tracking.md"
    d.write_text(f"# Log\n\n{legacy}\n{t.BEGIN}\n{t.END}\n")
    return d


def test_render_leaves_legacy_history_byte_for_byte(tmp_path):
    doc = _doc(tmp_path)
    before = doc.read_text().split(t.BEGIN)[0]
    log = tmp_path / "tr.jsonl"
    t.append(log, {"event": "triaged", "run_id": "r", "agent": "codex",
                   "finding_id": "codex/f", "confidence": "verified",
                   "evidence": [], "bucket": "log only",
                   "observation": "ordinal on one more record type"})
    t.render(log, doc)
    assert doc.read_text().split(t.BEGIN)[0] == before


def test_check_fails_when_the_committed_view_is_stale(tmp_path):
    doc = _doc(tmp_path)
    log = tmp_path / "tr.jsonl"
    t.append(log, {"event": "triaged", "run_id": "r", "agent": "codex",
                   "finding_id": "codex/f", "confidence": "verified",
                   "evidence": [], "bucket": "urgent", "observation": "x"})
    assert t.check(log, doc) is False
    t.render(log, doc)
    assert t.check(log, doc) is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_format_tracker_render.py`
Expected: FAIL — `AttributeError: module 'agent_format_tracker' has no attribute 'BEGIN'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/agent_format_tracker.py`:

```python
BEGIN = "<!-- BEGIN tracker-derived history -->"
END = "<!-- END tracker-derived history -->"


def _rendered(tracker: Path) -> str:
    lines = []
    for finding_id, chain in findings(tracker).items():
        last = chain[-1]
        bucket = last.get("bucket", "untriaged")
        note = last.get("observation", "")
        flag = "" if last.get("confidence") == "verified" else " *(assumed)*"
        lines.append(f"- `{finding_id}` — **{bucket}**{flag}: {note}")
        for rec in chain:
            if rec.get("supersedes"):
                lines.append(f"  - corrected: {rec.get('observation','')}")
    return "\n".join(lines) + ("\n" if lines else "")


def render(tracker: Path, doc: Path) -> str:
    text = doc.read_text(encoding="utf-8")
    head, _, tail = text.partition(BEGIN)
    _, _, after = tail.partition(END)
    out = f"{head}{BEGIN}\n{_rendered(tracker)}{END}{after}"
    doc.write_text(out, encoding="utf-8")
    return out


def check(tracker: Path, doc: Path) -> bool:
    text = doc.read_text(encoding="utf-8")
    _, _, tail = text.partition(BEGIN)
    body, _, _ = tail.partition(END)
    return body == "\n" + _rendered(tracker)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_format_tracker_render.py`
Expected: 2 passed

- [ ] **Step 5: Add the markers to the real doc and create the log**

Append to the very end of `docs/agent-json-tracking.md` (nothing above it changes):

```markdown

<!-- BEGIN tracker-derived history -->
<!-- END tracker-derived history -->
```

Then: `touch docs/agent-support/agent-format-tracker.jsonl`

- [ ] **Step 6: Verify the frozen content is untouched**

Run: `git diff --numstat docs/agent-json-tracking.md`
Expected: additions only, `0` in the deletions column.

- [ ] **Step 7: Commit**

```bash
git add scripts/agent_format_tracker.py scripts/tests/test_agent_format_tracker_render.py docs/agent-json-tracking.md docs/agent-support/agent-format-tracker.jsonl
git commit -m "feat(tracker): render into a marked section, freeze legacy history"
```

---

### Task 5: Batched auth preflight

**Files:**
- Modify: `scripts/agent_watch_prebump_drivers.py:229-254` (extract a side-effect-free credential check)
- Modify: `scripts/agent_watch.py` (add `--mode preflight`)
- Modify: `docs/agent-support/agent-watch-config.json` (per-agent `preflight` block)
- Test: `scripts/tests/test_agent_watch_preflight.py`

**Interfaces:**
- Consumes: `enumerate_sessions` (not required, but the config loader is shared)
- Produces: `preflight(cfg: dict, agents: list[str]) -> dict` mapping agent → `{"credential_present": bool, "authenticated": bool | None, "category": "ready"|"fixable_ours"|"fixable_theirs"|"not_fixable", "action": str}`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_watch_preflight.py
"""
On 2026-08-31 four auth failures surfaced hours apart, each stopping a different
pass. Preflight batches them into one report before any agent work begins.
"""
import agent_watch


def _cfg(**agents):
    return {"agents": {k: {"prebump": v} for k, v in agents.items()}}


def test_two_unauthenticated_agents_appear_in_one_report(tmp_path):
    cfg = _cfg(
        grok={"credential_files": [str(tmp_path / "missing.json")]},
        qwen={"credential_files": [str(tmp_path / "also-missing.json")]},
    )
    out = agent_watch.preflight(cfg, ["grok", "qwen"])
    assert set(out) == {"grok", "qwen"}
    assert all(not out[a]["credential_present"] for a in ("grok", "qwen"))


def test_credential_presence_is_not_authentication(tmp_path):
    # opencode's credential_files was EMPTY, so the sandbox had no auth at all and
    # the backend reported an opaque UnknownError that read as a vendor outage.
    cred = tmp_path / "auth.json"
    cred.write_text("{}")
    cred.chmod(0o600)
    out = agent_watch.preflight(_cfg(opencode={"credential_files": [str(cred)]}), ["opencode"])
    assert out["opencode"]["credential_present"] is True
    assert out["opencode"]["authenticated"] is None, "presence must not imply auth"


def test_preflight_generates_no_session(tmp_path, monkeypatch):
    called = []
    monkeypatch.setattr(agent_watch, "_run_prebump", lambda *a, **k: called.append(a))
    agent_watch.preflight(_cfg(codex={"credential_files": []}), ["codex"])
    assert called == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_watch_preflight.py`
Expected: FAIL — `AttributeError: module 'agent_watch' has no attribute 'preflight'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/agent_watch.py`:

```python
def preflight(cfg: dict, agents: list[str]) -> dict:
    """Probe every agent's credential path. Generates nothing, prints no secrets.

    `credential_present` and `authenticated` are DIFFERENT facts. Conflating them
    produced the 2026-08-31 opencode misdiagnosis: an empty credential_files meant
    the sandbox had no auth, and the backend reported that as an opaque server error.
    """
    from pathlib import Path
    out = {}
    for agent in agents:
        pb = cfg.get("agents", {}).get(agent, {}).get("prebump", {}) or {}
        creds = [Path(p).expanduser() for p in (pb.get("credential_files") or [])]
        present = bool(creds) and all(p.exists() for p in creds)
        out[agent] = {
            "credential_present": present,
            "authenticated": None,          # only a real driver run can prove this
            "category": "ready" if present else "fixable_ours",
            "action": "" if present else f"no credential file declared or found for {agent}",
        }
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_watch_preflight.py`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_watch.py scripts/tests/test_agent_watch_preflight.py
git commit -m "feat(preflight): batch credential checks before any agent work"
```

---

### Task 6: Discovery appends from inside the scan

**Files:**
- Modify: `scripts/agent_watch.py` (add `--run-id` and `--tracker`; append at the point a new type/key is confirmed)
- Test: `scripts/tests/test_agent_watch_tracker_hook.py`

**Interfaces:**
- Consumes: `agent_format_tracker.append` (Task 1)
- Produces: `record_discovery(tracker, run_id, agent, kind, field, evidence) -> str | None`, returning `None` when the finding was already recorded for this `(run_id, agent, kind, field)`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_watch_tracker_hook.py
"""
A finding is appended the instant it is confirmed, not at the end of the pass.
If the process dies mid-agent, everything found so far is already on disk.
"""
import agent_format_tracker as t
import agent_watch


def test_discovery_is_appended_before_the_run_finishes(tmp_path):
    log = tmp_path / "tr.jsonl"
    agent_watch.record_discovery(log, "r1", "claude", "schema_drift",
                                 "cost-state.modelUsage", ["report.json"])
    rows = t.read_all(log)
    assert len(rows) == 1
    assert rows[0]["event"] == "discovered"
    assert rows[0]["confidence"] == "verified"
    assert rows[0]["finding_id"] == "claude/cost-state.modelUsage"


def test_retries_do_not_duplicate_a_finding(tmp_path):
    log = tmp_path / "tr.jsonl"
    a = agent_watch.record_discovery(log, "r1", "claude", "schema_drift", "f", [])
    b = agent_watch.record_discovery(log, "r1", "claude", "schema_drift", "f", [])
    assert a is not None and b is None
    assert len(t.read_all(log)) == 1


def test_a_different_run_records_the_finding_again(tmp_path):
    log = tmp_path / "tr.jsonl"
    agent_watch.record_discovery(log, "r1", "claude", "schema_drift", "f", [])
    agent_watch.record_discovery(log, "r2", "claude", "schema_drift", "f", [])
    assert len(t.read_all(log)) == 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_watch_tracker_hook.py`
Expected: FAIL — `AttributeError: module 'agent_watch' has no attribute 'record_discovery'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/agent_watch.py`:

```python
def record_discovery(tracker, run_id: str, agent: str, kind: str,
                     field: str, evidence: list) -> str | None:
    """Append a `discovered` event immediately. Idempotent per (run_id, agent, kind, field)."""
    import agent_format_tracker as _t
    finding_id = f"{agent}/{field}"
    for rec in _t.read_all(tracker):
        if (rec.get("run_id") == run_id and rec.get("agent") == agent
                and rec.get("kind") == kind and rec.get("finding_id") == finding_id):
            return None
    return _t.append(tracker, {
        "event": "discovered", "run_id": run_id, "agent": agent,
        "finding_id": finding_id, "kind": kind, "field": field,
        "confidence": "verified", "evidence": list(evidence),
    })
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_watch_tracker_hook.py`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_watch.py scripts/tests/test_agent_watch_tracker_hook.py
git commit -m "feat(sweep): append discoveries during the scan, not after it"
```

---

### Task 7: Fixture patch manifest (Gate 1)

**Files:**
- Modify: `scripts/rebuild_stage0_baseline.py:186-240` (split `--emit` into `build_plan` / `apply_plan`)
- Test: `scripts/tests/test_rebuild_plan_apply.py`

**Interfaces:**
- Consumes: `enumerate_sessions` (Task 3)
- Produces: `build_plan(agent, cfg) -> dict` with keys `lines`, `fixture_base_sha256`, `source_manifest`, `pairs`, `suspected_variable_key_maps`; `apply_plan(plan, target: Path) -> None` raising `StaleP1anError` on any hash mismatch

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_rebuild_plan_apply.py
"""
Reviewing a report and then re-running --emit reviews one thing and applies another:
the second run re-harvests a corpus that may have moved. The plan is immutable and
hash-verified.
"""
import json
import pytest

import rebuild_stage0_baseline as r


def test_apply_refuses_when_a_source_session_changed(tmp_path):
    src = tmp_path / "s.jsonl"
    src.write_text(json.dumps({"type": "a", "k": 1}) + "\n")
    fixture = tmp_path / "small.jsonl"
    fixture.write_text("")
    plan = r.build_plan_from_paths([src], fixture)
    src.write_text(json.dumps({"type": "a", "k": 2}) + "\n")   # corpus moved
    with pytest.raises(r.StalePlanError):
        r.apply_plan(plan, fixture)


def test_apply_refuses_when_the_fixture_changed(tmp_path):
    src = tmp_path / "s.jsonl"
    src.write_text(json.dumps({"type": "a"}) + "\n")
    fixture = tmp_path / "small.jsonl"
    fixture.write_text("")
    plan = r.build_plan_from_paths([src], fixture)
    fixture.write_text('{"type":"someone-else"}\n')
    with pytest.raises(r.StalePlanError):
        r.apply_plan(plan, fixture)


def test_plan_flags_a_bucket_whose_key_set_varies(tmp_path):
    # The structural check that caught artifacts, modelUsage and models on 2026-08-31.
    src = tmp_path / "s.jsonl"
    src.write_text("\n".join(json.dumps(x) for x in [
        {"type": "m", "models": {"claude-haiku-4.5": {}}},
        {"type": "m", "models": {"gpt-5.6-sol": {}}},
    ]) + "\n")
    fixture = tmp_path / "small.jsonl"
    fixture.write_text("")
    plan = r.build_plan_from_paths([src], fixture)
    assert "models" in plan["suspected_variable_key_maps"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_rebuild_plan_apply.py`
Expected: FAIL — `AttributeError: module 'rebuild_stage0_baseline' has no attribute 'build_plan_from_paths'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/rebuild_stage0_baseline.py`:

```python
import hashlib


class StalePlanError(RuntimeError):
    """The corpus or the fixture moved between building and applying a plan."""


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _variable_key_maps(records: list[dict]) -> list[str]:
    """Buckets whose key set differs across records -- the signature of a free-form map.

    Needs no threshold, which is why it is the gate's authority until the fixture
    audit in SPEC 3.1 defines one.
    """
    seen: dict[str, list[frozenset]] = {}
    def walk(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, dict):
                    seen.setdefault(k, []).append(frozenset(v.keys()))
                    walk(v)
        elif isinstance(obj, list):
            for i in obj:
                walk(i)
    for rec in records:
        walk(rec)
    return sorted(k for k, sets in seen.items() if len({s for s in sets}) > 1)


def build_plan_from_paths(sources: list[Path], fixture: Path) -> dict:
    records = []
    for p in sources:
        for line in p.read_text(errors="replace").splitlines():
            if line.strip():
                try:
                    records.append(json.loads(line))
                except ValueError:
                    pass
    return {
        # _redact(value, opaque: frozenset[str], key=None) -- rebuild_stage0_baseline.py:116.
        # Pass the agent's real opaque set at the callsite; frozenset() here means
        # "no opaque keys", which is only correct for the isolated unit test.
        "lines": [json.dumps(_redact(r, frozenset(), None), sort_keys=True) for r in records],
        "fixture_base_sha256": _sha256(fixture),
        "source_manifest": {str(p): _sha256(p) for p in sources},
        "pairs": [],
        "suspected_variable_key_maps": _variable_key_maps(records),
    }


def apply_plan(plan: dict, fixture: Path) -> None:
    if _sha256(fixture) != plan["fixture_base_sha256"]:
        raise StalePlanError(f"fixture changed since the plan was built: {fixture}")
    for path, digest in plan["source_manifest"].items():
        p = Path(path)
        if not p.exists() or _sha256(p) != digest:
            raise StalePlanError(f"source session changed since the plan was built: {path}")
    with fixture.open("a", encoding="utf-8") as fh:
        for line in plan["lines"]:
            fh.write(line + "\n")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_rebuild_plan_apply.py`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/rebuild_stage0_baseline.py scripts/tests/test_rebuild_plan_apply.py
git commit -m "feat(gate1): hash-verified fixture patch manifest"
```

---

### Task 8: Version-claim proposals (Gate 2)

**Files:**
- Create: `scripts/agent_version_claim.py`
- Test: `scripts/tests/test_agent_version_claim.py`

**Interfaces:**
- Consumes: a weekly report dict (`results.<agent>`), the post-run installed version
- Produces: `propose(agent: str, result: dict, installed_now: str) -> dict | None` returning `None` with a `reason` logged when refused, else `{"from","to","assertions":[str],"refusals":[]}`

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_version_claim.py
"""
max_verified_version asserts the app parses sessions WRITTEN BY that build. Every
refusal here is a real 2026-08-31 near-miss.
"""
import agent_version_claim as c


def _result(**kw):
    base = {
        "verified_version": "1.1.14",
        "installed": {"parsed_version": "1.1.22"},
        "upstream": {"parsed_version": "1.1.22"},
        "evidence": {"fresh_evidence_source": "latest_prebump_report",
                     "sample_freshness": {"sample_mtime_utc": "2026-08-31T17:10:18Z",
                                          "cli_binary_mtime_utc": "2026-08-31T06:02:37Z"}},
        "compatibility": {"blockers": [], "latest_real_session_evidence": True},
    }
    base.update(kw)
    return base


def test_proposes_with_checkable_assertions():
    p = c.propose("antigravity", _result(), installed_now="1.1.22")
    assert p["from"] == "1.1.14" and p["to"] == "1.1.22"
    assert any("sample mtime" in a for a in p["assertions"])


def test_refuses_when_prebump_failed():
    r = _result(compatibility={"blockers": ["real_session_auth_failed"],
                               "latest_real_session_evidence": False})
    assert c.propose("antigravity", r, installed_now="1.1.22") is None


def test_refuses_an_upstream_only_target():
    # pi was correctly bumped to installed 0.84.3, never to an uninstalled upstream.
    r = _result(installed={"parsed_version": "0.84.3"},
                upstream={"parsed_version": "0.84.4"},
                verified_version="0.84.2")
    p = c.propose("pi", r, installed_now="0.84.3")
    assert p["to"] == "0.84.3", "must claim installed, never merely available"


def test_refuses_when_installed_changed_after_the_proposal():
    # grok and pi both self-updated mid-sweep on 2026-08-31.
    assert c.propose("grok", _result(), installed_now="1.1.23") is None


def test_refuses_when_evidence_predates_the_binary():
    r = _result(evidence={"fresh_evidence_source": "latest_prebump_report",
                          "sample_freshness": {"sample_mtime_utc": "2026-08-31T05:00:00Z",
                                               "cli_binary_mtime_utc": "2026-08-31T06:02:37Z"}})
    assert c.propose("antigravity", r, installed_now="1.1.22") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_version_claim.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'agent_version_claim'`

- [ ] **Step 3: Write minimal implementation**

```python
# scripts/agent_version_claim.py
"""Build a version-bump proposal, or refuse with a reason.

A verdict string is not evidence. Every assertion here is one the maintainer can
check on one screen.
"""
from __future__ import annotations


def propose(agent: str, result: dict, installed_now: str) -> dict | None:
    installed = (result.get("installed") or {}).get("parsed_version")
    if installed != installed_now:
        return None                      # CLI self-updated after the proposal was built
    verified = result.get("verified_version")
    if not installed or installed == verified:
        return None
    comp = result.get("compatibility") or {}
    if comp.get("blockers"):
        return None
    if not comp.get("latest_real_session_evidence"):
        return None
    ev = result.get("evidence") or {}
    fr = ev.get("sample_freshness") or {}
    sample, binary = fr.get("sample_mtime_utc"), fr.get("cli_binary_mtime_utc")
    if not sample or not binary or sample <= binary:
        return None                      # not written by the installed build
    return {
        "from": verified,
        "to": installed,                 # installed, never upstream-only
        "assertions": [
            f"fresh_evidence_source        = {ev.get('fresh_evidence_source')}",
            f"latest_real_session_evidence = {comp.get('latest_real_session_evidence')}",
            f"blockers                     = {comp.get('blockers')}",
            f"sample mtime {sample} > cli binary mtime {binary}",
        ],
        "refusals": [],
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_version_claim.py`
Expected: 5 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_version_claim.py scripts/tests/test_agent_version_claim.py
git commit -m "feat(gate2): version-claim proposals with checkable assertions"
```

---

### Task 9: Install eligibility

**Files:**
- Create: `scripts/agent_install.py`
- Test: `scripts/tests/test_agent_install.py`

**Interfaces:**
- Consumes: preflight output (Task 5), a weekly report dict
- Produces: `eligible(agent, result, preflight_row, cfg) -> tuple[bool, str]` — `(False, reason)` when refused

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_install.py
"""
SKILL 1b: never install unless a session can be generated afterward. Installing
rewrites nothing on disk, so the newest session is still the one the OLD build
wrote -- the agent flips from supports_installed_only, a real claim, to
blocked_stale_sample, which means unknown.
"""
import agent_install


CFG = {"agents": {"hermes": {"install": {"kind": "npm_global", "package": "h"},
                             "prebump": {"driver": "hermes_oneshot"}},
                  "antigravity": {"install": {"kind": "vendor_updater", "package": "agy"},
                                  "prebump": {"driver": "antigravity_print",
                                              "real_home_session": True}},
                  "kimi": {"install": {"kind": "npm_global", "package": "k"},
                           "prebump": {"driver": "kimi_prompt"}}}}


def _res(installed, upstream, thin=False):
    return {"installed": {"parsed_version": installed},
            "upstream": {"parsed_version": upstream},
            "compatibility": {"verdict": "blocked_thin_sample" if thin else "supports_installed_only"}}


def test_refuses_when_the_driver_does_not_work():
    # Hermes: upstream 0.20.6, installed 0.17.0, driver produces no usable sample.
    ok, why = agent_install.eligible(
        "hermes", _res("0.17.0", "0.20.6"), {"driver_ok": False}, CFG)
    assert ok is False and "driver" in why


def test_refuses_a_thin_real_home_store():
    ok, why = agent_install.eligible(
        "antigravity", _res("1.1.14", "1.1.22", thin=True), {"driver_ok": True}, CFG)
    assert ok is False and "thin" in why


def test_allows_when_all_four_checks_hold():
    ok, why = agent_install.eligible(
        "kimi", _res("0.38.0", "0.39.1"), {"driver_ok": True}, CFG)
    assert ok is True and why == ""


def test_refuses_without_a_declared_install_block():
    ok, why = agent_install.eligible(
        "grok", _res("1.0.5", "1.0.13"), {"driver_ok": True}, {"agents": {"grok": {}}})
    assert ok is False and "install" in why
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_install.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'agent_install'`

- [ ] **Step 3: Write minimal implementation**

```python
# scripts/agent_install.py
"""Install eligibility. Four checks, all must hold (SPEC 5a)."""
from __future__ import annotations


def eligible(agent: str, result: dict, preflight_row: dict, cfg: dict) -> tuple[bool, str]:
    a = cfg.get("agents", {}).get(agent, {}) or {}
    installed = (result.get("installed") or {}).get("parsed_version")
    upstream = (result.get("upstream") or {}).get("parsed_version")
    if not upstream or upstream == installed:
        return False, "no newer upstream version"
    if not a.get("install"):
        return False, "no install block declared in agent-watch-config.json"
    if not preflight_row.get("driver_ok"):
        return False, ("prebump driver did not succeed in preflight; installing would "
                       "convert a real claim into blocked_stale_sample")
    pb = a.get("prebump") or {}
    if pb.get("real_home_session") and \
            (result.get("compatibility") or {}).get("verdict") == "blocked_thin_sample":
        return False, "thin real-home store; session generation is refused, so the install is too"
    return True, ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_install.py`
Expected: 4 passed

- [ ] **Step 5: Commit**

```bash
git add scripts/agent_install.py scripts/tests/test_agent_install.py
git commit -m "feat(install): four-check eligibility, refuse without a working driver"
```

---

### Task 10: Orchestrator and skill update

**Files:**
- Modify: `scripts/agent_format_tracker.py` (add `run()` and CLI entry)
- Modify: `skills/agent-session-format-check/SKILL.md`
- Test: `scripts/tests/test_agent_format_tracker_run.py`

**Interfaces:**
- Consumes: everything above
- Produces: `run(cfg, *, snapshot, install, prebump, tracker, run_id) -> dict` — the injected callables make the ordering testable without running a real sweep

- [ ] **Step 1: Write the failing test**

```python
# scripts/tests/test_agent_format_tracker_run.py
"""
Ordering is the point: thinness and staleness are computed FROM the fingerprint,
so the first draft's "generate, then fingerprint" was impossible.
"""
import agent_format_tracker as t


def test_two_snapshots_with_install_and_prebump_between(tmp_path):
    order = []
    t.run(
        {"agents": {}},
        snapshot=lambda: order.append("snapshot") or {"results": {}},
        install=lambda snap: order.append("install") or [],
        prebump=lambda snap, installed: order.append("prebump") or {},
        tracker=tmp_path / "tr.jsonl",
        run_id="r1",
    )
    assert order == ["snapshot", "install", "prebump", "snapshot"]


def test_run_appends_nothing_when_there_are_no_findings(tmp_path):
    log = tmp_path / "tr.jsonl"
    t.run({"agents": {}}, snapshot=lambda: {"results": {}},
          install=lambda s: [], prebump=lambda s, i: {},
          tracker=log, run_id="r1")
    assert t.read_all(log) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest -q scripts/tests/test_agent_format_tracker_run.py`
Expected: FAIL — `AttributeError: module 'agent_format_tracker' has no attribute 'run'`

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/agent_format_tracker.py`:

```python
def run(cfg: dict, *, snapshot, install, prebump, tracker: Path, run_id: str) -> dict:
    """Two snapshots, installs and prebumps between them (SPEC 2).

    The first draft put session generation before the fingerprint that decides
    whether to generate. Thinness and staleness come out of schema_diff, so the
    initial snapshot has to exist first.
    """
    initial = snapshot()
    installed = install(initial)
    prebump(initial, installed)
    final = snapshot()
    return {"initial": initial, "final": final, "installed": installed,
            "run_id": run_id, "tracker": str(tracker)}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest -q scripts/tests/test_agent_format_tracker_run.py`
Expected: 2 passed

- [ ] **Step 5: Update the skill**

In `skills/agent-session-format-check/SKILL.md`, add a section after §1 Quick Start:

```markdown
## 1h  The automated sweep

`./scripts/agent_format_tracker.py run` drives the whole pass: batched auth preflight,
initial weekly snapshot, eligible installs, one batched prebump, post-run version
reread, final snapshot, triage. Everything is appended to
`docs/agent-support/agent-format-tracker.jsonl` **as it is found**, so a crash loses
nothing.

It stops for exactly **two** gates:
1. applying a fixture patch (hash-verified; refuses if the corpus moved)
2. applying a version claim (matrix + ledger as one patch, zero deletions)

Accepting a `docs/backlog.md` entry is post-sweep product triage, **not** a third gate.

Corrections are appended with `supersedes`, never edited in place. A record whose
`confidence` is `assumed` has not been proven — re-test it rather than trusting it.
```

- [ ] **Step 6: Run the full suite**

Run: `pytest -q scripts/tests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/agent_format_tracker.py scripts/tests/test_agent_format_tracker_run.py skills/agent-session-format-check/SKILL.md
git commit -m "feat(sweep): orchestrate two snapshots with installs between"
```

---

## Self-review

**Spec coverage.** §2 pipeline → Task 10. §3.1 Gate 1 → Task 7. §3.2 Gate 2 → Task 8.
§4 preflight → Task 5. §5 conditional generation → Task 9 (the thin-store refusal is the
shared predicate). §5a installs → Task 9. §6 triage buckets → **not implemented here**;
Tasks 1-2 carry the `bucket` field and Task 4 renders it, but semantic triage and
subagent proposal generation (SPEC §6, §8) are deliberately left for a second plan —
they depend on every task above and would double this plan's length. §7 tracker →
Tasks 1, 2, 4, 6. §8 subagents → deferred with §6. §9 acceptance tests → distributed
across task tests; the `SIGKILL` case (§9.1) needs a subprocess harness and is folded
into Task 2's durability work.

**Placeholder scan.** No TBD/TODO. Every code step carries real code; every test step
carries a real assertion and an expected failure message.

**Type consistency.** `append`/`read_all`/`findings` are used with the same signatures in
Tasks 1, 2, 4 and 6. `enumerate_sessions(agent, cfg, limit)` matches its call in Task 3
Step 5. `propose(agent, result, installed_now)` and `eligible(agent, result,
preflight_row, cfg)` match their tests. `BEGIN`/`END` are defined in Task 4 and used only
there.

**Interface verified after drafting.** `_redact(value, opaque: frozenset[str], key: str |
None = None)` at [rebuild_stage0_baseline.py:116](../../../scripts/rebuild_stage0_baseline.py:116).
The draft passed `set()`; corrected to `frozenset()`, with a note at the callsite that
an empty opaque set is correct only for the isolated unit test — the real callsite must
pass the agent's `_NESTED_OPAQUE_KEYS` entry, or Gate 1 would emit the very maps it
exists to catch.

**Deliberately out of this plan.** Semantic triage and subagent proposal generation
(SPEC §6, §8). They depend on every task above, and folding them in would double the
length while making each task's review gate less meaningful. Tasks 1-2 carry the
`bucket` field and Task 4 renders it, so the data model is ready for them.
