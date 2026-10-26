# OpenCode Session Rates in the Quota Meter — Implementation Plan (rev 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each running OpenCode 2.x session in the Quota Meter shows its token rate (tk/h), or its API-equivalent cost rate ($/h) in the $ lens, computed from local data only.

**Architecture:** Reuse the existing OpenCode telemetry reader instead of a parallel SQL reader. It already applies the v1/v2 store-selection contract, fork-clone attribution, compaction accounting and malformed-row rules. Add a **time-windowed** entry point to it, plus a cheap tail probe and a cycle-safe session-tree query. Price each usage event with the Session Info calculator (`TelemetryCostCalculator`), then turn the events of the newest burst into a rate. An actor loader runs this off the main thread on a 5 s cadence, only while the Quota Meter rate surface is on screen. The HUD shows one rate per OpenCode session tree, keyed by session ID.

**Tech Stack:** Swift 5 / SwiftUI, SQLite3 C API (read-only), XCTest.

**Spec:** This plan is the spec. Owner decisions (2026-10-26):
- No 5h or weekly quota for OpenCode until OpenCode Go subscription data exists. Only tk/h and $/h.
- OpenCode 2.x live sessions only (1.x has no live presence). Desktop sessions get a rate only while working.
- **Compaction counts.** A token-bearing compaction is a billable model call. The Quota Meter rate includes it, so $/h reconciles with Session Info.
- **Free routes read "Free"** in the $ lens, using the existing `"Free"` catalog key. API-equivalent cost of free-route sessions stays in Session Info.
- Target release: 6.2.

**Review history:** rev 1 (commit 21252ba2) got NO-SHIP from a ChatGPT Extra High Repo MCP review with 11 findings. Each is mapped to its fix in "Findings addressed" at the end.

## Global Constraints

- Deployment target macOS 14.0.
- `UsageTrackingSource` stays `.codex` / `.claude` (exhaustive switches at `CodexRunwayModel.swift:1411`, `UsageStaleCheck.swift:77`, `UsageFreshness.swift:52`, `UsageDisplayFormatter.swift:478,498`).
- `RunwayPresentation` keeps exactly four cases (`testRunwayPresentationDefaultsToFiveHour`).
- `opencode.db` is read-only: `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, the pattern at `OpenCodeSqliteReader.swift:187-193`. Never create indexes or write. One short read transaction per refresh cycle, never held across cycles.
- No network. No polling while the rate surface is off screen or `QuotaMeterRunwayVisibility.alwaysOff`.
- Every new Swift file, production **and test**, is added with `scripts/xcode_add_file.rb` (a correct run adds exactly 4 `project.pbxproj` lines per file). Verify the new test classes appear in the test run.
- New user-facing strings go into `Localizable.xcstrings` (en + zh-Hans). Update the key count and digest in `scripts/validate_localization_catalogs.py:42-45` and `scripts/tests/test_validate_localization_catalogs.py`, or release QA fails.
- Test-count baseline `tools/release/test-count-baseline.txt` holds the **passed** count (3905 at 21252ba2), not total-with-skips.
- Commits: Conventional Commits + `Tool:`/`Model:`/`Why:` trailers, `git commit -- <paths>`.

## Fixed values

| Name | Value | Note |
|---|---|---|
| Event window | events whose completion is within the last 30 min | Completion = `completedAt ?? observedAt`. |
| SQL lower bound | `time_created >= now − 2 h` | Bounds the query; a request longer than 2 h is not shown. Post-filter by completion. |
| Burst gap | 30 min between one event's completion and the next one's start | |
| Minimum burst span | 60 s from the first event's start to the newest completion | A single short request with a big cached prompt would otherwise read as millions of tk/h. |
| Freshness | the newest completion within 5 min of **now**, re-checked on every display tick, including cached activity | Covers one long request with no new row. |
| Token weight | fresh input + output (incl. reasoning) + cache writes + 0.10 × cache read | Same scale as Claude's tk/h (`ClaudeRunwayTokenActivityParser.weightedTokens`, :555-564). |
| Tail-probe cadence | every 5 s refresh | |
| Full windowed reload | when the tail probe changes, or 60 s after the last full read | Catches in-place edits the tail probe cannot see. |
| Session-tree depth cap | 8 levels, cycle-safe | |
| Max rate owners per refresh | 4 (`OpenCodeHUDGroup.maxVisibleSessions`) | |
| Performance budget | p95 ≤ 25 ms per refresh for 4 owners on the large fixture | Task 4 benchmark. |

**These rules differ from Claude's on purpose.** Claude uses 30 s sample freshness, a 10 s minimum span and a provisional single-turn rate (`ClaudeRunwayTokenActivityParser.swift:42-60, 370-438`). OpenCode stores a request's tokens only when it completes, so it needs a longer freshness. It shows "working" rather than a provisional rate until 60 s of evidence exist. Only the token weighting is shared.

## Review Focus

1. **In-place edit of an older row with an unchanged tail.** Expect: picked up by the 60 s full reload. Test `testInPlaceEditIsPickedUpByPeriodicReload` (Task 4).
2. **A cached rate going stale.** Expect: activity cached at minute 4 reads "working" at minute 6 with no new data. Test `testCachedActivityExpiresAtFreshness` (Task 4).
3. **A visible child or grandchild whose root is not visible.** Expect: exactly one row shows the tree's rate, the visible row nearest the root. Test `testRateShownOnceOnNearestVisibleAncestor` (Task 5).
4. **Database root swap with equal session IDs.** Expect: no cache hit across database paths. Test `testCacheIsKeyedByDatabasePath` (Task 4).
5. **A slow stale read finishing after a newer one.** Expect: the stale result is never published. Test `testStaleReadIsNotPublished` (Task 4).

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `AgentSessions/OpenCode/OpenCodeSqliteReader.swift` | Windowed telemetry entry point, tail probe, session-tree query. Reuse the existing private helpers. |
| Modify `AgentSessions/Model/SessionTelemetry.swift` | `TelemetryUsageEvent.completedAt: Date?` (optional, decode-if-present). |
| Create `AgentSessions/OpenCode/OpenCodeSessionRate.swift` | Pure: priced events → activity → display. |
| Create `AgentSessions/OpenCode/OpenCodeRateLoader.swift` | Actor: cache, probe, reload, generation, off-main IO. |
| Modify `AgentSessions/Views/AgentCockpitHUDView.swift` | Group model + rendering, owner mapping, refresh task, toggle availability, doc comments. |
| Create `AgentSessionsTests/OpenCodeRecentTelemetryTests.swift` | Task 1–2 SQLite tests (vendor-schema fixture). |
| Create `AgentSessionsTests/OpenCodeSessionRateTests.swift` | Task 3–4 tests. |
| Modify `AgentSessionsTests/OpenCodeHUDGroupTests.swift` | Task 5 tests. |
| Modify localization catalog + validator + its test, `docs/CHANGELOG.md`, baseline | Task 5–6. |

**Vendor-schema fixture.** Task 1 adds `OpenCodeVendorSchemaFixture` in its test file. It holds the exact `CREATE TABLE` / `CREATE INDEX` DDL for `session`, `message`, `part`, `session_v2`, `session_message` as OpenCode 2.1.2 creates them. Capture it read-only from a real 2.1.2 `opencode.db` with `SELECT sql FROM sqlite_master` and paste it in verbatim, with the capture date. Do **not** rely on `OpenCodeV2StoreTests.createV2Tables()`: it lacks the `(session_id, time_created, id)` index.

---

### Task 1: Windowed OpenCode telemetry in the existing reader

**Files:** Modify `OpenCodeSqliteReader.swift`, `SessionTelemetry.swift`. Create `AgentSessionsTests/OpenCodeRecentTelemetryTests.swift`.

**Interfaces — Produces:**
```swift
// SessionTelemetry.swift — new optional field on TelemetryUsageEvent, init param default nil,
// decoded with decodeIfPresent; no parserVersion bump (absent = unknown).
public let completedAt: Date?

extension OpenCodeSqliteReader {
    /// Same contract as `loadTelemetry(for:)` (store selection, fork boundary,
    /// malformed handling, compaction adapter), restricted to rows whose request
    /// started at or after `since`. nil = unreadable store.
    static func loadRecentTelemetry(for session: Session, since: Date) -> SessionTelemetryProviderScan?
}
```

- [ ] **Step 1: Failing tests** (vendor-schema fixture):
  - `testRecentWindowMatchesFullLoadForWindowedRows` — for a mixed session, the events from `loadRecentTelemetry(since:)` equal the events from `loadTelemetry(for:)` filtered to `observedAt >= since`. This is the parity guarantee: one contract, two entry points.
  - `testV1PreferredSessionReadsV1` / `testNewerV2ContinuationReadsV2` / `testEqualTimeMigratedCopyFollowsExistingPredicate` — mirror `OpenCodeV2StoreTests.swift:164-185`.
  - `testForkClonedRowsBeforeForkCreationAreExcluded` — mirror the fork boundary at `OpenCodeSqliteReader.swift:292-310`, with `fork_session_id` / `fork_boundary` set.
  - `testCompactionWithTokensIsIncluded` — mirrors `OpenCodeV2StoreTests.swift:255-269`.
  - `testMalformedCompletedRowMarksUsageUnavailable` — missing component, negative, fractional and overflow values → the scan's usage-unavailable reason is set (the path at `OpenCodeSqliteReader.swift:253-289`). An in-flight row (no completion) is skipped, not flagged.
  - `testCompletedAtComesFromDataTimeCompleted` — v2 `data.time.completed` (epoch ms); v1 step-finish part `time.end` when present; otherwise nil.
  - `testRecentQueryUsesVendorIndex` — `EXPLAIN QUERY PLAN` on the v2 windowed statement contains `USING INDEX` on the `(session_id, time_created, id)` index, and no `SCAN session_message`.
- [ ] **Step 2: Run** `xcodebuild … -only-testing:AgentSessionsTests/OpenCodeRecentTelemetryTests` → FAIL.
- [ ] **Step 3: Implement.** Thread a `since: Date?` through the existing private query functions (`v2Rows` :1476, `queryTelemetryV2` :1697, `queryTelemetryMessages` :729, `queryTelemetryParts` :779). `nil` keeps today's SQL byte for byte. v2 adds `AND time_created >= ?`. v1 selects messages by `(session_id, time_created)` and then their parts by `message_id`. `loadTelemetry(for:)` calls the same path with `since: nil`. Populate `completedAt` where each event is built (v2 adapter `OpenCodeV2MessageAdapter.swift:111-127`, v1 at :515-530).
- [ ] **Step 4: Run** focused tests plus `OpenCodeV2StoreTests` and `SessionTelemetryEngineTests` → PASS (the full-load contract is unchanged).
- [ ] **Step 5: Commit** `feat(opencode): windowed telemetry read for live session rates`.

### Task 2: Tail probe and session tree

**Files:** Modify `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentTelemetryTests.swift`.

**Interfaces — Produces:**
```swift
extension OpenCodeSqliteReader {
    /// Cheap change token for one session: the newest row's (seq, time_updated) for v2,
    /// or (time_created, id, time_updated) for v1, plus the session row's time_updated.
    /// Index seek only. nil = unreadable.
    static func tailToken(databaseURL: URL, sessionID: String) -> String?
    /// Cycle-safe root and descendants from session_v2.parent_id (and v1 session.parent_id),
    /// depth ≤ 8. Unknown id → [id] with root = id.
    static func sessionTree(databaseURL: URL, sessionID: String) -> (root: String, members: [String])?
}
```
- [ ] **Step 1: Failing tests:** `testTailTokenChangesOnAppendAndOnCompletion`, `testTailTokenIgnoresOtherSessions`, `testSessionTreeFindsGrandchildren`, `testSessionTreeStopsOnCycle`, `testSessionTreeDepthCap`, `testTailProbeUsesIndexSeek` (`EXPLAIN QUERY PLAN` uses the `(session_id, seq)` unique index).
- [ ] **Step 2–4:** run → FAIL, implement (recursive CTE with a visited set and depth column), run → PASS.
- [ ] **Step 5: Commit** `feat(opencode): tail probe and session tree for live rates`.

### Task 3: Rate and display from priced events

**Files:** Create `AgentSessions/OpenCode/OpenCodeSessionRate.swift` (add via `xcode_add_file.rb`); tests in `OpenCodeSessionRateTests.swift` (add via `xcode_add_file.rb`).

**Interfaces:**
- Consumes: `TelemetryUsageEvent` (with `completedAt`, `apiEquivalentUSD`); `TelemetryCostCalculator.price(events:fallbackSlices:snapshot:sessionInterval:cacheWriteTTLVerified:recordsCacheWrites:)` → `Result { estimate: TelemetryCostEstimate, events }` (`TelemetryCostCalculator.swift:11-14, 35`), with `estimate.unpricedModels`, `missingPriceComponents`, `freeRouteModels`; `RunwayPresentation`; `RunwayTimeFormatting.rate(_:unit:confidence:)` (declared `AgentCockpitHUDView.swift:5161`).
- Produces:
```swift
struct OpenCodeTreeActivity: Equatable, Sendable {
    let tokensPerSecond: Double
    let dollarsPerSecond: Double?      // nil when any contributing event is unpriced
    let allFreeRoute: Bool
    let usageUnavailable: Bool
    let burstStart: Date
    let newestCompletion: Date
}
enum OpenCodeSessionRate {
    static let burstGap: TimeInterval = 30 * 60
    static let minimumSpan: TimeInterval = 60
    static let freshness: TimeInterval = 5 * 60
    static let cacheReadWeight = 0.10
    /// Events already priced per event by TelemetryCostCalculator. nil = no burst ≥ minimumSpan.
    static func activity(pricedEvents: [TelemetryUsageEvent], estimate: TelemetryCostEstimate,
                         usageUnavailable: Bool) -> OpenCodeTreeActivity?
    static func unit(for presentation: RunwayPresentation) -> RunwayRateUnit   // .dollar → .dollarsPerHour, else .tokensPerHour
    static func display(activity: OpenCodeTreeActivity?, isWorking: Bool, unit: RunwayRateUnit, now: Date) -> OpenCodeRateDisplay
}
enum OpenCodeRateDisplay: Equatable, Sendable {
    case rate(String)                 // RunwayTimeFormatting.rate(value * 3600, unit:, confidence: .direct)
    case free
    case unpriced(models: [String])   // $ lens only; never "$0/h"
    case unavailable                  // malformed usage in the window
    case working                      // no measurable or fresh rate
    case idle
}
```
- [ ] **Step 1: Failing tests:**
  - `testBurstSpanAndTokenWeight` — two events, start-to-newest-completion 120 s, weighted 24 000 → 200 tk/s.
  - `testLongRequestStartedBeforeWindowStillCounts` — `observedAt` = now−35 min, `completedAt` = now−2 min → included.
  - `testGapOverThirtyMinutesStartsNewBurst`, `testSpanUnderSixtySecondsHasNoActivity`.
  - `testFreshnessIsCheckedAtDisplayTime` — the same activity: `display(now: newest+4 min)` → `.rate`; `display(now: newest+6 min)` → `.working`.
  - `testDollarsSumPerEventPrices` — two models plus one long-context event above the threshold. The sum equals the per-event `apiEquivalentUSD` total ÷ span, matching Session Info for the same events.
  - `testPositiveUnpricedCacheWriteIsUnpriced` — a model with no published write rate and a positive cache write → `.unpriced`.
  - `testPriceChangeBoundaryUsesEachEventsDate` — events straddling a dated period (`periods` in a test manifest) price at their own dates.
  - `testAllFreeRouteReadsFree`, `testUnknownModelIsUnpricedNeverZero`, `testUsageUnavailableShowsUnavailable`, `testIdleWins`.
  - `testTokenLensForFiveHourWeeklyAndToken` — `.fiveHour`, `.weekly` and `.token` all map to `.tokensPerHour`.
- [ ] **Step 2–4:** FAIL → implement → PASS. Burst: sort by completion; walk back while `next.observedAt − prev.completion ≤ burstGap`. Only events with `topLineTokens > 0` contribute; zero-volume events are ignored.
- [ ] **Step 5: Commit** `feat(opencode): per-tree tk/h and $/h from priced telemetry events`.

### Task 4: Off-main loader with cache, probe and generations

**Files:** Create `AgentSessions/OpenCode/OpenCodeRateLoader.swift` (via `xcode_add_file.rb`); tests in `OpenCodeSessionRateTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeRateOwner: Hashable, Sendable { let rootSessionID: String; let isWorking: Bool }
actor OpenCodeRateLoader {
    static let shared: OpenCodeRateLoader
    init(reader: OpenCodeRateReading = OpenCodeSqliteRateReader(), clock: @escaping @Sendable () -> Date = { Date() })
    /// Returns displays keyed by root session ID, or nil when `generation` was superseded.
    func displays(owners: [OpenCodeRateOwner], presentation: RunwayPresentation,
                  databaseURL: URL, generation: UInt64) async -> [String: OpenCodeRateDisplay]?
}
protocol OpenCodeRateReading: Sendable {   // seam for tests; production wraps Tasks 1–2
    func tailToken(databaseURL: URL, sessionID: String) -> String?
    func tree(databaseURL: URL, sessionID: String) -> (root: String, members: [String])?
    func recentEvents(databaseURL: URL, sessionID: String, since: Date) -> (events: [TelemetryUsageEvent], usageUnavailable: Bool)?
}
```
- Cache key: `(databaseURL.standardizedFileURL.path, rootSessionID)`. Value: member tail tokens, the last full-read time, and the cached `OpenCodeTreeActivity`.
- Per call: for each owner, compare member tail tokens. Reload all members' recent events when any token changed or 60 s have passed. Price the events with the snapshot from `RunwayPriceTable.shared` (calls `refreshInBackground` lazily, as the runway does). Build the display with `display(now: clock())` **every** call.
- IO runs inside `withCheckedContinuation` on `DispatchQueue.global(qos: .utility)`, as `CodexRunwaySnapshotLoader.snapshot` does (`CodexRunwayModel.swift:606-608`). Check `Task.isCancelled` and the latest generation after the IO; return nil if superseded.
- [ ] **Step 1: Failing tests** (fake `OpenCodeRateReading`): `testInPlaceEditIsPickedUpByPeriodicReload`, `testCachedActivityExpiresAtFreshness`, `testCacheIsKeyedByDatabasePath`, `testStaleReadIsNotPublished` (a slow fake read for generation 1 finishes after generation 2 → returns nil), `testUnchangedTailSkipsReload` (fake counts reads), `testUnreadableStoreGivesWorkingNotZero`.
- [ ] **Step 2: Benchmark test** `testRefreshStaysWithinBudgetOnLargeStore` (real SQLite, vendor fixture): 50 000 `session_message` rows across 200 sessions, a WAL-mode connection writing in the background, 4 owners with 3 descendants each. 20 refreshes; assert p95 ≤ 25 ms. Mark it `XCTSkip` unless `AGENT_SESSIONS_PERF=1`, and record the measured p95 in the commit message.
- [ ] **Step 3–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(opencode): cached off-main rate loader for the Quota Meter`.

### Task 5: Quota Meter integration

**Files:** Modify `AgentCockpitHUDView.swift` — `OpenCodeHUDGroupModel` (246-253), `OpenCodeHUDGroup.make` (262), `HUDOpenCodeSessionsGroup` (4732), `HUDLimitsRowsPanel` (~3858, body ~4166, refresh task ~4269/4481, `runwayRefreshConfigurationID` ~4368), `runwayControlAvailable` (1336), doc comments (233-245, 4729-4731). Modify the localization files. Tests in `OpenCodeHUDGroupTests.swift`.

**Interfaces:**
- Consumes: Tasks 3–4; `OpenCodeBackendDetector.dbURL(customRoot:)` with `PreferencesKey.Paths.opencodeSessionsRootOverride`.
- Produces:
```swift
// OpenCodeHUDGroupModel gains `let rates: [String: OpenCodeRateDisplay]`, keyed by HUDRow.id of the
// single row that displays each tree's rate.
extension OpenCodeHUDGroup {
    static func sessionID(for row: HUDRow) -> String?          // row.resolvedSessionID ?? row.runtimeSessionID
    /// Picks one display row per tree: the visible row whose session is the root, else the visible
    /// row nearest the root. `trees` maps a session ID to its (root, members) from Task 2.
    static func rateRows(visible: [HUDRow], trees: [String: (root: String, members: [String])]) -> [String: String] // rootID → HUDRow.id
    static func make(rows:detectionEnabled:openCodeEnabled:rates:) -> OpenCodeHUDGroupModel?  // rates default [:]
    static func controlAvailable(providersShown: Bool, openCodeGroupVisible: Bool) -> Bool
}
```
- Ownership comes from the **database** tree (Task 2), not `HUDRow.parentSessionID`. Unresolved presences have no parent metadata (`AgentCockpitHUDView.swift:1922-1929, 1993-1996`). `HUDRunwayIdentityReducer` walks an arbitrary parent chain (`rootSessionID`, 3519-3530); the database tree does the same here.
- Refresh task: `.task(id: OpenCodeRateTaskID(dbPath, rootIDs, presentation, visibility, rateSurfaceOnScreen))`. `rateSurfaceOnScreen` uses the same inputs that gate `runRunwayRefreshLoop` (`runwayRefreshConfigurationID`, ~4368), so the strip and window instances follow the existing runway visibility. Each loop iteration bumps a generation, calls the loader, publishes only non-nil results, then sleeps 5 s. Skip all IO when `alwaysOff`, off screen, or the group is nil.
- Row view: `.rate` in `hudProjectionColor` when above zero (match `HUDRunwayPanel.rateCell`, 4909-4924); `.free` → `"Free"`; `.unpriced(models)` → "—" + `.help("No API price for \(models.joined(", "))")`; `.unavailable` → "—" + `.help("Usage data for this session is incomplete.")`; `.working` / `.idle` → the existing `stateLabel`. Width `HUDRunwayLayout.rateWidth(for:)`.
- `runwayControlAvailable` = `controlAvailable(providersShown: <existing>, openCodeGroupVisible: group != nil)`.
- [ ] **Step 1: Failing tests:** `testRateShownOnceOnNearestVisibleAncestor` (root not visible; child and grandchild visible → only the child row has a rate), `testParentAndChildVisibleOnlyParentHasRate`, `testUnresolvedChildPresenceUsesDatabaseTree`, `testMountedRowShowsRateTextInsteadOfStateLabel` (extend `HUDLimitsRowsPanelTestHost` at 4713 with `openCodeRates`), `testControlAvailableForOpenCodeOnly`, `testAlwaysOffAndOffscreenDoNoIO` (fake loader counts calls), `testNewStringsHaveChineseTranslations` (both tooltip keys have zh-Hans values in the catalog).
- [ ] **Step 2–4:** FAIL → implement (catalog + validator count/digest, `python3 scripts/validate_localization_catalogs.py` and its unittest) → PASS.
- [ ] **Step 5: Commit** `feat(opencode): show per-session rates in the Quota Meter`.

### Task 6: Release notes and verification

- [ ] **Step 1:** Add the CHANGELOG `[Unreleased]` entry: OpenCode sessions in the Quota Meter show tk/h, or $/h in the $ lens; free routes read Free; no quota until Go data exists. Lint it with `python3 tools/release/sparkle_release_notes.py --version 6.2 --changelog <copy with [Unreleased]→[6.2]> --lint --out-text <scratch>`.
- [ ] **Step 2:** `./scripts/xcode_test_stable.sh` → TEST SUCCEEDED. Set `tools/release/test-count-baseline.txt` to the **passed** count from the result bundle.
- [ ] **Step 3:** Owner manual check on a real OpenCode 2.x TUI:
  - A working session shows a rate once it has at least 60 s of completed requests; before that it reads "working".
  - The $ lens shows $/h or Free.
  - A long request keeps its last rate for up to 5 min, then reads "working".
  - Closing the TUI removes the row.
  - CPU stays calm with the Quota Meter open for 5 min.
- [ ] **Step 4: Commit** `docs: record OpenCode session rates`.

---

## Findings addressed (rev 1 review)

| # | Finding | Fix in rev 2 |
|---|---|---|
| 1 | Unsound cache key; cached rate bypasses freshness | Tail probe + 60 s full reload; freshness evaluated at display time on every call (Task 4 tests 1–2). |
| 2 | Pricing per model at `now` misprices tiers, writes, periods | Per-event pricing through `TelemetryCostCalculator` (context tier, write-rate rule, `periods` by event date) (Task 3). |
| 3 | Fork clones double-counted | Windowed path reuses the reader's fork boundary (Task 1 test). Members come from the database tree, each read through the same fork-safe path. |
| 4 | v1/v2 selection contract ignored | Windowed path reuses `v2SessionExists` / `v2PreferredPredicate` (Task 1 tests). |
| 5 | Malformed completed usage undercounted | Reuses the reader's usage-unavailable rule → `.unavailable` (Tasks 1, 3). |
| 6 | Compaction exclusion contradicts Session Info | Decision: compaction counts; reconciliation via the shared pricing path (Task 3). |
| 7 | Index claim unbacked; scan risk | Vendor-schema fixture from real 2.1.2 DDL; `EXPLAIN QUERY PLAN` tests; large-store benchmark with WAL writer (Tasks 1, 2, 4). |
| 8 | Lookback by start excludes long requests | `completedAt` on events; SQL bound 2 h by start, filter by completion (Tasks 1, 3). |
| 9 | Child depth and double reporting | Cycle-safe database tree; one display row per tree (Tasks 2, 5). |
| 10 | UI lifecycle, keys, concurrency | Task identity includes the DB path and the on-screen gate; generations; cancellation before publish (Tasks 4, 5). |
| 11 | References and tests | `rate` at :5161; arbitrary-depth reducer noted; Claude rule differences stated; both test files registered; passed-count baseline; zh-Hans test; manual check matches the 60 s floor. |
