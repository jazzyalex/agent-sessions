# Format Sweep Automation Implementation Plan

**Status:** ready for implementation after review
**Spec:** `docs/superpowers/plans/2026-08-31-format-sweep-automation-SPEC.md`
**Scope:** Python automation, tracker data, repo workflow documentation, and tests. No Swift changes.

## Goal

Run the weekly format sweep unattended through evidence collection, installation, fresh-session validation, frequency measurement, semantic triage, and proposal generation. Stop only for two explicit writes:

1. applying a reviewed fixture patch;
2. applying a reviewed version-claim patch.

Every discovered fact must be durable before the scan continues. A completed run must be reproducible from immutable manifests, and a green test suite must exercise the production CLI path rather than disconnected helpers.

## Architecture

The implementation has four boundaries:

1. **Tracker:** an append-only, locked JSONL event stream with idempotent event keys and a renderer that folds event chains into current state.
2. **Corpus:** source adapters expose logical sessions and records from JSON/JSONL, SQLite, and bespoke stores. Weekly fingerprinting, frequency counting, and fixture planning consume the same `CorpusSnapshot`.
3. **Gates:** Gate 1 and Gate 2 each build a serialized immutable manifest. Applying a manifest never re-plans work; it verifies source/target hashes and applies only the reviewed operations.
4. **Orchestrator:** preflight -> initial snapshot -> eligible installs -> conditional prebump -> installed-version reread -> final snapshot -> triage/proposals -> two gates.

The production entry point is:

```bash
./scripts/agent_format_tracker.py run \
  --config docs/agent-support/agent-watch-config.json \
  --tracker docs/agent-support/agent-format-tracker.jsonl
```

Gate application is always a separate explicit command. `run` may build manifests but may never apply them.

## Global constraints

- Do not modify Swift files. Read `AgentSessionsTests/Stage0GoldenFixturesTests.swift` only to preserve the narrower UUID defence-in-depth test.
- Use Python standard library only.
- Do not duplicate agent-specific source dispatch. Move the weekly local-schema dispatch behind `agent_corpus.snapshot()` and call it from both `agent_watch.py` and `rebuild_stage0_baseline.py`.
- Treat configuration consistently: public APIs receive the full config object; adapters receive one agent's config after one centralized lookup.
- Never read a SQLite database as JSONL. SQLite adapters yield canonical logical records inside a read transaction and compute a digest over those records.
- Never install unless preflight proves the driver is ready and the initial snapshot says a post-install session may be generated.
- Never auto-downgrade after a failed install/prebump. Record the failure and print the exact revert command.
- Preserve all content before the generated markers in `docs/agent-json-tracking.md` byte-for-byte.
- Treat `docs/agent-support/agent-format-tracker.jsonl` as an existing append-only migration input. Never truncate, recreate, reorder, normalize, or rewrite committed records.
- Ledger additions must contain zero deleted ledger lines. A matrix version replacement is allowed only inside the exact reviewed Gate 2 patch.
- No implementation step commits automatically. Commits and pushes remain user-initiated. Suggested commit subjects are listed only as checkpoints.
- Add an `[Unreleased]` CHANGELOG bullet and a note in `docs/summaries/2026-08.md` when implementation changes the user-visible workflow.

## Existing tracker baseline

Commit `60e0a73d` backfilled the 2026-08-31 sweep as the first 46 JSONL records across 38 findings: 25 `triaged`, 18 `action_applied`, and 3 `corrected`. Those exact 46 lines have SHA-256 `7ea759a01de60b2c89385bbfa9ce79e964a083c6c7169ed33196816f8db54520` and are an immutable prefix.

The tracker is already live, so totals are not invariants. At planning HEAD `4920f9e1`, later Qwen work has appended 11 more records, bringing the file to 57 records across 49 findings: 30 `triaged`, 22 `action_applied`, and 5 `corrected`. Tests must validate every current row and the immutable 46-line prefix without requiring the total to remain 57.

Existing schema-version-1 records predate the stricter writer in this plan:

- some `triaged` records omit `frequency` and carry the judgement in `observation` rather than `rationale`;
- `action_applied` records carry `commit` and `observation`, not `action`, `status`, or `patch_sha256`;
- two later Qwen `corrected` records are standalone corrections with `supersedes: null`.

The reader and renderer must accept these rows without mutation. New writes use schema version 2 and the stricter event-specific validation below. Task 1 updates the SPEC's tracker-schema section to document the v1 reader/v2 writer boundary.

## Shared data contracts

Create these typed contracts in `scripts/agent_corpus.py`:

```python
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class LogicalRecord:
    agent: str
    session_id: str
    bucket: str
    value: dict[str, Any]
    source_id: str


@dataclass(frozen=True)
class SourceDigest:
    source_id: str
    kind: str
    location: str
    sha256: str
    record_count: int
    session_ids: tuple[str, ...]


@dataclass(frozen=True)
class CorpusSnapshot:
    agent: str
    records: tuple[LogicalRecord, ...]
    type_keys: dict[str, list[str]]
    sources: tuple[SourceDigest, ...]
    session_ids: tuple[str, ...]
```

Adapters implement the concrete signature `snapshot(agent: str, agent_cfg: dict, limit: int | None) -> CorpusSnapshot`; the registry rejects objects without that callable during configuration validation.

`SourceDigest.sha256` means:

- JSON/JSONL: SHA-256 of the exact file bytes read;
- directory-backed stores: SHA-256 of the sorted `(relative path, file SHA-256)` manifest;
- SQLite: SHA-256 of canonical JSON for the logical records selected inside one read transaction, not merely the main `.db` file. This includes WAL-visible rows and changes whenever the logical corpus changes.

`SourceDigest.location` is the unexpanded config path or a repo-relative path, never an absolute home-directory path. Adapters resolve it at runtime. Tracker evidence and serialized manifests follow the same rule.

## Task 1: Tracker protocol, locking, and kill durability

**Files**

- Create `scripts/agent_format_tracker.py`
- Create `scripts/tests/test_agent_format_tracker.py`
- Create `scripts/tests/test_agent_format_tracker_durability.py`
- Modify `docs/superpowers/plans/2026-08-31-format-sweep-automation-SPEC.md` to document v1 compatibility and v2 new-write validation

**Interfaces**

```python
append(path: Path, record: dict) -> str
append_once(path: Path, event_key: str, record: dict) -> str | None
read_all(path: Path) -> list[dict]
findings(path: Path) -> dict[str, list[dict]]
validate(path: Path, *, verify_evidence: bool = False, verify_commits: bool = False) -> list[str]
```

`read_all` accepts committed schema-version-1 rows after validating the common fields, enum values, UUID shape, and referential integrity whenever `supersedes` is non-null. It never upgrades rows in place.

New records are schema version 2. Required fields for every new event are `event`, `run_id`, `agent`, `finding_id`, `confidence`, and `evidence`. Event-specific validation is mandatory:

- `discovered`: `kind`, `field`, `observation`;
- `triaged`: `bucket`, `frequency`, `rationale`;
- `corrected`: `supersedes`, `observation`, `rationale`;
- `action_applied`: `action`, `status`, `patch_sha256` when a patch exists.

Implement `append_once` with `fcntl.flock(LOCK_EX)` around lookup and append. Write the complete encoded line with a loop until every byte is written, `fsync` the file, and `fsync` the parent directory when the file is first created. The lock covers `supersedes` validation and event-key deduplication.

**Tests**

1. Missing confidence and missing event-specific fields raise `ValidationError`.
2. New v2 corrections require `supersedes`, and it must reference an existing record in the same finding chain.
3. Every committed v1 row loads, including legacy action records and standalone Qwen corrections.
4. The SHA-256 of the first 46 physical lines equals the `60e0a73d` prefix hash above.
5. Twenty processes appending concurrently produce twenty intact unique JSON lines.
6. Twenty processes calling `append_once` with one event key produce exactly one line.
7. A subprocess writes one record, prints `ACK` only after `append` returns, and is then sent `SIGKILL`; the acknowledged record remains valid JSONL.
8. `record_id` is a UUID and `ts` is microsecond UTC, but identity and deduplication never depend on `ts`.

Re-run the backfill provenance audit locally after implementing the reader:

```bash
./scripts/agent_format_tracker.py validate \
  --tracker docs/agent-support/agent-format-tracker.jsonl \
  --verify-evidence --verify-commits
```

Expected on this checkout: every referenced evidence path resolves and every referenced commit exists. The default CI validation omits these two flags because local report paths are intentionally not portable to a fresh checkout.

Run:

```bash
pytest -q scripts/tests/test_agent_format_tracker.py \
  scripts/tests/test_agent_format_tracker_durability.py
```

Expected: all tests pass, including the subprocess and cross-process cases.

**Checkpoint:** `feat(tracker): make format findings durable and idempotent`

## Task 2: Safe renderer and frozen legacy history

**Files**

- Modify `scripts/agent_format_tracker.py`
- Create `scripts/tests/test_agent_format_tracker_render.py`
- Read the existing `docs/agent-support/agent-format-tracker.jsonl`; append only through the tracker API
- Reuse the markers already committed at the end of `docs/agent-json-tracking.md`; do not add a second pair

Add:

```python
BEGIN = "<!-- BEGIN tracker-derived history -->"
END = "<!-- END tracker-derived history -->"

fold_chain(chain: list[dict]) -> dict
rendered(tracker: Path) -> str
render(tracker: Path, doc: Path) -> str
check(tracker: Path, doc: Path) -> bool
```

`fold_chain` merges event state in physical append order. It does not sort by `ts`, because the backfill intentionally shares timestamps across many records. An `action_applied` event must not erase the last triage bucket, observation, frequency, or rationale. Legacy v1 observations are the display fallback when `rationale` is absent. Standalone corrections remain visible, while linked corrections preserve both the original and correction.

Before writing, `render` must require exactly one `BEGIN`, exactly one `END`, and `BEGIN` before `END`. Missing, reversed, or duplicate markers raise `MarkerError`; no file is changed. Write through a sibling temporary file, `fsync`, then `os.replace`.

**Tests**

1. The SHA-256 of everything before `BEGIN` is unchanged after rendering.
2. The existing 57-row planning snapshot renders without schema migration or tracker rewrites; the test does not freeze 57 as the future total.
3. A v1 triaged finding followed by a v1 `action_applied` still renders its bucket and observation.
4. Linked corrections render the original and correction; standalone v1 corrections also render.
5. Missing or duplicate markers raise and leave the document byte-identical.
6. `check` is false for stale output and true after render.

Verification against the real document:

```bash
git diff --numstat docs/agent-json-tracking.md
git diff --check
```

Expected: no changes above `BEGIN`. The markers already exist, so implementation adds only tracker-derived content between them.

**Checkpoint:** `feat(tracker): render current finding state without touching history`

## Task 3: Corpus contract and JSON/JSONL adapters

**Files**

- Create `scripts/agent_corpus.py`
- Create `scripts/tests/test_agent_corpus_json.py`

Implement one config boundary:

```python
def agent_config(cfg: dict, agent: str) -> dict:
    agents = cfg.get("agents", cfg)
    value = agents.get(agent)
    if not isinstance(value, dict):
        raise CorpusConfigError(f"unknown agent: {agent}")
    return value


def snapshot(agent: str, cfg: dict, limit: int | None = None) -> CorpusSnapshot:
    agent_cfg = agent_config(cfg, agent)
    local = (agent_cfg.get("weekly") or {}).get("local_schema") or {}
    return adapter_for(local.get("kind")).snapshot(agent, agent_cfg, limit)
```

The JSON adapter must preserve existing `roots`, `glob`, `required_types`, and `exclude_globs` behavior by moving or calling the existing tested helpers rather than reimplementing an approximate glob walk. `limit=None` means all logical sessions; `limit=N` preserves current newest-N semantics.

Add:

```python
def count_field(snapshot: CorpusSnapshot, predicate) -> dict:
    matched_records = 0
    matched_sessions: set[str] = set()
    for record in snapshot.records:
        if predicate(record):
            matched_records += 1
            matched_sessions.add(record.session_id)
    return {
        "records": matched_records,
        "sessions": len(matched_sessions),
        "of_sessions": len(snapshot.session_ids),
    }
```

**Tests**

1. Test both full-config and legacy top-level-agent config shapes.
2. Required-type and exclude-glob behavior matches the current `agent_watch` helpers.
3. Two records in one session count as two records and one session.
4. Invalid JSON lines are recorded as source errors; they are not silently converted into clean coverage.
5. Directory digests change when a source is added, removed, renamed, or edited.

Run:

```bash
pytest -q scripts/tests/test_agent_corpus_json.py
```

**Checkpoint:** `feat(corpus): define one logical-record contract for file stores`

## Task 4: SQLite and bespoke corpus adapters

**Files**

- Modify `scripts/agent_corpus.py`
- Modify `scripts/agent_watch.py` to expose or move existing logical record extractors
- Create `scripts/tests/test_agent_corpus_sqlite.py`
- Create `scripts/tests/test_agent_corpus_parity.py`

Implement adapters for every kind present in the real config at planning time:

- `jsonl_newest`;
- `opencode_latest_session`, including legacy `storage_v2` fallback;
- `hermes_latest_session`;
- `cursor_transcript_newest`;
- `kimi_wire_newest`;
- `devin_latest_session`;
- `fx_latest_session`.

Preserve agent-specific behavior layered on those kinds, including Grok's sibling `summary.json`, OpenCode session/message/part projection, and FX checkpoint siblings.

The inventory test loads the real `agent-watch-config.json` and fails when any configured kind has no registered adapter. Do not default unknown kinds to JSONL.

For OpenCode, yield logical `session`, `message`, and `part` records from `opencode.db` using the same bucket names as `_opencode_sqlite_latest_session_schema_fingerprint`. Preserve the logical `session_id` for frequency denominators. Run extraction in a read-only transaction and compute the canonical logical digest before closing it.

**Parity tests**

For representative file, SQLite, and bespoke fixtures, assert:

```python
agent_corpus.snapshot(agent, cfg).type_keys == expected_existing_fingerprint
```

Also assert that OpenCode frequency counting sees DB records and reports a non-zero session denominator. A raw `.db` path must never reach a JSON line reader.

Run:

```bash
pytest -q scripts/tests/test_agent_corpus_sqlite.py \
  scripts/tests/test_agent_corpus_parity.py
```

**Checkpoint:** `feat(corpus): support sqlite and bespoke agent stores`

## Task 5: Migrate weekly monitoring and rebuild to the shared corpus

**Files**

- Modify `scripts/agent_watch.py`
- Modify `scripts/rebuild_stage0_baseline.py`
- Modify existing corpus/fingerprint tests

Replace the local-schema dispatch in `agent_watch.py` with `agent_corpus.snapshot(agent, cfg, _LOCAL_SCHEMA_SAMPLE_COUNT)`. Preserve current report fields by adapting `CorpusSnapshot` into `weekly.local_schema` and `schema_diff`; do not change the compatibility verdict contract in this task.

Replace `_all_sessions` in `rebuild_stage0_baseline.py` with a call to `agent_corpus.snapshot(agent, full_cfg, limit=None)`. Change `_load_config` to return the full config and perform agent lookup through `agent_corpus.agent_config`; this prevents the full-config/per-agent mismatch.

Add a regression test based on `docs/backlog.md:578`:

1. Create a stale legacy OpenCode tree and a SQLite DB containing an extra `part.patch` key.
2. Assert weekly and rebuild consume the same `SourceDigest` and report the same missing pair.
3. Assert neither path reports “fixture already covers everything.”

Run:

```bash
pytest -q scripts/tests
```

Expected: all existing Python tests plus corpus parity tests pass.

**Checkpoint:** `fix(corpus): make weekly and rebuild inspect identical sources`

## Task 6: Wire discovery events into the production scan

**Files**

- Modify `scripts/agent_watch.py`
- Create `scripts/tests/test_agent_watch_tracker_hook.py`
- Extend an existing end-to-end `agent_watch.main` test

Add CLI flags:

```text
--run-id <stable id>
--tracker <jsonl path>
```

Add `record_discovery()` using `append_once`. Its event key is the stable tuple `(run_id, agent, kind, bucket, field)`, and its `finding_id` includes `kind` and the normalized bucket/field path so unrelated findings cannot collide.

Call it at the exact point `schema_diff` confirms an unknown type or key. Do not infer findings from severity or recommendation strings. Evidence must contain the report path and the source IDs that produced the unknown.

**Tests**

1. Calling the helper twice produces one event.
2. Two processes racing the same event key produce one event.
3. Running `agent_watch.main(["--mode", "weekly", "--run-id", "r1", "--tracker", str(log)])` against a fixture with one unknown writes one `discovered` event before returning.
4. A clean scan writes nothing.
5. The CLI rejects `--run-id` without `--tracker` and vice versa.

**Checkpoint:** `feat(sweep): persist discoveries from the real scan path`

## Task 7: Batched side-effect-free preflight

**Files**

- Modify `scripts/agent_watch_prebump_drivers.py`
- Modify `scripts/agent_watch.py`
- Modify `docs/agent-support/agent-watch-config.json`
- Create `scripts/tests/test_agent_watch_preflight.py`

Add `--mode preflight`. Preflight performs no session generation and no install. It validates:

- CLI/version command exists;
- configured driver exists in `DRIVERS`;
- discovery contract is structurally valid;
- at least one auth route is present: configured environment variable or credential file;
- credential hygiene without copying or printing values;
- an optional side-effect-free authentication probe declared under `preflight.auth_probe`.

Return per agent:

```python
{
    "credential_present": bool,
    "authenticated": bool | None,
    "driver_ready": bool,
    "category": "ready" | "fixable_ours" | "fixable_theirs" | "not_fixable",
    "action": str,
    "warnings": list[str],
}
```

`authenticated=None` is valid when no safe probe exists, but must not be presented as proven authentication. `driver_ready` is false when auth prerequisites, executable lookup, driver registration, or discovery-contract validation fails.

The preflight result includes version-update candidates based on installed/upstream inventory and driver readiness. It does not call them final install decisions because thinness and staleness are not known until the initial snapshot. The orchestrator merges preflight with the initial snapshot, then prints one consolidated planned/skipped install report. After execution it adds outcomes to the same report without raising a second prompt.

**Tests**

1. Environment-variable auth is recognized without reading credential files.
2. Credential presence remains distinct from proven authentication.
3. Two failures appear in one report with their separate categories.
4. No driver, session file, or install command is invoked.
5. No credential value appears in returned JSON or captured stdout/stderr.
6. The production `main --mode preflight` path emits the expected report.

**Checkpoint:** `feat(preflight): batch auth and driver readiness before sweep work`

## Task 8: Install eligibility, adapters, and failure recovery

**Files**

- Create `scripts/agent_install.py`
- Modify `docs/agent-support/agent-watch-config.json`
- Create `scripts/tests/test_agent_install.py`

Use the existing semantic version comparison from `agent_watch._compare_semver`; eligibility requires an exact result of `1` for `upstream > installed`. Missing or unparsable versions refuse installation.

Eligibility requires all four SPEC conditions:

1. newer upstream version;
2. declared install block;
3. `preflight_row.driver_ready is True`;
4. conditional-generation policy allows a post-install session.

Implement allowlisted argument-vector adapters for `brew_cask`, `brew_formula`, `npm_global`, and `vendor_updater`. Never use `shell=True`. Every adapter returns the exact install and revert argv plus captured result.

Before invoking the install, append an `action_applied` event with `status="started"`, `pre_install_version`, and the revert argv. Afterward reread the installed version. If install or post-install prebump fails:

- do not auto-downgrade;
- append a `corrected` event referencing the started record;
- print the exact revert argv;
- block Gate 2 for that agent.

If fresh evidence reports schema drift, classify it as urgent rather than rollback failure.

**Tests**

1. Older/equal/unparsable upstream versions refuse.
2. Missing install block or non-ready driver refuses.
3. Thin real-home store refuses before adapter invocation.
4. Each adapter builds the expected argument vector and revert vector.
5. Failed post-install prebump produces no downgrade and no version proposal.
6. The pre-install tracker record is durable before the mocked adapter starts.

**Checkpoint:** `feat(install): update only agents that can produce replacement evidence`

## Task 9: Conditional prebump selection

**Files**

- Create `scripts/agent_sweep_policy.py`
- Create `scripts/tests/test_agent_sweep_policy.py`

Implement one shared predicate used by install eligibility and prebump selection:

```python
@dataclass(frozen=True)
class GenerationDecision:
    generate: bool
    reason: str


def generation_decision(agent_cfg: dict, initial_result: dict, *, installed_changed: bool) -> GenerationDecision:
    compatibility = initial_result.get("compatibility") or {}
    verdict = compatibility.get("verdict")
    prebump = agent_cfg.get("prebump") or {}
    if prebump.get("real_home_session") is True and verdict == "blocked_thin_sample":
        return GenerationDecision(False, "thin real-home store")
    if verdict == "blocked_stale_sample":
        return GenerationDecision(True, "sample predates installed CLI")
    if installed_changed:
        return GenerationDecision(True, "installed version changed")
    if compatibility.get("supports_latest") is True:
        return GenerationDecision(False, "latest build already has fresh evidence")
    blockers = set(compatibility.get("blockers") or [])
    actionable = {
        "stale_sample",
        "schema_baseline_not_checked",
        "blocked_no_fresh_evidence",
    }
    if blockers & actionable:
        return GenerationDecision(True, "fresh evidence required by compatibility blocker")
    return GenerationDecision(False, "no condition requires a generated session")
```

Priority is exact:

1. `real_home_session` plus `blocked_thin_sample` -> refuse, even if stale or updated;
2. stale sample -> generate;
3. installed version changed or version claim candidate -> generate;
4. already `supports_latest` and fresh -> skip;
5. otherwise generate only when a named blocker requires it.

Tests must assert the driver callable is never invoked for the thin-store case, including when upstream is newer and the sample is stale.

**Checkpoint:** `feat(sweep): centralize safe session-generation decisions`

## Task 10: Gate 1 immutable fixture manifest

**Files**

- Modify `scripts/rebuild_stage0_baseline.py`
- Create `scripts/fixture_patch_guard.py`
- Create `docs/agent-support/fixture-key-exceptions.json`
- Create `scripts/tests/test_rebuild_plan_apply.py`
- Create `scripts/tests/test_fixture_patch_guard.py`

Replace `--emit` with:

```text
--build-plan <manifest.json>
--apply-plan <manifest.json> --expected-plan-sha256 <sha256>
```

The serialized manifest contains:

```python
{
    "schema_version": 1,
    "agent": str,
    "source_manifest": list[SourceDigest],
    "targets": [
        {
            "path": str,
            "base_sha256": str | None,
            "operation": "append_lines" | "create_file" | "replace_file",
            "content": str,
        }
    ],
    "pairs": list[list[str]],
    "variable_key_findings": list[dict],
    "plan_sha256": str,
}
```

`plan_sha256` is computed over canonical JSON with that field omitted. Application requires the reviewer-provided expected hash and recomputes it.

Every target path is repo-relative. `base_sha256=None` means the path must not exist. The manifest also records each target's expected post-image SHA-256 so later gates can depend on its virtual result without applying it early.

Fixture writers are agent-specific and consume `LogicalRecord` objects:

- JSONL agents append only the greedy set-cover records that close named gaps;
- OpenCode materializes `storage_v2/session`, `message`, and `part` files and includes any required matrix fixture-registration operation;
- unsupported writers refuse to build a plan rather than returning a false clean.

Always call `_redact(record, frozenset(agent_watch._NESTED_OPAQUE_KEYS.get(agent, ())))`. There is no production empty-set fallback.

`fixture_patch_guard.py` performs both checks:

1. bucket/path-aware variable-key comparison, with exceptions loaded from `fixture-key-exceptions.json`; every exception has `bucket`, `path`, and `reason`;
2. output-key scan for UUID-, model-slug-, absolute-path-, and header-shaped keys.

Any unexplained finding blocks both plan construction and application. `apply_plan` re-snapshots the corpus, compares the full source manifest including membership, verifies every target base hash, builds an exact temporary Git patch, runs `git apply --check`, and only then applies it. It never calls the planner.

**Tests**

1. Source edit, addition, removal, or SQLite logical-row change makes apply refuse.
2. Target edit makes apply refuse.
3. Wrong expected plan hash makes apply refuse.
4. UUID, model slug, path, and header key shapes each fail.
5. Variable maps are grouped by bucket plus field path, not leaf name globally.
6. A documented fixed-map exception passes; an undocumented one fails.
7. Real agent opaque keys are used in production planning.
8. OpenCode produces structured fixture operations, never JSONL-decoded DB bytes.
9. `--build-plan` writes but never applies; `--apply-plan` applies exactly the reviewed operations.

**Checkpoint:** `feat(gate1): apply only hash-verified safe fixture manifests`

## Task 11: Gate 2 exact version-claim manifest

**Files**

- Create `scripts/agent_version_claim.py`
- Create `scripts/tests/test_agent_version_claim.py`
- Create `scripts/tests/test_agent_version_claim_apply.py`

Split Gate 2 into:

```python
build_claim_plan(agent: str, result: dict, cfg: dict, tracker: Path) -> dict | None
apply_claim_plan(plan_path: Path, expected_sha256: str, cfg: dict, tracker: Path) -> None
```

The plan records:

- post-prebump installed version and version-command argv;
- checkable freshness assertions;
- exact unified diff for matrix and ledger;
- base and post-image hashes for both files;
- ledger added lines and a proven zero ledger-deletion count;
- deterministic proposal event key;
- canonical plan SHA-256.

When Gate 1 also changes `agent-support-matrix.yml` to register fixture evidence, Gate 2 is built against Gate 1's virtual post-image and records `depends_on_fixture_plan_sha256`. Gate 2 application then requires Gate 1's expected post-image hashes. It never rebuilds itself after Gate 1 and never accepts the pre-Gate-1 matrix hash. If Gate 1 is declined or fails, the dependent version claim remains unapplied rather than creating a third review.

Build refuses upstream-only targets, failed prebump, stale/thin evidence, unknown schema, any blocker, or evidence not written by the installed build. Use parsed timestamps, not lexical string comparison.

Apply:

1. verifies expected plan hash;
2. rereads installed version and requires an exact target match;
3. verifies matrix and ledger base hashes;
4. reparses the diff and requires zero removed ledger lines;
5. runs `git apply --check` and applies the exact diff;
6. appends an idempotent `action_applied` tracker event with patch hash;
7. rerenders tracker history.

Recovery is idempotent: if the patch post-image hashes already match but the action event is absent, application appends the missing event and renders instead of applying twice.

**Tests**

1. Each refusal condition produces no plan and a structured reason.
2. Installed version changing before apply refuses.
3. Matrix or ledger target movement refuses.
4. Any ledger deletion refuses, while the reviewed matrix replacement is allowed.
5. Crash-recovery simulation completes the tracker event without duplicating the patch.
6. Proposal and application are separate tracker events.

**Checkpoint:** `feat(gate2): bind version claims to exact evidence and patches`

## Task 12: Frequency, semantic triage, and idempotent proposals

**Files**

- Create `scripts/agent_triage.py`
- Create `scripts/tests/test_agent_triage.py`
- Modify `scripts/agent_format_tracker.py`

For every discovered finding, build a triage packet containing:

```python
{
    "finding_id": str,
    "field_path": str,
    "observed_values": list,
    "parser_behavior": "rendered" | "preserved_meta" | "dropped" | "unknown",
    "frequency": {"records": int, "sessions": int, "of_sessions": int},
    "release_note_hints": list,
    "evidence": list,
}
```

Frequency always comes from the final `CorpusSnapshot`. Never classify from a field name or substring count.

The triage adapter returns `urgent`, `support now`, `backlog`, or `log only` plus rationale and confidence. Its process boundary is JSON on stdin and JSON on stdout, invoked through an argument vector with a timeout. The Codex skill supplies a read-only subagent worker command; tests supply a deterministic local stub. Direct CLI runs must receive `--triage-command` and fail before the sweep starts if it is missing or invalid. There is no silent name-based fallback.

Proposal generation is deterministic:

- urgent/support-now -> patch proposal text plus evidence under `scripts/probe_scan_output/agent_format/<run-id>/proposals/`, never auto-applied;
- backlog -> exact backlog patch in the same proposal directory with marker `<!-- agent-format:<finding_id> -->`;
- log-only -> tracker event only.

Re-running the same `run_id` or seeing an existing backlog marker produces no duplicate proposal. Append the `triaged` event before generating proposal files so a crash cannot lose the classification.

**Tests**

1. Frequency counts records and logical sessions for JSONL and SQLite.
2. Triage cannot run without observed values, parser behavior, and frequency.
3. Stable field names with different values can receive different rationales.
4. Backlog proposal reruns are idempotent.
5. Read-only proposal workers cannot mutate the repo in the test harness.

**Checkpoint:** `feat(triage): classify measured findings and generate read-only proposals`

## Task 13: End-to-end orchestrator

**Files**

- Modify `scripts/agent_format_tracker.py`
- Create `scripts/tests/test_agent_format_tracker_run.py`
- Create `scripts/tests/test_agent_format_tracker_cli.py`

Use dependency injection internally, but exercise the production CLI in tests:

```python
def run(
    cfg: dict,
    *,
    preflight,
    snapshot,
    install,
    prebump,
    reread_versions,
    triage,
    build_fixture_plans,
    build_claim_plans,
    render_tracker,
    emit_summary,
    tracker: Path,
    run_id: str,
) -> dict:
    preflight_rows = preflight(cfg)
    initial = snapshot(cfg, tracker=tracker, run_id=run_id, phase="initial")
    installed = install(cfg, initial, preflight_rows, tracker=tracker, run_id=run_id)
    prebump_result = prebump(cfg, initial, installed, tracker=tracker, run_id=run_id)
    versions = reread_versions(cfg)
    final = snapshot(cfg, tracker=tracker, run_id=run_id, phase="final")
    triage_result = triage(cfg, final, tracker=tracker, run_id=run_id)
    fixture_plans = build_fixture_plans(cfg, final, triage_result)
    claim_plans = build_claim_plans(
        cfg, final, versions, triage_result, fixture_plans=fixture_plans
    )
    render_tracker(tracker)
    result = {
        "run_id": run_id,
        "initial": initial,
        "final": final,
        "prebump": prebump_result,
        "versions": versions,
        "fixture_plans": fixture_plans,
        "claim_plans": claim_plans,
    }
    emit_summary(result)
    return result
```

Required order:

1. validate tracker, generated markers, and the triage command before doing agent work;
2. run batched side-effect-free preflight;
3. run the initial weekly snapshot with discovery events;
4. merge preflight and initial-snapshot facts, then print one consolidated auth/update action report;
5. compute install and generation decisions from the initial snapshot;
6. apply eligible installs, recording started actions first;
7. run one batched prebump for selected agents;
8. reread installed versions;
9. run the final weekly snapshot;
10. measure and append triage events;
11. generate read-only urgent/support/backlog proposals;
12. build Gate 1 manifests and their virtual post-images;
13. build Gate 2 manifests against the applicable Gate 1 post-images;
14. render the tracker view;
15. print the two pending gate groups, hashes, and dependencies.

The orchestrator never calls either apply function. A post-install prebump failure blocks only that agent's claim and continues the rest of the sweep.

**Tests**

1. A call-order test asserts every stage above, including preflight and version reread.
2. Thin-store refusal proves neither install nor prebump driver is called.
3. One agent failing post-install prebump does not prevent other agents reaching proposals.
4. A finding is present in the tracker when an injected crash occurs after discovery but before triage.
5. The CLI builds manifests and prints hashes but leaves fixture, matrix, ledger, and backlog files unchanged.
6. The only write-capable CLI subcommands are explicit `apply-fixture-plan` and `apply-claim-plan`.
7. A complete fake run produces no duplicate findings or proposals when rerun with the same `run_id`.

**Checkpoint:** `feat(sweep): orchestrate the complete two-gate format workflow`

## Task 14: Workflow documentation and final verification

**Files**

- Modify `skills/agent-session-format-check/SKILL.md`
- Modify `docs/agent-support/monitoring.md` if its command contract changes
- Modify `docs/CHANGELOG.md`
- Modify `docs/summaries/2026-08.md`

Document the exact production commands, manifest locations, gate hashes, recovery behavior, and the distinction between credential presence and proven authentication. State explicitly that:

- the automated run never applies either gate;
- Gate 1 may have multiple fixture target operations, including OpenCode tree files;
- Gate 2 owns matrix plus ledger and requires zero ledger deletions;
- semantic workers are read-only;
- the Swift test detects UUID-shaped keys only, while the Python guard covers all four shapes.

Run final verification:

```bash
pytest -q scripts/tests
git diff --check
git status --short
```

No Xcode build is required because no Swift, project, resource, or build-setting file changes. If implementation unexpectedly touches Swift or the Xcode project, stop and revise scope before continuing.

Review the final diff for:

- no edits above the generated markers in `docs/agent-json-tracking.md`;
- no raw credential values or absolute user paths in fixtures, manifests, tracker records, or reports;
- no direct backlog writes from unattended mode;
- no commit or push performed without a separate user request.

**Checkpoint:** `docs(sweep): document the durable two-gate workflow`

## Acceptance matrix

The plan is complete only when every SPEC acceptance item maps to a named test:

| SPEC requirement | Required test |
|---|---|
| Tracker survives acknowledged append then SIGKILL | `test_acknowledged_append_survives_sigkill` |
| Concurrent appends do not merge/truncate | `test_process_concurrent_appends_are_valid_jsonl` |
| Same event key is idempotent | `test_append_once_is_cross_process_idempotent` |
| Existing tracker migration is lossless | `test_committed_v1_tracker_loads_without_rewrite` |
| Original backfill is an immutable prefix | `test_backfill_first_46_lines_match_60e0a73d_sha256` |
| Legacy history is byte-identical | `test_render_preserves_legacy_prefix_sha256` |
| Gate 1 refuses moved corpus or target | `test_apply_refuses_source_membership_or_digest_change`, `test_apply_refuses_target_change` |
| Gate 1 catches four key shapes | four parameterized cases in `test_fixture_patch_guard.py` |
| OpenCode weekly/rebuild parity | `test_opencode_weekly_and_rebuild_share_snapshot` |
| Gate 2 refusal cases | parameterized cases in `test_agent_version_claim.py` |
| Ledger patch has zero deletions | `test_claim_apply_refuses_ledger_deletion` |
| Batched preflight is side-effect-free | `test_preflight_batches_without_driver_or_install` |
| Thin store invokes no driver | `test_thin_real_home_store_invokes_nothing` |
| Install requires working driver | `test_install_refuses_nonready_driver` |
| Failed post-install prebump does not downgrade | `test_failed_postinstall_prebump_prints_revert_only` |
| Candidate and final applied/skipped installs appear in one consolidated report | `test_action_report_merges_preflight_and_initial_snapshot` |
| Corrections preserve original | `test_renderer_folds_correction_chain` |
| Same run has no duplicate findings/backlog proposals | `test_complete_rerun_is_idempotent` |
| Production CLI never auto-applies gates | `test_run_cli_builds_but_does_not_apply_manifests` |

## Implementation order and review gates

Implement in this order:

1. Tasks 1-2: tracker durability and rendering.
2. Tasks 3-5: shared corpus, including OpenCode parity. Do not proceed while any configured source kind lacks an adapter.
3. Tasks 6-9: production discovery, preflight, installs, and generation policy.
4. Tasks 10-11: immutable gates.
5. Tasks 12-13: semantic triage and complete orchestration.
6. Task 14: documentation and full verification.

After each group, run the named focused tests plus `pytest -q scripts/tests`. A passing helper-only test is insufficient when the task changes a CLI path; every such task includes a `main()` or subprocess-level test.
