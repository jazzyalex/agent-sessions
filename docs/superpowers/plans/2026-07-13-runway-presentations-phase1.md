# Runway Presentations — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick the Quota Meter Session Runway presentation (5h `m/h` / token `tk/h` / weekly `%/h`) from a Meter-style toolbar control. ($ burn is Phase 2.)

**Architecture:** Compute-selected (Approach A): the chosen `RunwayPresentation` maps to a `(rateUnit, window)` on the runway request via a pure `effectivePresentation` resolver; the loader computes only the selected unit. Global selection, snapshot-wide per-provider fallback. Default `.fiveHour` = byte-equal to v4.4.

**Tech Stack:** Swift / SwiftUI / AppKit; XCTest. Build: `xcodebuild -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run`. Full suite: `xcodebuild test -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-test -destination 'platform=macOS'`.

## Global Constraints

- Default `.fiveHour` must be byte-equal to v4.4 behavior (5h m/h; Codex auto-→tk/h when 5h dropped via `RunwayProviderBaseline.rateUnit` derivation).
- One snapshot → one `rateUnit` (rendering layer invariant); fallback is snapshot-wide per provider, never per-row.
- No network in Phase 1. No `$`/`.dollarsPerHour`/price manifest (Phase 2).
- Claude runway path may only change where explicitly extended (new unit branch); 5h default output unchanged.
- TDD; frequent commits. Subagents never run `xcodebuild` or commit — ONE central verification in the main session (Task 9).
- Weekly help copy: "share of average weekly burn" (honest historical-share label).

---

### Task 1: `RunwayPresentation` enum + preference key

**Files:**
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift` (add key)
- Modify: `AgentSessions/CodexStatus/UsageDisplayMode.swift` (add enum)
- Test: `AgentSessionsTests/CodexUsageParserTests.swift`

**Interfaces:**
- Produces: `enum RunwayPresentation: String, CaseIterable, Identifiable { case fiveHour="5h", token="token", dollar="dollar", weekly="weekly" }` with `static let storageKey`, `static func current(raw:) -> RunwayPresentation` (default `.fiveHour`), `var shortLabel`, `var title`, `var detail`. `PreferencesKey.quotaMeterRunwayPresentation: String`.

- [ ] **Step 1: Add the pref key.** In `PreferencesConstants.swift`, beside `quotaMeterRunwayVisibility`, add:
```swift
static let quotaMeterRunwayPresentation = "QuotaMeterRunwayPresentation"
```

- [ ] **Step 2: Write the failing test** in `CodexUsageParserTests.swift`:
```swift
func testRunwayPresentationDefaultsToFiveHour() {
    XCTAssertEqual(RunwayPresentation.current(raw: ""), .fiveHour)
    XCTAssertEqual(RunwayPresentation.current(raw: "garbage"), .fiveHour)
    XCTAssertEqual(RunwayPresentation.current(raw: "weekly"), .weekly)
    XCTAssertEqual(RunwayPresentation.allCases.count, 4)
}
```

- [ ] **Step 3: Run — expect FAIL** (`RunwayPresentation` undefined).

- [ ] **Step 4: Add the enum** at the end of `UsageDisplayMode.swift`, mirroring `QuotaMeterRunwayVisibility`:
```swift
/// Which rate the Session Runway rows report. `$` (`.dollar`) is Phase 2.
enum RunwayPresentation: String, CaseIterable, Identifiable {
    case fiveHour = "5h"
    case token = "token"
    case dollar = "dollar"
    case weekly = "weekly"

    static let storageKey = PreferencesKey.quotaMeterRunwayPresentation
    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .token: return "tk"
        case .dollar: return "$"
        case .weekly: return "Wk"
        }
    }
    var title: String {
        switch self {
        case .fiveHour: return "5-Hour Burn"
        case .token: return "Token Burn"
        case .dollar: return "Dollar Burn"
        case .weekly: return "Weekly Burn"
        }
    }
    var detail: String {
        switch self {
        case .fiveHour: return "Quota-minutes per hour against the 5-hour window."
        case .token: return "Tokens generated per hour, per session."
        case .dollar: return "Estimated API-equivalent cost per hour."
        case .weekly: return "Share of average weekly burn."
        }
    }
    static func current(raw: String) -> RunwayPresentation {
        RunwayPresentation(rawValue: raw) ?? .fiveHour
    }
}
```

- [ ] **Step 5: Run — expect PASS.**

- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(runway): add RunwayPresentation enum + preference key"`

---

### Task 2: Extend `RunwayRateUnit` with `.weeklyPercentPerHour`

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexRunwayModel.swift` (`RunwayRateUnit`)
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`RunwayTimeFormatting.rate`, `HUDRunwayLoadBar.fillFraction`, `HUDRunwayLayout.rateWidth(for:)`)
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

**Interfaces:**
- Produces: `RunwayRateUnit.weeklyPercentPerHour`; `RunwayTimeFormatting.rate(_:unit:confidence:)` handles it → e.g. `"0.6%/h"`.

- [ ] **Step 1: Failing test** (formatting):
```swift
func testWeeklyPercentРerHourFormatting() {
    XCTAssertEqual(RunwayTimeFormatting.rate(0.6, unit: .weeklyPercentPerHour), "0.6%/h")
    XCTAssertEqual(RunwayTimeFormatting.rate(0, unit: .weeklyPercentPerHour, confidence: .waiting), "0%/h")
}
```
(Rename the func in the test to `testWeeklyPercentPerHourFormatting` — ASCII.)

- [ ] **Step 2: Run — expect FAIL** (missing case / member).

- [ ] **Step 3: Add the case** to `RunwayRateUnit` (CodexRunwayModel.swift):
```swift
enum RunwayRateUnit: Equatable, Sendable {
    case quotaMinutesPerHour
    case tokensPerHour
    case weeklyPercentPerHour
}
```
Note: `.dollarsPerHour` is deferred to Phase 2.

- [ ] **Step 4: Update the 3 render sites** in AgentCockpitHUDView.swift:
  - `RunwayTimeFormatting.rate` — add:
```swift
case .weeklyPercentPerHour:
    guard confidence != .waiting else { return "0%/h" }
    guard confidence != .idle else { return "idle" }
    guard value.isFinite, value >= 0.05 else { return "flat" }
    return String(format: "%.1f%%/h", value)
```
  - `HUDRunwayLoadBar.fillFraction` `switch unit` — add `case .weeklyPercentPerHour:` using the same relative-to-max branch as `.tokensPerHour` (`base = max(0.12, relative * 0.85)`).
  - `HUDRunwayLayout.rateWidth(for:)` — it is an `==` check, not a switch; change to: token/weekly/dollar-ish widths, e.g.
```swift
static func rateWidth(for unit: RunwayRateUnit) -> CGFloat {
    switch unit {
    case .tokensPerHour: return 80
    case .weeklyPercentPerHour: return 60
    case .quotaMinutesPerHour: return 52
    }
}
```

- [ ] **Step 5: Run — expect PASS.**

- [ ] **Step 6: Commit** `git commit -am "feat(runway): add weeklyPercentPerHour rate unit + rendering"`

---

### Task 3: Rename `quotaMinutesPerHour` → `displayRate` (row + summary + load bar)

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexRunwayModel.swift` (`RunwayPauseImpactRow`, `RunwayShortBurstSummary`, `CodexRunwayCalculator`, `RunwaySnapshotAssembly.withPendingRows`, `tokenSnapshot`)
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDRunwayPanel.maxQuotaMinutesPerHour`, `runwayRow`, `summaryRow`, `HUDRunwayLoadBar` param + all uses)
- Test: `AgentSessionsTests/CodexUsageParserTests.swift`, `CodexActiveSessionsRegistryTests.swift`, `ClaudeRunwayParserTests.swift`

**Interfaces:**
- Produces: `RunwayPauseImpactRow.displayRate: Double`, `RunwayShortBurstSummary.displayRate: Double`, `HUDRunwayLoadBar(displayRate:maxDisplayRate:...)`.

This is a mechanical, behavior-preserving rename. The field now carries the value in `baseline.rateUnit`'s unit (m/h, tk/h, or %/h). Existing tests must still pass after updating references.

- [ ] **Step 1: Rename struct fields** in CodexRunwayModel.swift: `RunwayPauseImpactRow.quotaMinutesPerHour` → `displayRate`; `RunwayShortBurstSummary.quotaMinutesPerHour` → `displayRate`. Update every construction site (`CodexRunwayCalculator.snapshot`, `impactRow`, `summary`, `tokenSnapshot`, `withPendingRows`).

- [ ] **Step 2: Rename the load bar param** in AgentCockpitHUDView.swift: `HUDRunwayLoadBar.quotaMinutesPerHour` → `displayRate`, `maxQuotaMinutesPerHour` → `maxDisplayRate`; update `HUDRunwayPanel.maxQuotaMinutesPerHour` computed (→ `maxDisplayRate`) and the two call sites (`runwayRow`, `summaryRow`) + `rateCell(quota:)` arg names as needed.

- [ ] **Step 3: Update tests** — replace `quotaMinutesPerHour:`/`.quotaMinutesPerHour` on rows/summaries with `displayRate` in the 3 test files (grep: `grep -rn "quotaMinutesPerHour" AgentSessionsTests`). NOTE: `CodexRunwayCalculator.quotaMinutesPerHour(_:windowMinutes:)` (the private helper func) keeps its name — it computes m/h; only the struct fields rename.

- [ ] **Step 4: Verify no stragglers** `grep -rn "\.quotaMinutesPerHour\b" AgentSessions AgentSessionsTests | grep -v "func quotaMinutesPerHour"` → only the helper func remains.

- [ ] **Step 5: Commit** `git commit -am "refactor(runway): rename row/summary quotaMinutesPerHour → displayRate"`

---

### Task 4: `effectivePresentation` resolver (pure)

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDRunwayRequestBuilder`)
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

**Interfaces:**
- Produces: `struct RunwayResolvedPresentation { let rateUnit: RunwayRateUnit; let windowMinutes: Int }` and `static func effectivePresentation(preferred: RunwayPresentation, source: UsageTrackingSource, hasFiveHour: Bool, hasWeekly: Bool, weeklyMeasurable: Bool, windowMinutes: Int) -> RunwayResolvedPresentation`.

Implements §5 (excluding `$`, which resolves to `.token` in Phase 1). `windowMinutes` passed in is the active-limit window length (300 or 10080).

- [ ] **Step 1: Failing tests:**
```swift
func testEffectivePresentationMatrix() {
    typealias B = HUDRunwayRequestBuilder
    // 5h preferred, 5h present → m/h
    XCTAssertEqual(B.effectivePresentation(preferred: .fiveHour, source: .codex, hasFiveHour: true, hasWeekly: true, weeklyMeasurable: true, windowMinutes: 300).rateUnit, .quotaMinutesPerHour)
    // 5h preferred, 5h dropped → token
    XCTAssertEqual(B.effectivePresentation(preferred: .fiveHour, source: .codex, hasFiveHour: false, hasWeekly: true, weeklyMeasurable: true, windowMinutes: 10080).rateUnit, .tokensPerHour)
    // token always → token
    XCTAssertEqual(B.effectivePresentation(preferred: .token, source: .codex, hasFiveHour: true, hasWeekly: true, weeklyMeasurable: true, windowMinutes: 300).rateUnit, .tokensPerHour)
    // dollar in Phase 1 → token
    XCTAssertEqual(B.effectivePresentation(preferred: .dollar, source: .codex, hasFiveHour: true, hasWeekly: true, weeklyMeasurable: true, windowMinutes: 300).rateUnit, .tokensPerHour)
    // weekly measurable → weekly
    XCTAssertEqual(B.effectivePresentation(preferred: .weekly, source: .codex, hasFiveHour: true, hasWeekly: true, weeklyMeasurable: true, windowMinutes: 300).rateUnit, .weeklyPercentPerHour)
    // weekly unmeasurable → token
    XCTAssertEqual(B.effectivePresentation(preferred: .weekly, source: .codex, hasFiveHour: true, hasWeekly: true, weeklyMeasurable: false, windowMinutes: 300).rateUnit, .tokensPerHour)
    // weekly, no weekly window → token
    XCTAssertEqual(B.effectivePresentation(preferred: .weekly, source: .claude, hasFiveHour: true, hasWeekly: false, weeklyMeasurable: false, windowMinutes: 300).rateUnit, .tokensPerHour)
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** in `HUDRunwayRequestBuilder`:
```swift
struct RunwayResolvedPresentation: Equatable { let rateUnit: RunwayRateUnit; let windowMinutes: Int }

static func effectivePresentation(preferred: RunwayPresentation,
                                  source: UsageTrackingSource,
                                  hasFiveHour: Bool,
                                  hasWeekly: Bool,
                                  weeklyMeasurable: Bool,
                                  windowMinutes: Int) -> RunwayResolvedPresentation {
    switch preferred {
    case .token, .dollar: // $ is Phase 2 → token
        return RunwayResolvedPresentation(rateUnit: .tokensPerHour, windowMinutes: windowMinutes)
    case .fiveHour:
        return hasFiveHour
            ? RunwayResolvedPresentation(rateUnit: .quotaMinutesPerHour, windowMinutes: windowMinutes)
            : RunwayResolvedPresentation(rateUnit: .tokensPerHour, windowMinutes: windowMinutes)
    case .weekly:
        return (hasWeekly && weeklyMeasurable)
            ? RunwayResolvedPresentation(rateUnit: .weeklyPercentPerHour, windowMinutes: 10080)
            : RunwayResolvedPresentation(rateUnit: .tokensPerHour, windowMinutes: windowMinutes)
    }
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `git commit -am "feat(runway): effectivePresentation resolver (Phase 1 matrix)"`

---

### Task 5: Weekly per-session math (calculator)

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexRunwayModel.swift` (`CodexRunwayCalculator`)
- Test: `AgentSessionsTests/CodexUsageParserTests.swift`

**Interfaces:**
- Produces: `CodexRunwayCalculator.weeklySnapshot(baseline:activities:maxRows:) -> CodexRunwaySnapshot?` — per-session weekly `%/h` = (session tokens/sec ÷ Σ tokens/sec) × providerWeeklyPercentPerHour, where providerWeeklyPercentPerHour derives from `baseline` (remainingPercent + currentRunoutAt = weekly averageBurnRunout, expressed as %/hour). Returns `nil` when unmeasurable (so the loader falls back to token — Task 6).

The provider weekly rate: `providerRatePerSec = baseline.remainingPercent / (currentRunoutAt - observedAt)` (percent-of-weekly per second, already how the calculator derives providerRate). `%/h = providerRatePerSec × 3600`. Attribute by token share; rows carry `%/h` in `displayRate`; `deadline = .unavailable`; confidence `.direct`.

- [ ] **Step 1: Failing test:**
```swift
func testWeeklySnapshotAttributesPaceByTokenShare() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let reset = now.addingTimeInterval(7 * 24 * 3600)
    // Weekly baseline: 20% used over ~2 days → averageBurnRunout gives providerRate.
    let observed = now
    let runout = RunwayBaselineMath.averageBurnRunout(remainingPercent: 80, resetAt: reset,
                    windowLength: 10080*60, now: now)!
    let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 80, resetAt: reset,
                    currentRunoutAt: runout, observedAt: observed, hasProjectedRunout: true,
                    windowMinutes: 10080, rateUnit: .weeklyPercentPerHour)
    let a = RunwaySessionActivity(identity: .init(id: "a", displayName: "A", isGoal: false, logPaths: ["/a"]),
                    tokensPerSecond: 300, sampleStart: now, sampleEnd: now)
    let b = RunwaySessionActivity(identity: .init(id: "b", displayName: "B", isGoal: false, logPaths: ["/b"]),
                    tokensPerSecond: 100, sampleStart: now, sampleEnd: now)
    let snap = CodexRunwayCalculator.weeklySnapshot(baseline: baseline, activities: [a, b], maxRows: 5)
    XCTAssertEqual(snap?.rows.map(\.id), ["a", "b"])
    // a gets 3/4 of provider weekly %/h, b gets 1/4.
    let total = (snap?.rows.first?.displayRate ?? 0) + (snap?.rows.last?.displayRate ?? 0)
    XCTAssertGreaterThan(total, 0)
    XCTAssertEqual((snap?.rows.first?.displayRate ?? 0) / total, 0.75, accuracy: 0.01)
}

func testWeeklySnapshotNilWhenUnmeasurable() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let reset = now.addingTimeInterval(7 * 24 * 3600)
    // remainingPercent 100 (0 used) → providerRate 0 → nil.
    let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 100, resetAt: reset,
                    currentRunoutAt: reset, observedAt: now, hasProjectedRunout: false,
                    windowMinutes: 10080, rateUnit: .weeklyPercentPerHour)
    let a = RunwaySessionActivity(identity: .init(id: "a", displayName: "A", isGoal: false, logPaths: ["/a"]),
                    tokensPerSecond: 300, sampleStart: now, sampleEnd: now)
    XCTAssertNil(CodexRunwayCalculator.weeklySnapshot(baseline: baseline, activities: [a], maxRows: 5))
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `weeklySnapshot`** (mirror `tokenSnapshot`'s ranking/overflow, but rate = share × provider %/h):
```swift
static func weeklySnapshot(baseline: RunwayProviderBaseline,
                           activities: [RunwaySessionActivity],
                           maxRows: Int) -> CodexRunwaySnapshot? {
    guard maxRows > 0 else { return nil }
    let seconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
    guard seconds > 0, baseline.remainingPercent > 0 else { return nil }
    let providerPercentPerHour = (baseline.remainingPercent / seconds) * 3600
    guard providerPercentPerHour > 0, providerPercentPerHour.isFinite else { return nil }
    let positive = activities.filter { $0.tokensPerSecond > 0 && $0.tokensPerSecond.isFinite }
    guard !positive.isEmpty else { return nil }
    let totalTPS = positive.reduce(0) { $0 + $1.tokensPerSecond }
    guard totalTPS > 0 else { return nil }
    let ranked = positive.sorted { $0.tokensPerSecond != $1.tokensPerSecond ? $0.tokensPerSecond > $1.tokensPerSecond
        : ($0.identity.isGoal != $1.identity.isGoal ? $0.identity.isGoal
        : $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending) }
    let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
    func rate(_ a: RunwaySessionActivity) -> Double { providerPercentPerHour * (a.tokensPerSecond / totalTPS) }
    let rows = visible.map { a in
        RunwayPauseImpactRow(id: a.identity.id, displayName: a.identity.displayName, isGoal: a.identity.isGoal,
            deadline: .unavailable, gainedSeconds: 0, displayRate: rate(a), confidence: .direct)
    }
    let summary = overflow.isEmpty ? nil : RunwayShortBurstSummary(count: overflow.count,
        deadline: .unavailable, gainedSeconds: 0, displayRate: overflow.reduce(0) { $0 + rate($1) })
    return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: summary)
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `git commit -am "feat(runway): per-session weekly %/h snapshot (token-share × weekly avg-burn)"`

---

### Task 6: Thread presentation through the Codex builder + loader + request id

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDRunwayRequestBuilder.request`, `codexRunwayRequest` call sites x2, add `@AppStorage` for the pref)
- Modify: `AgentSessions/CodexStatus/CodexRunwayModel.swift` (`CodexRunwaySnapshotRequest.id` add rateUnit; loader `.weeklyPercentPerHour` branch)
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

**Interfaces:**
- Consumes: Task 4 `effectivePresentation`, Task 5 `weeklySnapshot`.
- Produces: request carries the resolved `rateUnit`; loader computes weekly when `rateUnit == .weeklyPercentPerHour`, falling back to token snapshot-wide when `weeklySnapshot` returns nil.

- [ ] **Step 1: Add `rateUnit` to `CodexRunwaySnapshotRequest.id`** (CodexRunwayModel.swift) — append `"\(baseline.rateUnit)"` to the id components array (so a presentation switch refires `.task(id:)`). Test:
```swift
func testRequestIDChangesWithRateUnit() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = now.addingTimeInterval(3*3600)
    func mk(_ u: RunwayRateUnit) -> CodexRunwaySnapshotRequest {
        CodexRunwaySnapshotRequest(baseline: RunwayProviderBaseline(source: .codex, remainingPercent: 50,
            resetAt: reset, currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: u),
            identities: [], now: now, maxRows: 5)
    }
    XCTAssertNotEqual(mk(.quotaMinutesPerHour).id, mk(.tokensPerHour).id)
}
```

- [ ] **Step 2: Run — expect FAIL; add the id component; expect PASS.**

- [ ] **Step 3: Loader weekly branch** — in `CodexRunwaySnapshotLoader.snapshot`, extend the `if request.baseline.rateUnit == .tokensPerHour { … } else { … }` into:
```swift
let core: CodexRunwaySnapshot?
switch request.baseline.rateUnit {
case .tokensPerHour:
    core = CodexRunwayCalculator.tokenSnapshot(baseline: request.baseline, activities: activities, maxRows: request.maxRows)
case .weeklyPercentPerHour:
    core = CodexRunwayCalculator.weeklySnapshot(baseline: request.baseline, activities: activities, maxRows: request.maxRows)
        ?? CodexRunwayCalculator.tokenSnapshot(baseline: request.baseline, activities: activities, maxRows: request.maxRows) // dead-number fallback (P6)
default:
    let directBurns = identities.compactMap { CodexRunwayRateLimitParser.burn(identity: $0, now: request.now) }
    let tokenBurns = request.baseline.hasProjectedRunout
        ? CodexRunwayTokenActivityParser.burns(activities: activities, baseline: request.baseline) : []
    core = CodexRunwayCalculator.snapshot(baseline: request.baseline,
        burns: mergeBurns(directBurns: directBurns, tokenBurns: tokenBurns), maxRows: request.maxRows)
}
```
IMPORTANT: when weekly falls back to token, the rows are tk/h but `baseline.rateUnit` is `.weeklyPercentPerHour` → rendering would mislabel. Fix: when falling back, return a snapshot whose baseline rateUnit is `.tokensPerHour`. Build the token snapshot with a token-unit baseline (copy `request.baseline` with `rateUnit: .tokensPerHour`) so the whole snapshot is coherent (one-unit invariant).

- [ ] **Step 4: Builder wiring** — `HUDRunwayRequestBuilder.request` gains `presentation: RunwayPresentation` + weekly fields (`weekRemainingPercent: Int`, `weekResetText: String`). Compute `resolved = effectivePresentation(...)` from presentation + `fiveHourRemainingPercent > 0`/window state + `weeklyMeasurable` (derive: weekly used% > 0 and weekly resetDate valid). When `resolved.rateUnit == .weeklyPercentPerHour`, build the baseline from the WEEKLY fields (remaining=week%, reset=weekReset, currentRunoutAt=averageBurnRunout(week), windowMinutes=10080, rateUnit=.weeklyPercentPerHour); else keep the existing active-window baseline but set `rateUnit: resolved.rateUnit`. Both `codexRunwayRequest` call sites read `@AppStorage(PreferencesKey.quotaMeterRunwayPresentation)` and pass it + the week fields (`codexUsageModel.weekRemainingPercent`, `codexUsageModel.weekResetText`).

- [ ] **Step 5: Test** the builder produces `.weeklyPercentPerHour` baseline when presentation `.weekly` + measurable weekly, and `.quotaMinutesPerHour` for `.fiveHour` default (byte-equal v4.4). Run — expect PASS.

- [ ] **Step 6: Commit** `git commit -am "feat(runway): thread presentation + weekly window through Codex builder/loader"`

---

### Task 7: Claude loader unit branch (P5)

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift`
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`claudeRunwayRequest` passes presentation + week fields; `HUDRunwayRequestBuilder.claudeRequest` resolves presentation)
- Test: `AgentSessionsTests/ClaudeRunwayParserTests.swift`

**Interfaces:**
- Consumes: Task 4/5/6. Produces: Claude runway renders tk/h and weekly %/h (not just m/h).

- [ ] **Step 1: Failing test** — a Claude request with `rateUnit: .tokensPerHour` yields token-mode rows (rate = tk/h), and `.weeklyPercentPerHour` yields weekly rows. (Mirror the Codex token/weekly loader tests with `ClaudeRunwaySnapshotLoader` + `.claude` baseline.)

- [ ] **Step 2: Run — expect FAIL** (Claude loader ignores rateUnit).

- [ ] **Step 3: Add the branch** to `ClaudeRunwaySnapshotLoader.snapshot`, mirroring Task 6's switch: `.tokensPerHour` → build token rows from Claude activities (Claude tk/h = input+output+cache_creation per v4.4/spec §3a — but Phase 1 uses the EXISTING Claude activity `tokensPerSecond` value as-is; per-type is Phase 2); `.weeklyPercentPerHour` → `weeklySnapshot` with token fallback; `default` → existing m/h path unchanged. Reuse `CodexRunwayCalculator.tokenSnapshot`/`weeklySnapshot` (they operate on `RunwaySessionActivity`, provider-agnostic).

- [ ] **Step 4: `claudeRequest` wiring** — add `presentation` + week fields (`claudeUsageModel.weekAllModelsRemainingPercent`, `weekAllModelsResetText`); resolve via `effectivePresentation(source: .claude, hasFiveHour: true, hasWeekly: weekly-valid, …)`. Claude always has a 5h ("session") window, so `.fiveHour` → m/h unchanged.

- [ ] **Step 5: Run — expect PASS.**

- [ ] **Step 6: Commit** `git commit -am "feat(runway): Claude loader honors rateUnit (token + weekly)"`

---

### Task 8: QM-toolbar presentation selector

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (add `runwayPresentationPicker` + place beside `cockpitModePicker`; add `@AppStorage` + `@State showPresentationPopover`)
- (Reuse/extend the popover pattern of `HUDCockpitModePopover`, or a small inline popover listing the 4 `RunwayPresentation` cases.)

**Interfaces:**
- Consumes: `RunwayPresentation`. Produces: user-visible control bound to `PreferencesKey.quotaMeterRunwayPresentation`; changing it updates `@AppStorage`, which flows into the builders (Task 6/7) and rebuilds the runway.

- [ ] **Step 1:** Add `@AppStorage(PreferencesKey.quotaMeterRunwayPresentation) private var runwayPresentationRaw = RunwayPresentation.fiveHour.rawValue` and `@State private var showPresentationPopover = false` to the QM view struct that owns the toolbar.

- [ ] **Step 2:** Add `runwayPresentationPicker` mirroring `cockpitModePicker`: a `Button` (label = `RunwayPresentation.current(raw:).shortLabel` + chevron) with `HUDIconButtonStyle`, `.help("Session Runway rate: 5h / tokens / $ / weekly")`, and a `.popover` listing the 4 cases (title + detail; `$` shown but Phase-1-resolves-to-token — keep it selectable, it just falls back). On select: set `runwayPresentationRaw`, close popover. Only show the picker when the runway is visible (same condition as the runway drawer).

- [ ] **Step 3:** Place `runwayPresentationPicker` in the QM toolbar next to `cockpitModePicker` (the QM-mode branches around lines 1258-1300).

- [ ] **Step 4:** Manual check deferred to Task 9 build + user QA (no unit test for SwiftUI layout).

- [ ] **Step 5: Commit** `git commit -am "feat(runway): QM toolbar presentation selector (Meter-style)"`

---

### Task 9: Central verification (main session only)

**Files:** none (verification).

- [ ] **Step 1:** Build: `xcodebuild build -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run -destination 'platform=macOS'` → `BUILD SUCCEEDED`.
- [ ] **Step 2:** Full suite: `xcodebuild test -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-test -destination 'platform=macOS'` → 0 failures (≥ prior count + new tests).
- [ ] **Step 3:** Sanity: default `.fiveHour` unchanged — the existing v4.4 runway tests (token-mode, weekly-ignores-projection, hold, etc.) still pass untouched.
- [ ] **Step 4:** Relaunch `.deriveddata-run` build for user visual QA of the toolbar picker + switching presentations.
- [ ] **Step 5:** Commit any test-count/notes; report GO/NO-GO.

---

## Self-Review

- **Spec coverage:** §2 presentation model → T1/T8; §3 rate unit + rename + request-id + resolver → T2/T3/T4/T6; §3b weekly + dead-number fallback → T5/T6; §5 matrix → T4; §6 rendering → T2; P5 Claude branch → T7. §3a `$`/per-type, §4 price manifest, §7 privacy → **Phase 2 (out of scope here).** ✓
- **Placeholder scan:** concrete code in each logic step; mechanical rename steps give exact grep targets. ✓
- **Type consistency:** `displayRate` used consistently T3→T5→T6; `RunwayResolvedPresentation`/`effectivePresentation` signature stable T4→T6/T7; `weeklySnapshot` signature stable T5→T6/T7. ✓
- **One-unit invariant:** weekly→token fallback rebuilds the baseline with `.tokensPerHour` (T6 Step 3) so the snapshot stays single-unit. ✓
