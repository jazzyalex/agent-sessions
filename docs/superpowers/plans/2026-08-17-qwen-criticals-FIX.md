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
