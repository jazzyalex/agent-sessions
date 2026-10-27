# OpenCode Session Rates in the Quota Meter — Implementation Plan (rev 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each running OpenCode 2.x session row in the Quota Meter shows that session's own token rate (tk/h), or its API-equivalent cost rate ($/h) in the $ lens, from local data only.

**Architecture:** The existing OpenCode telemetry reader gets a **batch, time-windowed** entry point: one read-only connection and one read transaction per refresh cycle. It classifies each in-window request from its **raw** row (completed, in flight, or completed-but-malformed) and returns completed usage events with their completion times. It reuses the reader's store selection, fork boundary, strict token validation and compaction accounting. A pure function selects each session's newest burst and prices **exactly those events** with the Session Info calculator, keeping the pricing outcome and its reasons. **One shared sampler** owns the only refresh loop. It receives demand through one ordered mailbox, runs only while some Quota Meter surface shows OpenCode rates, never overlaps reads, and publishes one versioned snapshot that every view reads. The view also hides rates itself when rate visibility is off.

**Tech Stack:** Swift 5 / SwiftUI, SQLite3 C API (read-only), XCTest.

**Spec:** This plan is the spec. Owner decisions:
- **v1 scope (2026-10-26):** a row shows its **own session's** rate only. No child-session trees or aggregation. A parent's rate excludes its children; a visible child row shows its own rate, so nothing is counted twice.
- Only tk/h and $/h. No 5h or weekly quota for OpenCode until OpenCode Go subscription data exists.
- OpenCode 2.x live sessions only. Desktop sessions get a rate only while working.
- **Compaction counts** as a billable call, so $/h reconciles with Session Info. A completed compaction with invalid usage makes the window unavailable. **Amended at implementation (owner accepted 2026-10-26):** a completed compaction with *absent* tokens counts as no usage, as in Session Info (3 of 5 real completed compactions carry none). A v2 assistant row with valid tokens but no `time.completed` (errored requests) counts at the row's update time.
- **Free routes read "Free"** in the $ lens (existing `"Free"` catalog key).
- **Requests that started more than 2 h ago are not shown** (product rule). The row reads "working" until a newer request completes.
- **Every session row visible on any surface is sampled.** No cross-surface cap.
- Target release: 6.2.

**Review history:**

| Rev | Commit | Result |
|---|---|---|
| 1 | 21252ba2 | NO-SHIP, 11 findings |
| 2 | e0a53360 | NO-SHIP, 11 findings |
| 3 | c6d1e009 | NO-SHIP, 6 blockers + 3 improvements |
| 4 | c5281ed9 | NO-SHIP, 2 blockers + 5 implementation corrections |
| 5 | this commit | Fixes rev 4's items. The owner accepted it as ready to implement without a fifth plan review (2026-10-26); the implementation gets its own review. |

"Findings addressed" at the end maps each rev-3 and rev-4 item to its fix.

## Global Constraints

- macOS 14.0 target. `UsageTrackingSource` stays `.codex` / `.claude`. `RunwayPresentation` keeps four cases.
- `opencode.db` is read-only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, `OpenCodeSqliteReader.swift:187-193`). **Exactly one connection and one `BEGIN`…`ROLLBACK` read transaction per refresh cycle**, closed before pricing or publishing. Never write, never create indexes, never run two reads at once.
- No database IO unless the sampler is active (Task 5). No network.
- `loadTelemetry(for:)` behavior and results are unchanged (`since: nil` keeps today's SQL).
- New Swift files, production and test, are added with `scripts/xcode_add_file.rb` (4 `project.pbxproj` lines per file). Confirm the new test classes run.
- New strings go into `Localizable.xcstrings` (en + zh-Hans), with the count/digest updated in `scripts/validate_localization_catalogs.py:42-45` and its unittest.
- Visible behavior goes in **both** `docs/CHANGELOG.md` and the monthly `docs/summaries/2026-10.md` (or `2026-11.md` if it lands then) (agents.md:134-136).
- Test-count baseline = the **passed** count (3905 at 21252ba2).
- **Commits need the owner's go-ahead** (CLAUDE.md:12-16, agents.md:123-132). Each task's last step prepares a scoped Conventional Commits message with `Tool:`/`Model:`/`Why:` trailers and commits with `git commit -- <paths>` only after the owner approves.

## Fixed values

| Name | Value |
|---|---|
| SQL start bound | v2: `session_message.time_created >= now − 2 h`; v1: owning `message.time_created >= now − 2 h` |
| Completion window | events with `completedAt >= now − 30 min` |
| Burst gap | ≤ 30 min from one event's `completedAt` to the next one's `observedAt` |
| Minimum burst span | 60 s from the burst's first `observedAt` to its newest `completedAt` |
| Freshness | newest `completedAt` within 5 min of now, evaluated on **every** published snapshot |
| Token weight | fresh input + output (incl. reasoning) + cache writes + 0.10 × cache read (`ClaudeRunwayTokenActivityParser.weightedTokens`, :555-564) |
| Sampler cadence | 5 s while active, never overlapping |
| Full reload | a session is re-read when its tail token changes, or 60 s after its last read |
| Sessions per cycle | every distinct session ID visible on any surface; in practice ≤ 4 × surfaces (`OpenCodeHUDGroup.maxVisibleSessions` per surface; window + strip = 8) |
| Performance gate | p95 ≤ 25 ms per cycle for **8** sessions on the large fixture, exactly 1 DB open per cycle; required in Task 7 |

These rules differ from Claude's on purpose (Claude: 30 s freshness, 10 s minimum, provisional single turn, `ClaudeRunwayTokenActivityParser.swift:42-60, 370-438`). OpenCode records tokens only when a request completes. Only the token weight is shared.

## Request classification (raw rows, inside the window)

| Row | Condition | Result |
|---|---|---|
| v2 `assistant` | `data.time.completed` present, usage passes strict validation | usage event, `completedAt` = `time.completed` |
| v2 `assistant` | `data.time.completed` present, usage missing or invalid | window **unavailable** |
| v2 `assistant` | no `data.time.completed` | in flight, ignored |
| v2 `compaction` | `status == "completed"`, `tokens` valid | usage event, `completedAt` = `time.completed` ?? row `time_updated` |
| v2 `compaction` | `status == "completed"`, `tokens` missing or invalid | window **unavailable** |
| v2 `compaction` | any other status | in flight, ignored |
| v1 step-finish part of an eligible message | usage valid | usage event, `completedAt` = `part.time.end` ?? part row `time_updated` |
| v1 step-finish part of an eligible message | usage invalid | window **unavailable** |
| v1 assistant message with no step-finish part | — | in flight, ignored |
| any | — | rows of other types are not requests |
| v2 row of any type | `data` JSON cannot be decoded | window **unavailable** (the type of request cannot be ruled out) |
| v2 `assistant` / `compaction` | completion field present but not a positive integer epoch-millisecond value | window **unavailable** |
| v1 eligible message or its part | JSON cannot be decoded | window **unavailable** (it could hide step-finish evidence) |
| v1 step-finish part | `time.end` present but not a positive integer epoch-millisecond value | window **unavailable** |

**Only a successfully decoded row with no completion marker is "in flight".** Decode and timestamp failures use the reader's existing `malformedPayload` tracking (`OpenCodeSqliteReader.swift:273-286, 751-770, 784-827, 1695-1735`) and fail closed.

**Which malformed rows count.** A row counts toward "unavailable" only if it could belong to the 30-minute completion window. For an undecodable row, or one whose completion is malformed, that means its row `time_updated` (v2 `session_message`, v1 `part`/`message`) is ≥ now − 30 min. A malformed row that was last written longer ago than that is outside the window and ignored. So an old broken request does not poison a new burst, and a recent one always does.

**Timestamp parsing.** A completion value counts only if it is a positive `Int64` epoch-millisecond, or a JSON number that converts to one exactly. Anything else is "malformed", never "missing". The compaction and v1 fallbacks (`time_updated` columns) are SQL integers and are used only when the JSON field is absent.

"Strict validation" is the reader's existing rule (`OpenCodeSqliteReader.swift:229-289, 460-501`): every component present, a finite non-negative integer, no addition overflow. Classification reads the raw v2 row **before** `OpenCodeV2MessageAdapter` transforms it, because the adapter drops tokenless compactions (`OpenCodeV2MessageAdapter.swift:120-126`).

## Review Focus

1. **A completed compaction without tokens.** Expect "unavailable", not a silently smaller rate. Test `testCompletedTokenlessCompactionIsUnavailable` (Task 2).
2. **Two surfaces showing disjoint sets of 4 sessions.** Expect all 8 sampled. Test `testDisjointSurfacesAllSampled` (Task 5).
3. **Rate visibility switched to Always Off while a rate is shown.** Expect the label to revert at once, even with a populated snapshot. Test `testAlwaysOffHidesExistingRate` (Task 6).
4. **v1 part in the window whose message started over 2 h ago.** Expect it excluded. Test `testV1PartOfOldMessageExcluded` (Task 2).
5. **Hide then show while a read is blocked.** Expect no publish from the stale read and no second overlapping read. Test `testHideShowDuringBlockedRead` (Task 5).

---

## File Structure

| File | Responsibility |
|---|---|
| Modify `AgentSessions/Model/SessionTelemetry.swift` | `TelemetryUsageEvent.completedAt`; `priced(...)` copies it. |
| Modify `AgentSessions/OpenCode/OpenCodeV2MessageAdapter.swift` | `adapt` takes `timeUpdatedMillis`; the step-finish part carries completion. |
| Modify `AgentSessions/OpenCode/OpenCodeSqliteReader.swift` | Completion on usage rows/events; raw classification; v1 message-scoped window; batch entry point. |
| Create `AgentSessions/OpenCode/OpenCodeSessionRate.swift` | Pure: burst selection, subset pricing outcome, display value. |
| Create `AgentSessions/OpenCode/OpenCodeRateSampler.swift` | Store (demand mailbox, publish), sampler (the only loop). |
| Modify `AgentSessions/Views/AgentCockpitHUDView.swift` | Demand reporting, visibility-gated rendering, toggle availability, doc comments. |
| Create `AgentSessionsTests/OpenCodeRecentUsageTests.swift` | Tasks 1–3 (with `OpenCodeVendorSchemaFixture`). |
| Create `AgentSessionsTests/OpenCodeSessionRateTests.swift` | Tasks 4–5. |
| Modify `AgentSessionsTests/OpenCodeHUDGroupTests.swift` | Task 6. |

**`OpenCodeVendorSchemaFixture`.** Checked-in **schema-only** DDL (`SELECT sql FROM sqlite_master WHERE type IN ('table','index')`) for `session`, `message`, `part`, `session_v2`, `session_message` as OpenCode 2.1.2 creates them. A comment records the version, capture date and SHA-256 of the DDL text. It contains no row data. `OpenCodeV2StoreTests.createV2Tables()` is not used: it lacks the `(session_id, time_created, id)` index.

---

### Task 1: Carry completion time end to end

**Files:** `SessionTelemetry.swift`, `OpenCodeV2MessageAdapter.swift`, `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentUsageTests.swift`.

**Interfaces — Produces:**
```swift
// TelemetryUsageEvent: stored `public let completedAt: Date?`, init param `completedAt: Date? = nil`,
// decodeIfPresent (absent → nil). No parserVersion bump. priced(...) passes it through
// (SessionTelemetry.swift:291-303). observedAt stays the request start (period pricing uses it,
// TelemetryCostCalculator.swift:215).
static func adapt(rowID: String, type: String, timeCreatedMillis: Int64,
                  timeUpdatedMillis: Int64, data: [String: Any]) -> Adapted   // OpenCodeV2MessageAdapter.swift:26
```
- `adaptedV2Row` (`OpenCodeSqliteReader.swift:1514-1519`) passes `row.timeUpdated` (`V2Row`, :1463-1469). `stepFinishPart` (:146-157) writes `"completedAt"`: `data.time.completed` for an assistant; for a completed compaction, `time.completed` ?? `timeUpdatedMillis`. The v1 part path reads `part.time.end` ?? the part row's `time_updated`. The private `OpenCodeTelemetryUsageRow` gains `completedAt`, and the `TelemetryUsageEvent` constructed at `OpenCodeSqliteReader.swift:513-528` sets it (lines :478-501 are token validation). Update every existing `adapt(` call site.
- **v1 `observedAt` check.** The current reader picks the part's `time_created` before the owning message's start (:264-275, :804-815). Confirm with a realistic v1 fixture, end-present and end-absent, that `observedAt` is the request start used for period pricing and burst spans. If it is not, use the owning message's `time_created` for the rate path only, and leave Session Info unchanged.
- [ ] **Step 1: Failing tests:** `testCompletedAtFromV2AssistantTime`, `testCompactionWithoutTimeCompletedUsesRowUpdate`, `testV1PartTimeEndThenRowUpdate`, `testV1ObservedAtIsRequestStart` (realistic v1 fixture, end present and absent), `testCompletedAtSurvivesPricing` (via `TelemetryCostCalculator.price(events:fallbackSlices:snapshot:…)`, :43-48), `testObservedAtStaysRequestStart`, `testDecodesEventWithoutCompletedAt`.
- [ ] **Step 2:** `xcodebuild … -only-testing:AgentSessionsTests/OpenCodeRecentUsageTests` → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** focused tests + `OpenCodeV2StoreTests` + `SessionTelemetryEngineTests` → PASS (full-load results unchanged).
- [ ] **Step 5:** prepare commit `feat(telemetry): carry OpenCode request completion time`; commit on owner approval.

### Task 2: Window eligibility and request classification

**Files:** `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentUsageTests.swift`.

**Interfaces — Produces (internal to the reader; used by Task 3):**
```swift
enum OpenCodeRecentWindow: Equatable, Sendable {
    case noCompletedUsage                 // empty, user-only, or in-flight only
    case usage([TelemetryUsageEvent])     // completed events with completedAt >= now − 30 min
    case unavailable                      // a completed in-window request has missing/invalid usage
}
/// Reads one session's window on an already-open connection inside the caller's transaction.
private static func recentWindow(db: OpaquePointer?, sessionID: String, now: Date) -> OpenCodeRecentWindow?
```
- Store via the existing `v2SessionExists` / `v2PreferredPredicate` (:1421-1435).
- v2: `SELECT … FROM session_message WHERE session_id = ? AND time_created >= ?`, ordered in memory by `seq`. Classify raw rows by the "Request classification" table before adaptation, then adapt the completed ones and reduce with the existing strict validation and fork boundary (:292-310).
- v1: select eligible message IDs with `message.time_created >= since`, then their parts only: `SELECT … FROM part WHERE message_id IN (<eligible>)`, or a `JOIN message` on the same bound. Never filter parts by their own `time_created`. Keep the existing ordering and attribution boundary.
- [ ] **Step 1: Failing tests** (vendor fixture):
  - `testInFlightOnlyWindowIsNoUsage`, `testUserOnlyWindowIsNoUsage`.
  - `testCompletedTokenlessCompactionIsUnavailable`, `testInFlightCompactionIgnored`, `testCompletedCompactionWithTokensIncluded`.
  - `testCompletedAssistantMissingTokensIsUnavailable`, `testMalformedComponentsAreUnavailable` (negative, fractional, overflow).
  - `testUndecodableV2AssistantIsUnavailable`, `testUndecodableV2CompactionIsUnavailable`, `testUndecodableV1PartIsUnavailable`, `testUndecodableV1MessageIsUnavailable`.
  - `testMalformedCompletionTimestampIsUnavailable` (string, negative, fractional, beyond `Int64`), for v2 `time.completed` and v1 `time.end`.
  - `testDecodedRowWithoutCompletionIsInFlight` — the only path to "in flight".
  - `testOldMalformedRowOutsideWindowIsIgnored` — `time_updated` 45 min ago, a valid burst now → `.usage`.
  - `testRecentMalformedRowPoisonsWindow` — `time_updated` 5 min ago → `.unavailable`.
  - `testV1PartOfOldMessageExcluded`, `testV1LongRequestStartedInsideCutoffIncluded`, `testRequestStartedOverTwoHoursAgoExcluded`.
  - `testStoreSelectionMatchesFullLoad` (v1-only, equal-time migrated copy, newer v2 continuation), `testForkClonedRowsExcluded`.
  - `testWindowParityWithFullLoad` — on a fixture of **complete, valid rows only**, the normalized tuples `(recordID, model, fresh, cacheRead, cacheWrite5m, output, reasoning, completedAt)` match `loadTelemetry(for:)` filtered by the same start timestamp. `anchorLine` is excluded; `testAnchorLinesAreDenseInWindow` covers it. (On malformed data the full load fails the whole session closed while the window fails only itself; that difference is intended.)
- [ ] **Step 2–4:** FAIL → implement → PASS (+ `OpenCodeV2StoreTests`, `SessionTelemetryEngineTests`).
- [ ] **Step 5:** prepare commit `feat(opencode): classify in-window OpenCode requests`; commit on owner approval.

### Task 3: Batch read in one transaction

**Files:** `OpenCodeSqliteReader.swift`; tests in `OpenCodeRecentUsageTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeRecentUsageRequest: Sendable { let sessionID: String; let previousTail: String?; let forceReload: Bool }
enum OpenCodeRecentUsageResult: Equatable, Sendable {
    case unchanged(tail: String)
    case loaded(tail: String, window: OpenCodeRecentWindow)
    case unreadable
}
extension OpenCodeSqliteReader {
    /// One connection, one BEGIN…ROLLBACK for all requests. nil = the store could not be opened.
    static func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest], now: Date) -> [String: OpenCodeRecentUsageResult]?
    #if DEBUG
    nonisolated(unsafe) static var databaseOpenCountForTesting = 0
    #endif
}
```
- Tail token: v2 newest `(seq, time_updated)` by the `(session_id, seq)` unique index plus `session_v2.time_updated`; v1 newest `message (time_created, id, time_updated)`. Unchanged tail with no `forceReload` → `.unchanged`; else `.loaded(tail, recentWindow(...))`.
- [ ] **Step 1: Failing tests:** `testOneDatabaseOpenPerCall` (8 sessions → +1), `testUnchangedTailSkipsRead`, `testForceReloadRereads`, `testInPlaceEditCaughtByForceReload`, `testQueryPlansUseIndexes` (v2 window uses `(session_id, time_created, id)` with no `SCAN session_message`; tail uses `(session_id, seq)`; v1 message bound uses `(session_id, time_created, id)` and parts use `(message_id, id)`), `testConsistentUnderConcurrentWALWriter`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** prepare commit `feat(opencode): batch windowed usage read`; commit on owner approval.

### Task 4: Burst first, then price exactly the burst

**Files:** Create `OpenCodeSessionRate.swift`; tests in `OpenCodeSessionRateTests.swift`.

**Interfaces — Produces:**
```swift
enum OpenCodePricing: Equatable, Sendable {
    case priced(dollarsPerHour: Double)
    case allFreeRoute
    case unpriced(unknownModels: [String], missingComponents: [String])   // from the burst's TelemetryCostEstimate
}
struct OpenCodeSessionActivity: Equatable, Sendable {
    let tokensPerHour: Double
    let pricing: OpenCodePricing
    let newestCompletion: Date
}
enum OpenCodeRateValue: Equatable, Sendable {
    case rate(Double, RunwayRateUnit)
    case free
    case unpriced(unknownModels: [String], missingComponents: [String])
    case unavailable, working, idle
}
enum OpenCodeSessionRate {
    static let burstGap: TimeInterval = 30 * 60, minimumSpan: TimeInterval = 60
    static let freshness: TimeInterval = 5 * 60, cacheReadWeight = 0.10
    static func burst(_ events: [TelemetryUsageEvent]) -> [TelemetryUsageEvent]?
    static func activity(burst: [TelemetryUsageEvent], prices: RunwayPriceSnapshot) -> OpenCodeSessionActivity
    static func unit(for presentation: RunwayPresentation) -> RunwayRateUnit   // .dollar → .dollarsPerHour else .tokensPerHour
    static func value(window: OpenCodeRecentWindow?, activity: OpenCodeSessionActivity?,
                      isWorking: Bool, unit: RunwayRateUnit, now: Date) -> OpenCodeRateValue
}
```
- `burst`: events with `topLineTokens > 0`, sorted by `completedAt`; walk back while the gap rule holds; span must be ≥ `minimumSpan`.
- `activity`: `TelemetryCostCalculator.price(events: burst, fallbackSlices: [], snapshot: prices)` on the **burst only**.
  - `.unpriced(estimate.unpricedModels, estimate.missingPriceComponents)` when either list is non-empty or any priced event has `apiEquivalentUSD == nil`. Both lists are kept as returned (deduplicated, sorted). Both may be empty when only a nil event USD triggered it; the view then shows the generic reason.
  - `.allFreeRoute` when every burst event's model is in `estimate.freeRouteModels`.
  - Otherwise `.priced(sum USD ÷ span × 3600)`.
- `value`: idle → `.idle`; window `.unavailable` → `.unavailable`; no activity or stale → `.working`; $ unit maps the pricing outcome to `.free`, `.unpriced` or `.rate`; tk unit → `.rate(tokensPerHour, .tokensPerHour)`.
- [ ] **Step 1: Failing tests:** `testBurstSpanAndWeight` (24 000 weighted over 120 s → 720 000 tk/h), `testGapStartsNewBurst`, `testShortSpanHasNoBurst`, `testOldUnpricedOutsideBurstDoesNotHideRate`, `testMixedFreeAndPaidIsNotFree`, `testAllFreeIsFree`, `testUnknownModelReasonIsKept` (exact `unknownModels`), `testMissingWriteRateReasonIsKept` (exact `missingComponents`, e.g. `"<model>:cacheWrite"`), `testMixedReasonsBothKept` (one unknown model and one missing component in the same burst → both lists non-empty), `testNilUSDWithNoReasonsIsUnpricedWithEmptyLists`, `testPeriodBoundaryPricesEachEventAtItsDate`, `testLongContextEventPricedAtItsTier`, `testDollarsMatchSessionInfoForSameEvents`, `testFreshnessAtValueTime`, `testIdleWins`, `testUnavailableWins`, `testLensMapping`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** prepare commit `feat(opencode): per-session tk/h and $/h from the newest burst`; commit on owner approval.

### Task 5: One shared sampler with an ordered demand mailbox

**Files:** Create `OpenCodeRateSampler.swift`; tests in `OpenCodeSessionRateTests.swift`.

**Interfaces — Produces:**
```swift
struct OpenCodeRateDemand: Equatable, Sendable { let sessions: [String: Bool] }   // sessionID → isWorking
struct OpenCodeRateSnapshot: Equatable, Sendable {
    let databasePath: String?; let presentation: RunwayPresentation
    let demandRevision: UInt64; let version: UInt64
    let values: [String: OpenCodeRateValue]
    static let empty: OpenCodeRateSnapshot
}
@MainActor @Observable final class OpenCodeRateStore {
    static let shared: OpenCodeRateStore
    private(set) var snapshot: OpenCodeRateSnapshot
    /// nil = this surface shows no OpenCode rates. Bumps `demandRevision` and yields the new
    /// union to the sampler's mailbox in call order.
    func setDemand(_ surface: UUID, _ demand: OpenCodeRateDemand?)
    /// Sampler-only. Accepts the snapshot only if its demandRevision == the current revision
    /// and its version is newer than the published one.
    func publish(_ snapshot: OpenCodeRateSnapshot)
    /// Live demand state for the sampler's post-read checks (read on the main actor).
    var currentDemandRevision: UInt64 { get }
}
protocol OpenCodeRecentUsageReading: Sendable {
    func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest], now: Date) -> [String: OpenCodeRecentUsageResult]?
}
actor OpenCodeRateSampler {
    init(store: OpenCodeRateStore, reader: OpenCodeRecentUsageReading,
         clock: @escaping @Sendable () -> Date, databaseURL: @escaping @Sendable () -> URL?,
         presentation: @escaping @Sendable () -> RunwayPresentation, prices: @escaping @Sendable () -> RunwayPriceSnapshot)
    /// Consumes `(revision, union)` updates from one AsyncStream in order. The store creates the
    /// stream; the sampler is its only consumer.
    func run(updates: AsyncStream<(UInt64, OpenCodeRateDemand?)>) async
}
```
- **Ordering:** the store owns the only `demandRevision` counter and one `AsyncStream` continuation. Every `setDemand` yields `(revision, union)` synchronously on the main actor, so the sampler sees updates in call order. A newer hide can never be overtaken by an older show.
- **Union:** all distinct session IDs across surfaces, `isWorking` = OR. No cap (see Fixed values for the practical bound).
- **One read at a time:** the loop is `await read; process; sleep`. A demand update during a read is applied **after** that read returns, and the stale result is then dropped. There are never two reads in flight. The GCD read in `withCheckedContinuation` (pattern `CodexRunwayModel.swift:606-608`) may finish after demand changes; its result is checked before use.
- **Validity check after each read:** the sampler records the store's revision and the DB path when the read starts. After the read it reads the **live** `await store.currentDemandRevision` (main actor) and the current DB path. It does **not** use the last revision it took from its mailbox, because newer updates may still be queued while a read is suspended. If either value changed, the result is discarded **without** touching the cache. Otherwise the cache is updated, a snapshot is built with the current clock, and `store.publish` makes the final check on the main actor.
- **Single-flight invariant:** one actor-owned refresh task is the only code that calls the reader. The mailbox consumer only records demand and wakes that task. It never starts a read itself.
- **Stop:** a nil union stops the loop after the in-flight read (if any) returns; no further reads.
- **Path change:** clear the cache; publish an `.empty` snapshot carrying the new path.
- **Demand source:** each `HUDLimitsRowsPanel` (3858) reports under its own UUID, the same per-surface pattern as `QuotaMeterPollingRegistry` (690-716). It reports non-nil only when the OpenCode group is shown, rate visibility is not `.alwaysOff`, and (for the strip) the strip is expanded. Add `@Environment(\.quotaStripExpanded) private var stripExpanded` to `HUDLimitsRowsPanel`; it is declared today only in other views (precedent :4814). Report on appear and on change; nil on disappear.
- [ ] **Step 1: Failing tests** (fake reader with a gate to block reads, fake clock):
  - `testNoDemandNoIO`, `testDemandStartsAndNilStops`.
  - `testDisjointSurfacesAllSampled` (two surfaces × 4 sessions → one read with 8 requests).
  - `testUpdatesAppliedInCallOrder` (show, hide, show in quick succession → final state shown, one loop).
  - `testHideShowDuringBlockedRead` (no publish from the stale read, no overlapping read).
  - `testCollapseExpandDuringBlockedRead`.
  - `testPathChangeDuringBlockedReadDiscardsResult`.
  - `testStorePublishRejectsStaleRevisionOrVersion`.
  - `testStaleResultNeverEntersCache` — a blocked read, demand changes, the read returns; then the next cycle with an unchanged tail must re-read, not reuse the stale result. Assert on cache contents, not only on publish.
  - `testLiveRevisionCheckedNotMailboxRevision` — a demand update queued but not yet consumed when the read returns → the result is discarded.
  - `testOnlyRefreshTaskCallsReader` — mailbox bursts during a blocked read cause no extra reader calls.
  - `testCachedActivityExpiresAtFreshness`, `testPeriodicForceReloadAfterSixtySeconds`, `testUnreadableStoreGivesWorking`.
- [ ] **Step 2: Benchmark** `testCycleWithinBudgetOnLargeStore`: real SQLite, vendor fixture, 50 000 `session_message` rows over 200 sessions with an active 2-hour tail, WAL writer, **8** sessions × 30 cycles, warm and changed-tail. p95 ≤ 25 ms, exactly 1 DB open per cycle. Runs with `AGENT_SESSIONS_PERF=1`; required in Task 7.
- [ ] **Step 3–4:** FAIL → implement → PASS.
- [ ] **Step 5:** prepare commit `feat(opencode): shared demand-driven rate sampler`; commit on owner approval.

### Task 6: Quota Meter rendering

**Files:** `AgentCockpitHUDView.swift` (`HUDOpenCodeSessionsGroup` 4732, `HUDLimitsRowsPanel` 3858 / body 4188, `runwayControlAvailable` 1336, doc comments 233-245 and 4729-4731); localization files; tests in `OpenCodeHUDGroupTests.swift`.

**Interfaces:** Consumes `OpenCodeRateStore.shared.snapshot`. Produces:
- `static func OpenCodeHUDGroup.sessionID(for row: HUDRow) -> String?` = `row.resolvedSessionID ?? row.runtimeSessionID`.
- `static func OpenCodeHUDGroup.controlAvailable(providersShown: Bool, openCodeGroupVisible: Bool) -> Bool`.
- `static func OpenCodeHUDGroup.showsRates(visibility: QuotaMeterRunwayVisibility, isStrip: Bool, stripExpanded: Bool) -> Bool`.

**Behavior:**
- **The rate cell is gated in the view itself.** When `showsRates(...)` is false (visibility `.alwaysOff`, from `runwayVisibilityRaw` already observed at :3970, or a collapsed strip), the row shows the existing working/idle label regardless of the snapshot. It also ignores a snapshot whose `presentation` differs from the current one.
- **Values:**
  - `.rate(v, unit)` → `RunwayTimeFormatting.rate(v, unit:, confidence: .direct)` (:5161); `hudProjectionColor` when `v > 0`, else secondary.
  - `.free` → `"Free"`.
  - `.unpriced(unknownModels, missingComponents)` → "—" with one help text built from every non-empty part, joined by a newline:
    - `"No API price for %@"` with the model list, when `unknownModels` is non-empty;
    - `"Missing API price component: %@"` with the component list, when `missingComponents` is non-empty;
    - `"No API price for this session's recent usage."` when both are empty.

    The rule lives in `static func OpenCodeHUDGroup.unpricedHelp(unknownModels:missingComponents:) -> String`, a pure function that is tested directly.
  - `.unavailable` → "—" + `.help("Usage data for this session is incomplete.")`.
  - `.working` / `.idle` / missing → `stateLabel`.
  - Width `HUDRunwayLayout.rateWidth(for:)`.
- **Toggle:** the OpenCode group is built inside `HUDLimitsRowsPanel.body` (:4188-4197), so its local `openCodeGroup` is out of scope at `runwayControlAvailable` (:1336). The parent recomputes visibility from its own inputs instead: `OpenCodeHUDGroup.make(rows: displayState.rowsForDisplay, detectionEnabled: <same flag passed to the panel at :1135-1140>, openCodeEnabled: <same>) != nil`, or a shared computed property both use. `runwayControlAvailable = controlAvailable(providersShown: <existing expression>, openCodeGroupVisible: that)`.
- **Test seam:** `HUDLimitsRowsPanelTestHost` (:4712-4727) today accepts only `activeRows` / `detectionEnabled`. Extend it with an injected `OpenCodeRateStore` (or snapshot), `runwayVisibility`, `isStrip` and `stripExpanded`, so the mounted tests can drive those inputs.

- [ ] **Step 1: Failing tests:** `testRowShowsOwnSessionRate`, `testParentAndChildRowsShowTheirOwnRates`, `testAlwaysOffHidesExistingRate` (mounted via `HUDLimitsRowsPanelTestHost` (4713) with a populated injected snapshot; switching visibility to `.alwaysOff` reverts to "working"), `testCollapsedStripHidesExistingRate`, `testSnapshotForOtherPresentationIgnored`, `testPositiveRateUsesProjectionColorEvenWhenQuiet`, `testUnpricedHelpModelOnly`, `testUnpricedHelpComponentOnly`, `testUnpricedHelpMixedShowsBoth`, `testUnpricedHelpGenericWhenEmpty`, `testToolbarControlUsesParentComputedGroupVisibility`, `testMountedStripReportsDemandOnlyWhenExpanded`, `testAlwaysOffReportsNoDemand`, `testControlAvailableForOpenCodeOnly`, `testNewStringsHaveChineseTranslations` (all four help keys: unknown model, missing component, generic unpriced, incomplete usage).
- [ ] **Step 2–4:** FAIL → implement (catalog + validator count/digest; run the validator and its unittest) → PASS.
- [ ] **Step 5:** prepare commit `feat(opencode): show per-session rates in the Quota Meter`; commit on owner approval.

### Task 7: Docs and required verification

- [ ] **Step 1:** CHANGELOG `[Unreleased]` entry: OpenCode sessions in the Quota Meter show tk/h, or $/h in the $ lens; free routes read Free; no quota until Go data exists. Add the matching line in the monthly summary for the month the change lands: `docs/summaries/2026-10.md` if it lands in October, otherwise create `docs/summaries/2026-11.md` following that file's format. Lint with `python3 tools/release/sparkle_release_notes.py --version 6.2 --changelog <copy, [Unreleased]→[6.2]> --lint --out-text <scratch>`.
- [ ] **Step 2:** `./scripts/xcode_test_stable.sh` → TEST SUCCEEDED. Set the baseline to the **passed** count from the result bundle.
- [ ] **Step 3 (required):** `AGENT_SESSIONS_PERF=1 xcodebuild … -only-testing:AgentSessionsTests/OpenCodeSessionRateTests/testCycleWithinBudgetOnLargeStore` → PASS. Record p95 and DB opens per cycle.
- [ ] **Step 4:** Owner manual check, real OpenCode 2.x TUI:
  - A rate appears after 60 s of completed requests; "working" before that.
  - The $ lens shows $/h or Free.
  - A long request keeps its rate for up to 5 min.
  - Always Off and a collapsed strip both hide rates at once.
  - DB reads stop only when **no** surface shows OpenCode rates: Always Off, or the strip collapsed with the window closed. With the window open and the strip collapsed, sampling continues. Check that Agent Sessions' own reads stop with `sudo fs_usage -w -f filesys AgentSessions | grep opencode.db` for 30 s; OpenCode's own writes are not counted.
  - CPU stays calm with the Quota Meter open for 5 min.
- [ ] **Step 5:** prepare commit `docs: record OpenCode session rates`; commit on owner approval.

---

## Findings addressed (rev 3 review)

| # | Rev-3 item | Fix in rev 4 |
|---|---|---|
| B1 | Completed tokenless compaction disappears | Raw-row classification before adaptation; completed + missing/invalid usage → unavailable (Request classification table; Task 2 tests). |
| B2 | Global cap of 4 starves another surface | No cap: every visible session sampled; perf gate at 8 sessions (Task 5). |
| B3 | Always Off leaves the last rate on screen | `showsRates` gates the rate cell in the view; mounted transition tests (Task 6). |
| B4 | v1 parts windowed by their own time | Parts selected by eligible owning message only (Task 2); query-plan test (Task 3). |
| B5 | Unpriced reasons lost | `OpenCodePricing.unpriced(unknownModels, missingComponents)` through to the value and distinct tooltips (Tasks 4, 6). |
| B6 | Demand/cancel ordering undefined | Store-owned revision + single `AsyncStream` mailbox in call order; one read at a time; revision and path rechecked before cache and publish; `store.publish` with revision/version guard (Task 5). |
| I1 | Row update time not threaded | `adapt(... timeUpdatedMillis:)` from `V2Row.timeUpdated`; v1 `time.end` ?? part `time_updated`; `observedAt` stays the start (Task 1). |
| I2 | Unconditional commit steps | Every Step 5 prepares the commit and commits on owner approval; Global Constraints. |
| I3 | Parity semantics; Task 2 size | Parity on complete, valid rows with the intended difference stated; old Task 2 split into Task 2 (eligibility and classification) and Task 3 (batch, tail, WAL, query plans). `@Environment(\.quotaStripExpanded)` is added to `HUDLimitsRowsPanel` explicitly. |

## Findings addressed (rev 4 review)

| # | Rev-4 item | Fix in rev 5 |
|---|---|---|
| Blocker 1 | Undecodable rows / malformed completion read as in-flight | Classification rows for decode and timestamp failures (fail closed via existing `malformedPayload`); only decoded rows without a completion marker are in flight; window attribution by `time_updated`; strict timestamp parsing; Task 2 tests. |
| Blocker 2 | Mixed unpriced reasons lose one class in the view | Both lists kept; `unpricedHelp` joins every non-empty part, with a generic fallback; four help strings; mixed/empty tests (Tasks 4, 6). |
| B6 note | Post-read check must use live store revision | `currentDemandRevision` read on the main actor after each read; stale results never cached; single-flight invariant; three tests (Task 5). |
| C1 | `openCodeGroup` out of scope for the toolbar; test host lacks injection | Parent recomputes group visibility via `OpenCodeHUDGroup.make`; test host extended (Task 6). |
| C2 | Event construction line | `:513-528`; v1 `observedAt` verified with a realistic fixture (Task 1). |
| C3 | Manual "collapse stops reads" ignores the other surface | Reads stop only when no surface demands; `fs_usage` filtered to Agent Sessions (Task 7). |
| C4 | Summary path placeholder | `docs/summaries/2026-10.md`, or a new `2026-11.md` if it lands then (Task 7). |
| C5 | Task 5 size | Kept as one task, implemented in the order mailbox/revision → single-flight read lifecycle → cache → benchmark, each with its blocked-read tests passing before the next. |
