# Qwen review criticals — C1 and C2 fixed

Date: 2026-08-17. Branch `main`, base `8c499ce7`. No commit made.
Source: `docs/superpowers/plans/2026-08-17-qwen-integration-REVIEW.md` §4 Critical.

The working tree also carries an unrelated in-progress Onboarding contribute-card
feature; none of its files were touched here. The two fixes below are independent and
touch disjoint files apart from their own tests.

---

## C1 — reachable `fatalError` in `QwenSessionParser`

### Reproduction (fail-before)

`isUserPromptSubmitContextPart` builds `trimmed[bodyStart..<bodyEnd]` after only
`hasPrefix`/`hasSuffix` guards. `prefix` is 34 chars, `suffix` 35; the degenerate wrapper
`<qwen:user-prompt-submit-context>\n</qwen:user-prompt-submit-context>` is 68 chars and
satisfies both guards by *sharing* the single newline, so `bodyStart` (34) > `bodyEnd` (33).

Standalone repro of the exact function body:

```
Swift/arm64e-apple-macos.swiftinterface:19659: Fatal error: Range requires lowerBound <= upperBound
```

Reproduced again inside the test target with the fix reverted — the new regression test
crashed the whole test runner, not just the case:

```
Fatal error: Range requires lowerBound <= upperBound
💣 Program crashed: Signal 5 ... Thread 0 crashed
Restarting after unexpected exit, crash, or test timeout
```

That is the C1 blast radius: reached from the lightweight scan path, so one malformed
session file kills the entire indexing pass.

### Fix

`AgentSessions/Services/QwenSessionParser.swift` — guard the overlap before forming the
range and treat it as an empty body (matching Qwen's own `slice` semantics, where a
start past the end yields `""` rather than throwing):

```swift
guard trimmed.count > prefix.count + suffix.count else { return true }
```

### Proof (pass-after) — pinned behavior

New `QwenIntegrationTests.testDegenerateHookContextWrapperParsesWithoutCrashing` writes
four synthetic user records whose final part is the wrapper, and pins what each parses to
(in every case the wrapper part is stripped and only `"Visible retained prompt."` remains):

| Final part | Result |
|---|---|
| `<open>\n</close>` (shared newline, 68 chars — the crasher) | stripped, no crash |
| `<open>\n\n</close>` (genuinely empty body) | stripped |
| `<open>\nx\n</close>` (1-char body) | stripped |
| `<open>\n   \n</close>` (whitespace-only body) | stripped |

Existing `testPayloadlessUserProjectionStripsOnlyValidFinalHookContext` (valid / malformed /
nested cases) still passes unchanged.

---

## C2 — SQL `LIMIT` disabled on the hottest search path

### Reproduction (fail-before)

`DB.swift:2318` and `:2401` bound `LIMIT -1` whenever `eligibleSessionIDs != nil`, and
`SearchCoordinator.swift:348` always passes a concrete `Set` post-registry-refactor, so
the bound was off for all 13 sources on every search — `ORDER BY bm25(...)` had to
materialize and fully sort every matching row before the first `sqlite3_step` returned.

New `SearchIngestTests.testSearchSessionIDsFTSAppliesSQLLimitWithEligibleIDs` ingests 5
sessions sharing a planted rare word and asks for `limit: 2` with an eligible set drawn
only from rows ranked *beyond* the bound. With the old code the query returned them:

```
SearchIngestTests.swift:339: error: ... XCTAssertTrue failed - SQL LIMIT must truncate
before eligibility filtering; got ["9cc42ab4...", "9e7d386d..."]
```

### What a naive restore breaks (and why the fix is shaped this way)

Binding `LIMIT = limit` unconditionally (the pre-Qwen shape at `ef4e9253^`, which had no
eligibility filter at all) is *not* behavior-preserving for the current code: it regresses
two deliberate behaviors added alongside the filter, both of which failed on that first
attempt —

- `SessionParserTests.testSearchCoordinatorScansPastStaleIdentityFTSHit` (limit 1, stale
  row ranked first — search must scan past it to the current hit)
- `SessionParserTests.testSearchCoordinatorToolCapacityExcludesOrdinaryDuplicatesBeforeLimit`
  (an already-present duplicate must not consume a capacity slot)

So the bound has to be *widened*, not removed: the filter still needs to skip past a
bounded number of ineligible/excluded rows.

### Fix

`AgentSessions/Indexing/DB.swift`, both FTS query paths (session text and tool I/O):

```swift
let isFiltered = eligibleSessionIDs != nil || !excludingSessionIDs.isEmpty
let sqlLimit = isFiltered ? limit + Self.filteredSearchScanSlack : limit
sqlite3_bind_int(stmt, idx, Int32(clamping: sqlLimit)); idx += 1
sqlite3_bind_int(stmt, idx, Int32(isFiltered ? 0 : offset))
```

with `IndexDB.defaultFilteredSearchScanSlack = 512` and a DEBUG-only override on the
existing `IndexDBTestHooks`. The single-statement / single-read-snapshot property the
currency filter depends on is unchanged; only the `LIMIT` value changes. Unfiltered
callers are byte-for-byte the pre-Qwen bounded query (`LIMIT limit OFFSET offset`).
Worst-case sorter work goes from *every matching row* to `limit + 512`.

### Proof (pass-after)

The same test now pins that the `LIMIT` reaches SQL, non-tautologically (the Swift-side
`ids.count == limit` early return cannot produce these outcomes):

- slack 0, eligible = all 5 → `limit: 2` returns exactly the top 2, in unbounded order
- slack 0, eligible = the 3 lowest-ranked → **empty** (SQLite truncated, not Swift)
- slack 1, same eligible set → exactly one row (`all[2]`), i.e. the bound is `2 + 1`

Both previously-failing coordinator tests pass again.

---

## Files changed

| File | +/− |
|---|---|
| `AgentSessions/Indexing/DB.swift` | +33 −6 |
| `AgentSessions/Services/QwenSessionParser.swift` | +5 −0 |
| `AgentSessionsTests/QwenIntegrationTests.swift` | +63 −0 |
| `AgentSessionsTests/SearchIngestTests.swift` | +60 −0 |

No persisted-format change, no schema change, no drive-by fixes for I1–I8.

## Verification

- `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` → **BUILD SUCCEEDED**
- `-configuration Release build` → **BUILD SUCCEEDED** (covers the non-DEBUG branch of the slack accessor)
- Focused: `QwenIntegrationTests` (29) + `SearchIngestTests` (39) + `SessionParserTests` (134) → 202 tests, 0 failures
- `./scripts/xcode_test_stable.sh` → **Executed 2026 tests, with 3 tests skipped and 0 failures (0 unexpected)** — TEST SUCCEEDED
- `git diff --check` → clean

## Open question for the owner

`defaultFilteredSearchScanSlack = 512` is a judgement call: it bounds how many stale /
excluded rows a filtered search may skip past before results silently truncate. It is far
larger than any realistic stale cohort, but it is a cap where previously there was none.
An exact alternative (pushing the small *ineligible* set into SQL as a `NOT IN` clause —
`SearchCoordinator` already computes `staleIDs`) would remove the heuristic, but needs a
matching "all tool I/O session ids" query and a `SearchCoordinator` API change, which is
larger than a critical-fix diff should be.

---

# Package 1 — C2 precision (owner ruling: exactness over the cap)

Baseline for this section: `67ecd8a1` (the slack-capped C2 fix above, committed by the
owner). This package replaces the cap-as-primary-mechanism with an exact pushdown.

## What changed

`IndexDB.searchSessionIDsFTS` / `searchSessionIDsToolIOFTS` gained
`ineligibleSessionIDs: Set<String>` alongside the existing `eligibleSessionIDs`. When the
ineligible ∪ excluded set fits the bind budget (`IndexDB.maxPushedDownFilterIDs = 700`),
it is pushed into SQL as `sm.session_id NOT IN (…)` and the SQL `LIMIT` is bound to
`limit` exactly — the bound now applies to the *filtered* ranking, so the top-N is exact
and no eligible row can be truncated away by rows the caller was going to discard.

`SearchCoordinator` supplies the complement it already computes:

- session text: `staleIDs = presentIDs.subtracting(indexedIDs)` — existed already, now passed through
- tool I/O: `presentToolIOIDs.subtracting(currentToolIOIDs)`, where the "all tool I/O ids"
  query the plan called for **already existed** as `IndexDB.toolIOSessionIDs(sources:)`
  (I wrote a duplicate `indexedToolIOSessionIDs` first and deleted it — no new query was needed).

## Why `filteredSearchScanSlack` stays (demoted, not removed)

The ineligible set is not always small. Every identity-backed session (OpenCode, Hermes)
is dropped from the eligible set and re-added only when its stored identity state matches
the live session, so a single storage-path change or a failed identity-state read makes
*every* session of that source ineligible at once — thousands of ids, past any bind
budget. Rather than abandon the exact path for that case (the owner's stop condition) or
ship an unbounded query for it, the code degrades: over budget → Swift-side filtering with
the widened-but-bounded `limit + 512` LIMIT. Exact in the normal case, bounded always,
never `LIMIT -1`. Both modes are pinned by the test.

Bind-budget note: 700 keeps total binds under SQLite's oldest `SQLITE_MAX_VARIABLE_NUMBER`
(999) with room for the existing filter binds.

## Proof

`SearchIngestTests.testSearchSessionIDsFTSAppliesSQLLimitWithEligibleIDs`, extended with
the slack pinned to 0 so nothing below can be attributed to the cap:

| Case | Expectation |
|---|---|
| eligible = all, `limit: 2` | exactly the top 2, unbounded order preserved |
| eligible = 3 lowest-ranked, no ineligible set (fallback) | empty — SQLite truncated, not Swift |
| same, **with** ineligible set (exact mode) | the true top-2 *of the eligible rows* |
| same, `limit: 1` | one row — exactness is not "no LIMIT" |
| ineligible set of 701 ids (over budget) | degrades to the bounded Swift path, still correct |

The two behaviors a naive hard bound broke stay green:
`testSearchCoordinatorScansPastStaleIdentityFTSHit` and
`testSearchCoordinatorToolCapacityExcludesOrdinaryDuplicatesBeforeLimit`.

---

# Package 2 — Importants I1–I8 (+ agreed Minors)

Each finding was verified in code before acting. Two did not survive verification.

| # | Verdict | Action |
|---|---|---|
| I1 | Correct, historical | Record-only, per ruling. No action. |
| I2 | Correct | `precondition` → `assert` in both `static let` initializers. |
| I3 | Correct | Corroborated-absence constructor; wired into OpenCode **and** Hermes. |
| I4 | **Half wrong** | Transaction claim is false (verified); swallowed `try?` fixed; one-shot pinned. |
| I5 | Correct | Deleted the dead guard from the Qwen parser. |
| I6 | Correct | Done (delegated): config entry, `agent_watch.py` registration, count fix. |
| I7 | Correct | Identity sources structurally excluded from both currency predicates. |
| I8 | Correct | Three comments softened to match the 0.14.3 matrix pin. |
| M2 | Correct but inert | Hidden-file skip restored locally in Hermes (see note). |
| M6 | **Slightly wrong** | Bullet was under "Core Features", not "New in 4.8:"; substance fixed. |

## I2 — shipped `precondition` → `assert`

`SessionSourceRegistry.validateIdentityConfigurations` and
`SessionProviderCatalog.init(adapters:)`. Both invariants are compile-time constant and
already covered by registry tests, so a descriptor mistake now fails the suite instead of
trapping in a user's launch. `preconditionFailure` in the missing-entry subscripts is left
alone — that is a lookup failure, not the flagged pattern.

## I3 — wrongful-deletion guard

An empty `IdentitySnapshot` instructs cleanup to delete every identity row for that
storage path, and it was synthesized from a bare `FileManager.fileExists == false`. Added
`SearchIngestService.IdentitySnapshot.authoritativeAbsence(ofDatabaseAt:fileProbe:)`:
absence counts as authoritative only when the directory that would contain the database is
itself present; otherwise it returns nil (unknown) and the caller makes no claim — exactly
like a failed enumeration. Wired into both `OpenCodeSessionIndexer` branches (`.json`,
`.none`) and the equivalent `HermesSessionIndexer` branch, which had the same shape.

Pinned by `testAuthoritativeAbsenceRequiresAReadableContainer` using the existing
`FakeFileProbe` (three cases: gone-with-container, container-missing, database-present).

**Not fixed, needs a design decision (option set):** `deleteSessionsByIdentity` is still
`internal` and starts no transaction of its own — it is safe only because of where it is
called from. Options: (a) make it `private` and expose only the reconciling wrapper;
(b) give it its own `BEGIN IMMEDIATE`, which requires auditing callers that already hold a
transaction (nested `BEGIN` throws — see I4 below, where exactly that bit me);
(c) take a "must already be in a transaction" precondition-style parameter. Not improvised
here.

## I4 — half wrong

**Wrong half:** "the migration is not wrapped in a transaction". It is. The entire
`bootstrap` — every `CREATE TABLE`, every migration block, every `schema_migrations`
marker — runs inside one `BEGIN IMMEDIATE` … `COMMIT` with `ROLLBACK` on error
(`DB.swift:65` and `:522`). I proved this by adding the recommended inner transaction: it
failed instantly with `cannot start a transaction within a transaction`, taking 26 tests
down. Reverted. The wipe and its marker already commit atomically, so the migration cannot
re-run after a crash, and the `schema_migrations` marker is a genuine one-shot guard.

**Right half:** `SearchCoordinator.init` swallowed `try? IndexDB()`, so a migration or open
failure silently downgraded the app to legacy scan search with no signal. Now `do/catch`:
`LaunchProfiler.log` in release, `assertionFailure` in DEBUG.

Pinned by `testAnalyticsRederiveMigrationRunsOnlyOnce` — write a `session_days` row, reopen
the same database, assert the row survives. (This test is what caught the bad transaction
edit.)

## I5 — dead 50 MB guard deleted

Verified: every Qwen call site (`parseFile`, descriptor `parseFull`, indexer reload) passed
`allowLargeFile: true`, so no call site ever took the guarded path. Call-site intent is
unambiguous — refusing to open a large transcript is worse than the parse cost — so the
constant and the parameter are gone rather than kept as decoration; behavior is identical.
Note for a separate decision: `PiSessionParser`, `GrokSessionParser` and `KimiSessionParser`
carry the same seam with the same all-`true` call sites, but theirs *is* exercised by tests
(`testParseFileFullSkipsOversizedFileUnlessExplicitlyAllowed`), so deleting it there would
drop existing coverage. Left alone — cross-parser scope.

## I7 — two units in `session_search.mtime`

Verified and worse than a unit mismatch: for identity sources the column holds a *logical
content revision* (updated-millis + extent), not the storage file's stat, so
`s.mtime = f.mtime` compares two different quantities and can only ever answer "stale".
No normalization at write can fix that without discarding the WAL-invisible-update property
the revision exists for, and no read-side tolerance can compare a revision to a file stat.

So the predicates are now correct *by construction*: `indexedSessionIDsCurrent` and
`indexedToolIOSessionIDsCurrent` take
`identitySources: Set<String> = SessionSourceRegistry.identityBackedSourceRawValues`
(new derived registry member) and exclude those rows explicitly, with documentation naming
`sessionSearchIdentityStatesByID` as the correct comparison. **No migration, no behavior
change** — those rows were never returned — but the omission is now deliberate rather than
an accident a future caller could misread.

Pinned by `testCurrencyPredicatesExcludeIdentitySourcesStructurally`: an identity row whose
stored stat matches `files` *exactly* is still excluded, a file-backed control row with the
same shape is included, and passing `identitySources: []` brings the identity row back —
proving the exclusion is the `NOT IN`, not a stat mismatch.

## I8 — comment/evidence honesty

`QwenSessionParser` (display projection), `QwenSessionDiscovery` (header + filename
pattern) and `QwenCLIEnvironment` (resume flags) now say what was actually observed: the
0.21.13 *package source* and *`--help` surface* were read, no 0.21.13 transcript was
captured, and the matrix pins `max_verified_version: 0.14.3`.

## I6 — audit pipeline (delegated, verified by report)

`docs/agent-support/agent-watch-config.json` gained a weekly-cadence `qwen` entry (12
agents), `scripts/agent_watch.py` needed four real per-agent registrations (it is not
purely config-driven: `_NESTED_PAYLOAD_AGENTS`, `_NESTED_OPAQUE_KEYS`, the baseline
type-key dispatch, the weekly matrix-key/verified maps), and `monitoring.md`'s "all 11
active agents" became 12. `update-checklist.md` had no stale count.

Flagged, not fixed: `docs/agent-support/workflow.md:26` says "nine active providers" and
was already stale before Qwen (missing Kimi and Grok too) — pre-existing, out of scope.

## Minors folded in

- **M2:** verified but effectively inert — the shared `FileProbing.contentsOfDirectory`
  cannot blanket-skip hidden entries because its other caller enumerates `.claude*`
  directories in `$HOME`, and a dot-named file cannot match Hermes' `session_` prefix
  anyway. Restored the intent locally in `HermesSessionDiscovery` with an `.isHiddenKey`
  filter, which re-excludes the only real case: an entry carrying the filesystem hidden
  flag. No shared-signature churn.
- **M6:** the Qwen bullet was under "Core Features", not under "New in 4.8:" as the review
  states, so the literal claim is wrong — but the risk is real (a 4.8 reader sees an
  unshipped feature with no marker). Fixed with an inline "(shipping in 4.9)" rather than
  inventing a 4.9 heading the release commit is supposed to author.

## Files changed (this session, uncommitted)

| File | +/− |
|---|---|
| `AgentSessions/Indexing/DB.swift` | +90 −16 |
| `AgentSessions/Search/SearchCoordinator.swift` | +18 −2 |
| `AgentSessions/Search/SearchIngestService.swift` | +16 −0 |
| `AgentSessions/Model/SessionSourceRegistry.swift` | +14 −1 |
| `AgentSessions/Services/SessionProviderCatalog.swift` | +4 −1 |
| `AgentSessions/Services/OpenCodeSessionIndexer.swift` | +2 −2 |
| `AgentSessions/Services/HermesSessionIndexer.swift` | +2 −1 |
| `AgentSessions/Services/HermesSessionDiscovery.swift` | +8 −1 |
| `AgentSessions/Services/QwenSessionParser.swift` | +13 −10 |
| `AgentSessions/Services/QwenSessionDiscovery.swift` | +4 −2 |
| `AgentSessions/Services/QwenSessionIndexer.swift` | +1 −1 |
| `AgentSessions/Qwen/QwenSourceDescriptor.swift` | +1 −1 |
| `AgentSessions/Qwen/QwenCLIEnvironment.swift` | +3 −1 |
| `AgentSessionsTests/SearchIngestTests.swift` | +143 −20 |
| `README.md` | +1 −1 |
| `docs/agent-support/agent-watch-config.json` | +29 −0 |
| `docs/agent-support/monitoring.md` | +1 −1 |
| `scripts/agent_watch.py` | +14 −3 |

## Verification

- Debug build: **BUILD SUCCEEDED**; Release build: **BUILD SUCCEEDED**
- Focused: `SearchIngestTests` (42) + `QwenIntegrationTests` (29) + `SessionParserTests` (134) → 205 tests, 0 failures
- `./scripts/xcode_test_stable.sh`: **2036 tests, 3 skipped, 0 failures** — TEST SUCCEEDED
- `git diff --check`: clean
