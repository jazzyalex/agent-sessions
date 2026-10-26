# OpenCode Session Rates in the Quota Meter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each running OpenCode 2.x session row in the Quota Meter shows its own token rate (tk/h), or its API-equivalent cost rate ($/h) when the $ lens is selected, without any OpenCode subscription data.

**Architecture:** A read-only SQLite reader pulls the recent assistant requests of each running OpenCode session (and its child sessions) from `opencode.db`. A pure function turns those requests into a `RunwaySessionActivity` using the same burst rule and token weighting as Claude's tk/h. A small display model maps activity + the global `RunwayPresentation` to row text. `HUDLimitsRowsPanel` refreshes these rates every 5 s off the main thread and passes them to the existing OpenCode group. Rows join by OpenCode session ID; nothing goes through the Codex/Claude runway request, baseline or `UsageTrackingSource`.

**Tech Stack:** Swift 5 / SwiftUI, SQLite3 C API (read-only), XCTest.

**Spec:** This plan is the spec. Owner decisions from the 2026-10-26 session:
- No weekly (Wk) or 5h quota for OpenCode until OpenCode Go subscription data exists. Only tk/h and $/h.
- OpenCode 2.x only. 1.x sessions have no live presence, so they get no rate.
- Desktop sessions get a rate only while working (the service reports them; idle Desktop selection is not exposed).
- Target release: 6.2.

## Global Constraints

- Deployment target: macOS 14.0 (unchanged).
- `UsageTrackingSource` stays `.codex` / `.claude`. Do not add `.opencode`: several exhaustive switches depend on it (`CodexRunwayModel.swift:1411`, `UsageStaleCheck.swift:77`, `UsageFreshness.swift:52`, `UsageDisplayFormatter.swift:478,498`).
- `RunwayPresentation` keeps exactly four cases (`testRunwayPresentationDefaultsToFiveHour` asserts `allCases.count == 4`).
- SQLite access is read-only: `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)`, the pattern at `OpenCodeSqliteReader.swift:187-193`. Never write to `opencode.db`; never hold a transaction open between refreshes.
- No network calls. No new background timers outside the visible Quota Meter.
- New Swift files are added with `scripts/xcode_add_file.rb` (agents.md, "Adding New Swift Files"). A correct run adds exactly 4 `project.pbxproj` lines per file.
- Every new user-facing string goes into `AgentSessions/Resources/Localizable.xcstrings` (en + zh-Hans) and the key count/digest in `scripts/validate_localization_catalogs.py` and `scripts/tests/test_validate_localization_catalogs.py` is updated, or release QA's localization gate fails. Reuse the existing `"Free"` key.
- Commits: Conventional Commits with `Tool:` / `Model:` / `Why:` trailers, `git commit -- <paths>` only.
- Tests run through `./scripts/xcode_test_stable.sh` (full) or `xcodebuild ... -only-testing:` (focused). Test counts are invariants; record the new total.

## Fixed values

| Name | Value | Why |
|---|---|---|
| Lookback for the SQL read | 30 min | Matches the Claude/Codex burst gap; bounds the query. |
| Burst gap | 30 min | Same as Claude (`ClaudeRunwayTokenActivityParser` burst walk). |
| Minimum burst span | 60 s | A single short request with a large cached prompt would read as millions of tk/h. Claude solves this with a provisional clamp; OpenCode shows "working" until a minute of evidence exists. |
| Rate freshness while working | 5 min after the newest completed request | One OpenCode request can run for minutes with no new row; keep the last burst rate visible during it, then fall back to "working". |
| Token weight | fresh input + output + reasoning + cache write + 0.10 × cache read | Same scale as Claude's tk/h (`ClaudeRunwayTokenActivityParser.weightedTokens`, cacheReadWeight 0.10). |
| Refresh cadence | 5 s | Same as `runRunwayRefreshLoop`. |
| Max sessions read per refresh | `OpenCodeHUDGroup.maxVisibleSessions` (4) | Only visible rows get a rate. |

## Review Focus

1. **A single long request.** OpenCode writes the assistant row's tokens only when the request completes; a 4-minute request shows no new data. Expect: the previous burst rate stays for up to 5 min, then the row reads "working", never "0 tk/h". (Task 2 test `testRateStaysDuringLongRequestThenFallsBackToWorking`.)
2. **Compaction rows.** `session_message` rows with `type='compaction'` carry large token counts that are not interactive burn. Expect: excluded from the rate. (Task 1 test `testCompactionRowsAreExcluded`.)
3. **Subagent child sessions.** OpenCode task tools run in child sessions (`session_v2.parent_id`); the TUI shows the parent. Expect: child requests in the window count toward the parent's rate. (Task 1 test `testChildSessionRequestsFoldIntoParent`.)
4. **A store without `session_v2` / locked or missing DB.** OpenCode 1.x stores or a mid-migration DB. Expect: the reader returns nil, the row keeps its working/idle label, no crash, no log spam. (Task 1 test `testMissingV2TablesReturnsNil`.)
5. **In-flight rows.** An assistant row exists before completion with no `data.time.completed` or no `data.tokens`. Expect: skipped, not counted as zero tokens. (Task 1 test `testInFlightRowsAreSkipped`.)

---

## File Structure

| File | Responsibility |
|---|---|
| Create `AgentSessions/OpenCode/OpenCodeRunwayRequestReader.swift` | Read-only SQL: recent completed assistant requests for a session and its children. IO only. |
| Create `AgentSessions/OpenCode/OpenCodeSessionRate.swift` | Pure: requests → `RunwaySessionActivity`; activity + presentation + prices → row display. |
| Modify `AgentSessions/Views/AgentCockpitHUDView.swift` | Group model carries rates; row view renders them; panel refresh loop; toggle availability. |
| Create `AgentSessionsTests/OpenCodeSessionRateTests.swift` | Reader (SQLite fixture) and pure-rate tests. |
| Modify `AgentSessionsTests/OpenCodeHUDGroupTests.swift` | Group model + mounted panel with rates. |
| Modify `AgentSessions/Resources/Localizable.xcstrings`, `scripts/validate_localization_catalogs.py`, `scripts/tests/test_validate_localization_catalogs.py` | New strings. |
| Modify `docs/CHANGELOG.md` | Unreleased entry. |

---

### Task 1: Read recent OpenCode requests from SQLite

**Files:**
- Create: `AgentSessions/OpenCode/OpenCodeRunwayRequestReader.swift`
- Test: `AgentSessionsTests/OpenCodeSessionRateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct OpenCodeRunwayRequest: Equatable, Sendable {
      let sessionID: String
      let startedAt: Date        // session_message.time_created
      let completedAt: Date      // data.time.completed (epoch ms)
      let model: String?         // data.model.id
      let freshInput: Int        // data.tokens.input
      let output: Int            // data.tokens.output + data.tokens.reasoning
      let cacheRead: Int         // data.tokens.cache.read
      let cacheWrite: Int        // data.tokens.cache.write
  }
  enum OpenCodeRunwayRequestReader {
      static let lookback: TimeInterval = 30 * 60
      /// nil when the store cannot be read as OpenCode 2.x (no `session_v2` /
      /// `session_message`, open failure, busy). Empty array = readable, no requests.
      static func requests(databaseURL: URL, rootSessionID: String, now: Date) -> [OpenCodeRunwayRequest]?
      /// Cheap change check: `session_v2.time_updated` of the root and its direct children, max.
      static func latestUpdate(databaseURL: URL, rootSessionID: String) -> Date?
  }
  ```

- [ ] **Step 1: Write the failing tests** in `OpenCodeSessionRateTests` with a temp-file fixture (`session_v2` with `id`, `parent_id`, `time_updated`; `session_message` with `id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data`, plus the `(session_id, seq)` unique index and `(session_id, time_created, id)` index, copied from `OpenCodeV2StoreTests.createV2Tables()`):
  - `testReadsCompletedAssistantRequestsInsideLookback` — 3 assistant rows at now−40 min, now−10 min, now−2 min → returns the 2 inside 30 min, with token fields mapped as in the struct comments (`output` includes `reasoning`).
  - `testCompactionRowsAreExcluded` — a `type='compaction'` row with tokens inside the window → not returned.
  - `testChildSessionRequestsFoldIntoParent` — child session (`parent_id` = root) with one row → returned with its own `sessionID`.
  - `testInFlightRowsAreSkipped` — assistant rows lacking `data.time.completed` or `data.tokens` → skipped.
  - `testMissingV2TablesReturnsNil` — DB with only v1 `session`/`message` tables → `nil`; nonexistent path → `nil`.
  - `testLatestUpdateIsMaxOfRootAndChildren`.

- [ ] **Step 2: Run** `xcodebuild ... -only-testing:AgentSessionsTests/OpenCodeSessionRateTests` — expect FAIL (type not defined).

- [ ] **Step 3: Implement** `OpenCodeRunwayRequestReader` in the new file (add it with `scripts/xcode_add_file.rb`). Query shape (index seek on `(session_id, time_created, id)`):
  ```sql
  SELECT session_id, time_created, data FROM session_message
  WHERE (session_id = ?1 OR session_id IN (SELECT id FROM session_v2 WHERE parent_id = ?1))
    AND type = 'assistant' AND time_created >= ?2
  ```
  Parse `data` with `JSONSerialization`; skip a row when `time.completed` or `tokens` is missing. `time_created` is epoch ms (match `OpenCodeSqliteReader.queryTelemetryV2`). Direct children only (one level), as `HUDRunwayIdentityReducer` folds one parent level.

- [ ] **Step 4: Run** the focused tests — expect PASS.

- [ ] **Step 5: Commit** `feat(opencode): read recent session requests for Quota Meter rates`.

---

### Task 2: Turn requests into a session rate and row text

**Files:**
- Create: `AgentSessions/OpenCode/OpenCodeSessionRate.swift`
- Test: `AgentSessionsTests/OpenCodeSessionRateTests.swift`

**Interfaces:**
- Consumes: `OpenCodeRunwayRequest` (Task 1); `RunwaySessionActivity`, `RunwayModelComponent`, `RunwaySessionIdentity` (`CodexRunwayModel.swift:233,291,336`); `RunwayPresentation` (`UsageDisplayMode.swift:369`); `RunwayPriceSnapshot.resolvedPrice(forModel:)` (`RunwayPriceTable.swift:258`), `RunwayModelPrice.effective(at:)`, `rates(for: .standardNormalized, contextInputTokens:inferenceGeo:)`; `RunwayTimeFormatting.rate(_:unit:confidence:)` (`AgentCockpitHUDView.swift:5164`).
- Produces:
  ```swift
  enum OpenCodeSessionRate {
      static let burstGap: TimeInterval = 30 * 60
      static let minimumSpan: TimeInterval = 60
      static let freshness: TimeInterval = 5 * 60
      static let cacheReadWeight = 0.10
      /// nil = not enough evidence (no requests, span < 60 s, or newest completion older than `freshness`).
      static func activity(identity: RunwaySessionIdentity, requests: [OpenCodeRunwayRequest], now: Date) -> RunwaySessionActivity?
      static func unit(for presentation: RunwayPresentation) -> RunwayRateUnit   // .dollar → .dollarsPerHour, else .tokensPerHour
      static func display(activity: RunwaySessionActivity?, isWorking: Bool, unit: RunwayRateUnit,
                          prices: RunwayPriceSnapshot, now: Date) -> OpenCodeRateDisplay
  }
  enum OpenCodeRateDisplay: Equatable, Sendable {
      case rate(String)          // formatted by RunwayTimeFormatting.rate(..., confidence: .direct)
      case free                  // every priced component resolved via a free route
      case unpriced(model: String?)  // $ lens, at least one component has no price
      case working               // no measurable rate yet
      case idle
  }
  ```

- [ ] **Step 1: Write the failing tests:**
  - `testBurstRateUsesClaudeTokenWeight` — two requests in one burst, span 120 s, tokens chosen so the weighted sum is 24 000 → `tokensPerSecond == 200`.
  - `testGapOverThirtyMinutesStartsANewBurst` — only the newest burst counts.
  - `testSpanUnderOneMinuteHasNoRate` — single 20 s request → `nil`.
  - `testRateStaysDuringLongRequestThenFallsBackToWorking` — newest completion at now−4 min → activity non-nil; at now−6 min → `display(... isWorking: true ...) == .working`.
  - `testIdlePresenceShowsIdle` — `isWorking: false` → `.idle` regardless of activity.
  - `testTokenLensFormatsTokensPerHour` — `.token` and `.fiveHour` and `.weekly` presentations all give `.tokensPerHour`; text equals `RunwayTimeFormatting.rate(200 * 3600, unit: .tokensPerHour, confidence: .direct)`.
  - `testDollarLensPricesEachModel` — two models in one burst, `RunwayPriceTable.makeForTesting().snapshot()` → `.rate("$…/h")` equal to the per-component sum computed from the test table's published rates.
  - `testFreeRouteReadsFree` — model `deepseek-v4.1-flash-free` (resolves via free route) → `.free`.
  - `testUnknownModelIsUnpricedNotZero` — `.unpriced(model: "made-up-model")`, never `$0/h`.

- [ ] **Step 2: Run** focused tests — FAIL.

- [ ] **Step 3: Implement** `OpenCodeSessionRate` (add file via `scripts/xcode_add_file.rb`). Burst: sort by `completedAt`; walk back from the newest while `next.startedAt − previous.completedAt <= burstGap`; `span = newest.completedAt − burstFirst.startedAt`. One `RunwayModelComponent` per model: each token field summed over the burst ÷ span, `speed: .standardNormalized`, `cacheCreation1hPerSecond: 0`, `contextInputTokens` = the newest request's `freshInput + cacheRead + cacheWrite` (long-context tier selection). `tokensPerSecond` = weighted sum ÷ span. Dollar: price every component via `resolvedPrice(forModel:)` + `effective(at: now)`; any nil → `.unpriced`; all `viaFreeRoute` → `.free`; otherwise sum `perSecond * 3600`.

- [ ] **Step 4: Run** focused tests — PASS.

- [ ] **Step 5: Commit** `feat(opencode): compute per-session tk/h and $/h from recent requests`.

---

### Task 3: Show rates in the Quota Meter OpenCode group

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` — `OpenCodeHUDGroupModel` (246-253), `OpenCodeHUDGroup.make` (262), `HUDOpenCodeSessionsGroup` (4732), `HUDLimitsRowsPanel` (~3858, body ~4166, loops ~4269/4481), `runwayControlAvailable` (1336); doc comments at 233-245 and 4729-4731.
- Modify: `AgentSessions/Resources/Localizable.xcstrings`, `scripts/validate_localization_catalogs.py`, `scripts/tests/test_validate_localization_catalogs.py`.
- Test: `AgentSessionsTests/OpenCodeHUDGroupTests.swift`

**Interfaces:**
- Consumes: Task 1 reader, Task 2 `OpenCodeSessionRate` / `OpenCodeRateDisplay`; `OpenCodeBackendDetector.dbURL(customRoot:)` with `PreferencesKey.Paths.opencodeSessionsRootOverride`; `PreferencesKey.quotaMeterRunwayPresentation`; `QuotaMeterRunwayVisibility`.
- Produces:
  ```swift
  // OpenCodeHUDGroupModel gains:
  let rates: [String: OpenCodeRateDisplay]   // key: OpenCodeHUDGroup.rateKey(for:)
  extension OpenCodeHUDGroup {
      static func rateKey(for row: HUDRow) -> String?   // row.resolvedSessionID ?? row.runtimeSessionID; nil → no rate
      static func make(rows:detectionEnabled:openCodeEnabled:rates:) -> OpenCodeHUDGroupModel?  // rates defaults to [:]
  }
  /// Off-main loader; caches activity per root session keyed by `latestUpdate`.
  actor OpenCodeRateLoader {
      static let shared: OpenCodeRateLoader
      func displays(for rows: [HUDRow], presentation: RunwayPresentation,
                    databaseURL: URL?, now: Date) async -> [String: OpenCodeRateDisplay]
  }
  ```

- [ ] **Step 1: Write the failing tests:**
  - `testGroupCarriesRatesBySessionID` — `make(... rates: ["ses_a": .rate("412K tk/h")])` with a row whose `resolvedSessionID == "ses_a"` → `model.rates["ses_a"]`.
  - `testRowWithoutSessionIDGetsNoRate` — `rateKey(for:)` is nil when both IDs are nil.
  - `testMountedRowShowsRateTextInsteadOfStateLabel` — mount via `HUDLimitsRowsPanelTestHost` (DEBUG, `AgentCockpitHUDView.swift:4713`), extended to accept `openCodeRates`; the row text contains "412K tk/h" and not "working".
  - `testRunwayControlAvailableForOpenCodeOnly` — Codex/Claude usage off, OpenCode group non-nil → toolbar presentation control is available (expose the predicate as a `static func` for the test).
  - `testAlwaysOffVisibilityShowsLabelsOnly` — `QuotaMeterRunwayVisibility.alwaysOff` → no loader call, rows show working/idle.

- [ ] **Step 2: Run** focused tests — FAIL.

- [ ] **Step 3: Implement.**
  - Row view: right column shows `.rate(text)` in `hudProjectionColor` when the rate is above zero (match `HUDRunwayPanel.rateCell`, 4909-4924), `.free` → existing `"Free"` key, `.unpriced` → "—" with `.help("No API price for \(model)")` (new string), `.working`/`.idle` → current `stateLabel`. Width: `HUDRunwayLayout.rateWidth(for:)`.
  - Panel: add `@State private var openCodeRates: [String: OpenCodeRateDisplay] = [:]` and a `.task(id:)` loop keyed by (visible OpenCode root IDs, presentation, visibility) that calls `OpenCodeRateLoader.shared.displays(...)` then sleeps 5 s. Skip when visibility is `.alwaysOff` or the group is nil.
  - Loader: resolve the DB once per call via `OpenCodeBackendDetector.dbURL(customRoot:)`; for each visible row's root ID, call `latestUpdate`; reuse the cached activity when unchanged, else `requests` → `activity`. Run the SQLite work on a `DispatchQueue.global(qos: .utility)` continuation, as `CodexRunwaySnapshotLoader.snapshot` does (606-608). `isWorking = row.liveState == .active`.
  - Child rows: the service also reports running child sessions, which can appear as their own HUD rows. A row whose session is a child (`row.parentSessionID != nil`, or a `session_v2.parent_id` hit in the reader) gets no rate of its own; its requests count only in the parent's rate. Test: `testChildRowShowsNoSeparateRate`.
  - `runwayControlAvailable`: true when any Codex/Claude provider is shown **or** the OpenCode group is non-nil.
  - Update both doc comments: OpenCode rows now show a rate; no quota.
  - Localization: add the `"No API price for %@"` key (en + zh-Hans), update count/digest; run `python3 scripts/validate_localization_catalogs.py` and its unittest.

- [ ] **Step 4: Run** focused tests + `OpenCodeHUDGroupTests` + localization validator — PASS.

- [ ] **Step 5: Commit** `feat(opencode): show per-session rates in the Quota Meter`.

---

### Task 4: Release notes and full verification

**Files:**
- Modify: `docs/CHANGELOG.md` (`[Unreleased]` → `### Highlights` or `### Improvements`), `tools/release/test-count-baseline.txt`.

- [ ] **Step 1:** Add the CHANGELOG entry, user-facing and short: OpenCode sessions in the Quota Meter show tk/h, or $/h in the $ lens, per session; free routes read Free; no quota until Go data exists. Preview with `python3 tools/release/sparkle_release_notes.py --version 6.2 --changelog <copy with [Unreleased] renamed> --lint --out-text <scratch>`.
- [ ] **Step 2:** Run `./scripts/xcode_test_stable.sh`. Expected: TEST SUCCEEDED; record the passed count and set `tools/release/test-count-baseline.txt` to it.
- [ ] **Step 3:** Manual check with a real OpenCode 2.x TUI session (owner): working session shows a tk/h rate within ~1 minute of activity; $ lens shows $/h or Free; closing the TUI removes the row; CPU stays calm with the Quota Meter open for 5 minutes.
- [ ] **Step 4: Commit** `docs: record OpenCode session rates`.
