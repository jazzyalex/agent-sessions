# OpenCode Session Rates in the Quota Meter — Implementation Plan (rev 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each running OpenCode 2.x session row in the Quota Meter shows that session's own token rate (tk/h), or its API-equivalent cost rate ($/h) in the $ lens, from local data only.

**Architecture:** The existing OpenCode telemetry reader gets a **batch, time-windowed** entry point: one read-only connection and one read transaction per refresh cycle. It returns completed usage events with their completion times, and reuses the reader's store selection, fork boundary, malformed-usage rule and compaction adapter. A pure function selects each session's newest burst and prices **exactly those events** with the Session Info calculator. **One shared sampler** owns the only refresh loop. It runs only while a Quota Meter surface on screen is showing OpenCode rates, and it publishes one versioned snapshot that every view reads.

**Tech Stack:** Swift 5 / SwiftUI, SQLite3 C API (read-only), XCTest.

**Spec:** This plan is the spec. Owner decisions:
- **v1 scope (2026-10-26):** a row shows its **own session's** rate only. No child-session trees, no aggregation, no ownership mapping. A parent's rate excludes its children; a visible child row shows its own rate, so nothing is counted twice.
- Only tk/h and $/h. No 5h or weekly quota for OpenCode until OpenCode Go subscription data exists.
- OpenCode 2.x live sessions only. Desktop sessions get a rate only while working.
- **Compaction counts** as a billable call, so $/h reconciles with Session Info.
- **Free routes read "Free"** in the $ lens (existing `"Free"` catalog key).
- **Requests that started more than 2 h ago are not shown** (product rule). Their row reads "working" until a newer request completes.
- Target release: 6.2.

**Review history:** rev 1 (21252ba2) NO-SHIP, 11 findings. Rev 2 (e0a53360) NO-SHIP, 11 findings, 3 of rev 1's fully fixed. "Findings addressed" at the end maps every rev-2 finding to its fix here.

## Global Constraints

- macOS 14.0 target. `UsageTrackingSource` stays `.codex` / `.claude`. `RunwayPresentation` keeps four cases.
- `opencode.db` access is read-only: `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` (pattern `OpenCodeSqliteReader.swift:187-193`). **Exactly one connection and one `BEGIN`…`ROLLBACK` read transaction per refresh cycle**, closed before pricing or publishing. Never write and never create indexes.
- No database IO unless the sampler is active (Task 4). No network.
- `loadTelemetry(for:)` behavior is unchanged: the `since: nil` path keeps today's SQL and results.
- Every new Swift file, production and test, is added with `scripts/xcode_add_file.rb` (4 `project.pbxproj` lines per file). Confirm the new test classes run.
- New strings go into `Localizable.xcstrings` (en + zh-Hans), with the count and digest updated in `scripts/validate_localization_catalogs.py:42-45` and `scripts/tests/test_validate_localization_catalogs.py`.
- Visible behavior is recorded in **both** `docs/CHANGELOG.md` and `docs/summaries/2026-MM.md` (agents.md:134-136).
- Test-count baseline is the **passed** count (3905 at 21252ba2).
- Commits: Conventional Commits + `Tool:`/`Model:`/`Why:` trailers, `git commit -- <paths>`.

## Fixed values

| Name | Value |
|---|---|
| SQL start bound | `time_created >= now − 2 h` (v2 `session_message`, v1 `message`) |
| Completion window | events with `completedAt >= now − 30 min` |
| Burst gap | ≤ 30 min from one event's `completedAt` to the next one's `observedAt` |
| Minimum burst span | 60 s from the burst's first `observedAt` to its newest `completedAt` |
| Freshness | newest `completedAt` within 5 min of now, evaluated on **every** published snapshot |
| Token weight | fresh input + output (incl. reasoning) + cache writes + 0.10 × cache read (same as `ClaudeRunwayTokenActivityParser.weightedTokens`, :555-564) |
| Sampler cadence | 5 s while active |
| Full reload | a session is re-read when its tail token changes, or 60 s after its last read |
| Max sessions per cycle | 4 (`OpenCodeHUDGroup.maxVisibleSessions`) |
| Performance gate | p95 ≤ 25 ms per cycle for 4 sessions on the large fixture, exactly 1 DB open per cycle; a required step in Task 6 |

These rules differ from Claude's on purpose (Claude: 30 s freshness, 10 s minimum, provisional single turn, `ClaudeRunwayTokenActivityParser.swift:42-60, 370-438`). OpenCode records tokens only when a request completes. Only the token weight is shared.

## Review Focus

1. **A window with only an in-flight request.** Expect "working", not "unavailable". Test `testInFlightOnlyWindowIsNoUsage` (Task 2).
2. **A stale unpriced request before a fully priced burst.** Expect the recent burst's $/h. Test `testOldUnpricedOutsideBurstDoesNotHideRate` (Task 3).
3. **The strip collapses while OpenCode rates are showing.** Expect the sampler to stop within one cycle, with no further DB opens. Test `testCollapsedStripStopsSampling` (Task 4).
4. **The database root changes while sampling.** Expect the cache cleared, the old snapshot dropped, and no mixing. Test `testDatabaseChangeResetsCacheAndSnapshot` (Task 4).
5. **A completion time lost through pricing.** Expect `completedAt` to survive `TelemetryCostCalculator.price`. Test `testCompletedAtSurvivesPricing` (Task 1).

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `AgentSessions/Model/SessionTelemetry.swift` | `TelemetryUsageEvent.completedAt`; `priced(...)` copies it. |
| Modify `AgentSessions/OpenCode/OpenCodeV2MessageAdapter.swift` | Carry completion into the synthetic step-finish part. |
| Modify `AgentSessions/OpenCode/OpenCodeSqliteReader.swift` | Completion on usage rows/events; batch windowed entry point with window states. |
| Create `AgentSessions/OpenCode/OpenCodeSessionRate.swift` | Pure: burst selection, subset pricing, activity, display value. |
| Create `AgentSessions/OpenCode/OpenCodeRateSampler.swift` | Shared sampler (the only loop), demand registry, published snapshot. |
| Modify `AgentSessions/Views/AgentCockpitHUDView.swift` | Demand reporting, row rendering, toggle availability, doc comments. |
| Create `AgentSessionsTests/OpenCodeRecentUsageTests.swift` | Tasks 1–2 (with `OpenCodeVendorSchemaFixture`). |
| Create `AgentSessionsTests/OpenCodeSessionRateTests.swift` | Tasks 3–4. |
| Modify `AgentSessionsTests/OpenCodeHUDGroupTests.swift` | Task 5. |

**`OpenCodeVendorSchemaFixture`.** The test file checks in the **schema-only** DDL (`SELECT sql FROM sqlite_master WHERE type IN ('table','index')`) for `session`, `message`, `part`, `session_v2`, `session_message`, as created by OpenCode 2.1.2. Record the OpenCode version, capture date, and SHA-256 of the DDL text in a comment. It contains no row data. The checked-in `OpenCodeV2StoreTests.createV2Tables()` is not used: it lacks the `(session_id, time_created, id)` index.

---

### Task 1: Carry completion time end to end

**Files:** `SessionTelemetry.swift`, `OpenCodeV2MessageAdapter.swift`, `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentUsageTests.swift`.

**Interfaces — Produces:**
```swift
// TelemetryUsageEvent: new stored property, init parameter `completedAt: Date? = nil`,
// Codable via decodeIfPresent (absent → nil). No parserVersion bump.
public let completedAt: Date?
// priced(usd:revision:updated:manifestFingerprint:) passes completedAt through.
```
- Data path: the v2 assistant `data.time.completed` (epoch ms) is copied by `stepFinishPart` (`OpenCodeV2MessageAdapter.swift:146-157`) into the part as `"completedAt"`. A token-bearing compaction with `status == "completed"` and no `time.completed` uses the row's `time_updated`. v1 step-finish parts use `part.time.end` when present. The private `OpenCodeTelemetryUsageRow` gains `completedAt: Date?`, and the event built at `OpenCodeSqliteReader.swift:478-501` sets it.
- [ ] **Step 1: Failing tests:** `testCompletedAtFromV2AssistantTime`, `testCompactionWithoutTimeCompletedUsesRowUpdate`, `testV1PartTimeEnd`, `testCompletedAtSurvivesPricing` (price via `TelemetryCostCalculator.price(events:fallbackSlices:snapshot:…)`, `TelemetryCostCalculator.swift:43-48`; the priced event keeps `completedAt`), `testDecodesEventWithoutCompletedAt` (old cached JSON).
- [ ] **Step 2:** run `-only-testing:AgentSessionsTests/OpenCodeRecentUsageTests` → FAIL.
- [ ] **Step 3:** implement as above.
- [ ] **Step 4:** run focused tests, plus `OpenCodeV2StoreTests` and `SessionTelemetryEngineTests` (unchanged full-load results) → PASS.
- [ ] **Step 5: Commit** `feat(telemetry): carry OpenCode request completion time`.

### Task 2: Batch windowed reader with explicit window states

**Files:** `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentUsageTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeRecentUsageRequest: Sendable { let sessionID: String; let previousTail: String?; let forceReload: Bool }
enum OpenCodeRecentWindow: Equatable, Sendable {
    case noCompletedUsage                       // nothing completed in the window (empty, user-only, in-flight only)
    case usage([TelemetryUsageEvent])           // completed events, unpriced, completedAt set
    case unavailable                            // a completed row in the window has malformed/missing usage
}
enum OpenCodeRecentUsageResult: Equatable, Sendable {
    case unchanged(tail: String)
    case loaded(tail: String, window: OpenCodeRecentWindow)
    case unreadable
}
extension OpenCodeSqliteReader {
    /// One connection, one read transaction for all requests. nil = the store could not be opened.
    static func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest],
                            now: Date) -> [String: OpenCodeRecentUsageResult]?
    #if DEBUG
    nonisolated(unsafe) static var databaseOpenCountForTesting = 0
    #endif
}
```
- Per session, inside the one transaction:
  1. Pick the store with the existing `v2SessionExists` / `v2PreferredPredicate` (:1421-1435).
  2. Compute the tail token: v2 newest `(seq, time_updated)` by the `(session_id, seq)` unique index plus `session_v2.time_updated`; v1 newest `message (time_created, id, time_updated)`.
  3. If the tail is unchanged and there is no `forceReload`, return `.unchanged`.
  4. Otherwise read rows with `time_created >= now − 2 h` through the existing private helpers. Thread `since: Date?` through `v2Rows` (:1476), `queryTelemetryV2` (:1697), `queryTelemetryMessages` (:729) and `queryTelemetryParts` (:779). Apply the existing fork boundary (:292-310) and the compaction adapter.
  5. Classify the window: an assistant with no completion evidence (no `time.completed`, not a completed compaction) is **in-flight and ignored**. A completed row whose usage fails the reader's existing validation (:229-289, :460-501) gives `.unavailable`. No completed usage gives `.noCompletedUsage`. Otherwise `.usage(events)` keeps events with `completedAt >= now − 30 min`.
- [ ] **Step 1: Failing tests** (vendor fixture):
  - `testOneDatabaseOpenPerCall` — 4 sessions → `databaseOpenCountForTesting` +1.
  - `testUnchangedTailSkipsRead`, `testForceReloadRereads`, `testInPlaceEditCaughtByForceReload`.
  - `testInFlightOnlyWindowIsNoUsage`, `testUserOnlyWindowIsNoUsage`, `testMalformedCompletedRowIsUnavailable` (missing component, negative, fractional, overflow), `testCompletedCompactionIncluded`.
  - `testLongRequestStartedWithinTwoHoursCompletedNowIncluded`, `testRequestStartedOverTwoHoursAgoExcluded`.
  - `testStoreSelectionMatchesFullLoad` — v1-only, equal-time migrated copy, newer v2 continuation: the same store as `loadTelemetry(for:)`.
  - `testForkClonedRowsExcluded`.
  - `testWindowParityWithFullLoad` — for rows with `time_created >= since`, the normalized tuples `(recordID, model, fresh, cacheRead, cacheWrite5m, output, reasoning, completedAt)` equal those from `loadTelemetry(for:)` filtered by the same start timestamp. `anchorLine` is excluded from the comparison; `testAnchorLinesAreDenseInWindow` covers it separately.
  - `testQueryPlansUseIndexes` — `EXPLAIN QUERY PLAN` for the v2 window query uses the `(session_id, time_created, id)` index with no `SCAN session_message`, and the tail probe uses the `(session_id, seq)` index. Write down whether the `ORDER BY seq` needs a temp B-tree; if it does, order in memory instead.
  - `testConsistentUnderConcurrentWALWriter` — a writer connection appends during the read; the result is one coherent snapshot (tail and rows agree).
- [ ] **Step 2–4:** FAIL → implement → PASS (plus `OpenCodeV2StoreTests`, `SessionTelemetryEngineTests`).
- [ ] **Step 5: Commit** `feat(opencode): batch windowed usage read for live session rates`.

### Task 3: Burst first, then price exactly the burst

**Files:** Create `OpenCodeSessionRate.swift`; tests in `OpenCodeSessionRateTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeSessionActivity: Equatable, Sendable {
    let tokensPerHour: Double
    let dollarsPerHour: Double?   // nil when any burst event is unpriced or misses a price component
    let allFreeRoute: Bool        // every contributing burst event resolved through a free route
    let newestCompletion: Date
}
enum OpenCodeRateValue: Equatable, Sendable {
    case rate(Double, RunwayRateUnit)   // numeric; the view formats and colors it
    case free, unpriced(models: [String]), unavailable, working, idle
}
enum OpenCodeSessionRate {
    static let burstGap: TimeInterval = 30 * 60, minimumSpan: TimeInterval = 60
    static let freshness: TimeInterval = 5 * 60, cacheReadWeight = 0.10
    static func burst(_ events: [TelemetryUsageEvent]) -> [TelemetryUsageEvent]?          // contributing events of the newest burst, or nil
    static func activity(burst: [TelemetryUsageEvent], prices: RunwayPriceSnapshot) -> OpenCodeSessionActivity
    static func unit(for presentation: RunwayPresentation) -> RunwayRateUnit              // .dollar → .dollarsPerHour else .tokensPerHour
    static func value(window: OpenCodeRecentWindow?, activity: OpenCodeSessionActivity?,
                      isWorking: Bool, unit: RunwayRateUnit, now: Date) -> OpenCodeRateValue
}
```
- `burst`: keep only events with `topLineTokens > 0`, sort by `completedAt`, walk back while the gap rule holds, and require a span of at least `minimumSpan`.
- `activity`: call `TelemetryCostCalculator.price(events: burst, fallbackSlices: [], snapshot: prices)` on the **burst only**. `dollarsPerHour` is nil when the result's `estimate.unpricedModels` or `missingPriceComponents` is non-empty, or when any priced event has `apiEquivalentUSD == nil`. `allFreeRoute` = every burst event's model is in `estimate.freeRouteModels`.
- `value`: idle → `.idle`; window `.unavailable` → `.unavailable`; no activity or stale (`now − newestCompletion > freshness`) → `.working`; $ unit with `allFreeRoute` → `.free`; $ unit with nil dollars → `.unpriced`; else `.rate`.
- [ ] **Step 1: Failing tests:** `testBurstSpanAndWeight` (24 000 weighted over 120 s → 720 000 tk/h), `testGapStartsNewBurst`, `testShortSpanHasNoBurst`, `testOldUnpricedOutsideBurstDoesNotHideRate`, `testMixedFreeAndPaidIsNotFree`, `testAllFreeIsFree`, `testMissingWriteRateIsUnpriced`, `testPeriodBoundaryPricesEachEventAtItsDate`, `testLongContextEventPricedAtItsTier`, `testDollarsMatchSessionInfoForSameEvents`, `testFreshnessAtValueTime` (newest+4 min → rate, +6 min → working), `testIdleWins`, `testUnavailableWins`, `testLensMapping`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(opencode): per-session tk/h and $/h from the newest burst`.

### Task 4: One shared sampler, driven by real demand

**Files:** Create `OpenCodeRateSampler.swift`; tests in `OpenCodeSessionRateTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeRateDemand: Equatable, Sendable { let sessions: [String: Bool] }  // sessionID → isWorking
@MainActor @Observable final class OpenCodeRateStore {
    static let shared: OpenCodeRateStore
    private(set) var snapshot: OpenCodeRateSnapshot   // published by the sampler only
    /// Each Quota Meter surface reports what it shows. nil = this surface shows no OpenCode rates
    /// (hidden, strip collapsed, group absent, visibility alwaysOff).
    func setDemand(_ surface: UUID, _ demand: OpenCodeRateDemand?)
}
struct OpenCodeRateSnapshot: Equatable, Sendable {
    let databasePath: String?; let presentation: RunwayPresentation; let version: UInt64
    let values: [String: OpenCodeRateValue]   // sessionID → value
}
protocol OpenCodeRecentUsageReading: Sendable {   // production wraps OpenCodeSqliteReader.recentUsage
    func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest], now: Date) -> [String: OpenCodeRecentUsageResult]?
}
actor OpenCodeRateSampler {
    init(store: OpenCodeRateStore, reader: OpenCodeRecentUsageReading,
         clock: @escaping @Sendable () -> Date, databaseURL: @escaping @Sendable () -> URL?,
         presentation: @escaping @Sendable () -> RunwayPresentation, prices: @escaping @Sendable () -> RunwayPriceSnapshot)
    func demandChanged(_ union: OpenCodeRateDemand?)   // called by the store; starts or stops the loop
}
```
- **One loop.** Only the sampler loops. It starts when the union of surface demands is non-empty and stops (cancels) when it becomes nil. Views never loop and never pass generation numbers, so independent surfaces cannot collide.
- **Union.** Session IDs are merged across surfaces (`isWorking` = OR), capped at 4 sessions in first-seen order.
- **Cycle.** Read the DB URL (`OpenCodeBackendDetector.dbURL(customRoot:)` with `PreferencesKey.Paths.opencodeSessionsRootOverride`). If the path changed, clear the cache and publish an empty snapshot for the new path. Then make one `recentUsage` call off the main thread (`withCheckedContinuation` on `DispatchQueue.global(qos: .utility)`, as at `CodexRunwayModel.swift:606-608`). Update the cache: per `(path, sessionID)`, the tail, last read, window and activity. Build values with the current clock **every** cycle. If not cancelled, publish to the store on the main actor with `version + 1`. A cancelled cycle mutates neither the cache nor the store.
- **Demand source.** Each `HUDLimitsRowsPanel` instance reports demand under its own UUID:
  - Non-nil only when the OpenCode group is shown with rates enabled (visibility not `.alwaysOff`).
  - For the strip surface, only when expanded (`@Environment(\.quotaStripExpanded)`, as at `AgentCockpitHUDView.swift:4814`).
  - Set on appear and on changes; nil on disappear.
  - This sits alongside `QuotaMeterPollingRegistry` (`AgentCockpitHUDView.swift:690-716`) and follows the same per-surface UUID pattern.
- [ ] **Step 1: Failing tests** (fake reader that counts calls, fake clock, fake store observer):
  - `testNoDemandNoIO`, `testDemandStartsAndNilStops`.
  - `testCollapsedStripStopsSampling` — the demand goes nil; no reader call after one cycle.
  - `testTwoSurfacesShareOneLoop` — two demands → one reader call per cycle.
  - `testDatabaseChangeResetsCacheAndSnapshot`.
  - `testCancelledCycleDoesNotPublishOrCache` — a slow fake read, demand removed mid-read.
  - `testCachedActivityExpiresAtFreshness`.
  - `testPeriodicForceReloadAfterSixtySeconds`.
  - `testUnreadableStoreGivesWorking`.
  - `testSnapshotVersionIncreases`.
- [ ] **Step 2: Benchmark** `testCycleWithinBudgetOnLargeStore`: real SQLite with the vendor fixture, 50 000 `session_message` rows over 200 sessions with an active 2-hour tail, plus a WAL writer. Measure 4 sessions over 30 cycles, warm and changed-tail. Assert p95 ≤ 25 ms and exactly 1 DB open per cycle. It runs only with `AGENT_SESSIONS_PERF=1`; Task 6 makes that run required.
- [ ] **Step 3–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(opencode): shared demand-driven rate sampler`.

### Task 5: Quota Meter rendering

**Files:** `AgentCockpitHUDView.swift` (`HUDOpenCodeSessionsGroup` 4732, `HUDLimitsRowsPanel` 3858 / body 4188, `runwayControlAvailable` 1336, doc comments 233-245 and 4729-4731); localization files; tests in `OpenCodeHUDGroupTests.swift`.

**Interfaces:** Consumes `OpenCodeRateStore.shared.snapshot` and `OpenCodeHUDGroup.sessionID(for row: HUDRow) -> String?` (= `row.resolvedSessionID ?? row.runtimeSessionID`, new). Produces `static func OpenCodeHUDGroup.controlAvailable(providersShown: Bool, openCodeGroupVisible: Bool) -> Bool`.
- Row: look up `snapshot.values[sessionID]`, ignoring the snapshot if its `presentation` differs from the current one.
  - `.rate(v, unit)` → `RunwayTimeFormatting.rate(v, unit:, confidence: .direct)` (:5161), in `hudProjectionColor` when `v > 0` (numeric, not text), else secondary.
  - `.free` → `"Free"`.
  - `.unpriced(models)` → "—" + `.help("No API price for \(models.joined(separator: ", "))")`.
  - `.unavailable` → "—" + `.help("Usage data for this session is incomplete.")`.
  - `.working` / `.idle` / missing → the existing `stateLabel`.
  - Width `HUDRunwayLayout.rateWidth(for:)`.
- Toggle: `runwayControlAvailable` = `controlAvailable(providersShown: <existing expression>, openCodeGroupVisible: group != nil)`.
- [ ] **Step 1: Failing tests:** `testRowShowsOwnSessionRate`, `testParentAndChildRowsShowTheirOwnRates`, `testSnapshotForOtherPresentationIgnored`, `testPositiveRateUsesProjectionColorEvenWhenQuiet`, `testMountedStripReportsDemandOnlyWhenExpanded` (mount `HUDLimitsRowsPanelTestHost` (4713) with `quotaStripExpanded` false/true and assert `setDemand` calls through an injected store), `testAlwaysOffReportsNoDemand`, `testControlAvailableForOpenCodeOnly`, `testNewStringsHaveChineseTranslations`.
- [ ] **Step 2–4:** FAIL → implement (catalog + validator count/digest; run the validator and its unittest) → PASS.
- [ ] **Step 5: Commit** `feat(opencode): show per-session rates in the Quota Meter`.

### Task 6: Docs and required verification

- [ ] **Step 1:** CHANGELOG `[Unreleased]` entry: OpenCode sessions in the Quota Meter show tk/h, or $/h in the $ lens; free routes read Free; no quota until Go data exists. Add the matching line to `docs/summaries/2026-MM.md` for the month it lands. Lint with `python3 tools/release/sparkle_release_notes.py --version 6.2 --changelog <copy, [Unreleased]→[6.2]> --lint --out-text <scratch>`.
- [ ] **Step 2:** `./scripts/xcode_test_stable.sh` → TEST SUCCEEDED. Set the baseline to the **passed** count from the result bundle.
- [ ] **Step 3 (required):** `AGENT_SESSIONS_PERF=1 xcodebuild … -only-testing:AgentSessionsTests/OpenCodeSessionRateTests/testCycleWithinBudgetOnLargeStore` → PASS. Record p95 and DB opens per cycle in the commit message.
- [ ] **Step 4:** Owner manual check, real OpenCode 2.x TUI:
  - A rate appears once 60 s of completed requests exist; before that the row reads "working".
  - The $ lens shows $/h or Free.
  - A long request keeps its rate for up to 5 min, then the row reads "working".
  - Collapsing the strip stops DB reads (check with `fs_usage -f filesys | grep opencode.db` for 30 s).
  - CPU stays calm with the Quota Meter open for 5 min.
- [ ] **Step 5: Commit** `docs: record OpenCode session rates`.

---

## Findings addressed (rev 2 review)

| # | Rev-2 finding | Fix in rev 3 |
|---|---|---|
| P1-1 | Completion time lost before/during pricing; wrong line refs | Task 1 carries it through the adapter (:146-157), the usage row, event build (:478-501) and `priced()` (`SessionTelemetry.swift:291-303`); test after pricing. |
| P1-2 | Empty / in-flight windows misread as unavailable | `OpenCodeRecentWindow` with explicit states; completion evidence, including completed compaction (Task 2). |
| P1-3 | Estimate priced over a different set than the burst | Burst selected first; `price` called on burst events only; free = all burst events (Task 3). |
| P1-4 | Ownership / tree contract missing | Scope cut: each row shows its own session; no trees, no mapping, no double count. |
| P1-5 | Shared-actor generations unsafe across views | One sampler owns the only loop; views only report demand and read a versioned snapshot (Task 4). |
| P1-6 | No real on-screen signal | Per-surface demand: group shown, not `alwaysOff`, strip expanded; same UUID pattern as `QuotaMeterPollingRegistry` (:690-716); mounted test (Tasks 4–5). |
| P1-7 | Per-member calls break the one-transaction rule | `recentUsage` batch: one open, one read transaction per cycle, counted in tests (Task 2). |
| P2-8 | Parity test invalid; >2 h blind spot | Normalized tuple parity on the same start population, anchors tested separately; >2 h is a stated product rule. |
| P2-9 | Benchmark optional | Checked-in schema-only DDL with version/date/hash; WAL consistency test; perf run required in Task 6 with DB-open count. |
| P2-10 | Display loses the number; no IO seam; monthly summary | `OpenCodeRateValue.rate(Double, unit)`; reader protocol + injected store; summaries step in Task 6. |
| P3-11 | Wrong refs; broad tasks | Adapter :146-157, reader :478-501, calculator :43-48, HUD body :4188, rate :5161. Tasks split by contract: completion, reader, rate, sampler, UI, docs. |
