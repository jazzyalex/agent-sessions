# Session Info Inspector Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the "Session info" pane so one hero number (cost) leads, the cache/fresh/output split is visible at a glance, configuration history is a clickable timeline that jumps into the transcript, and all estimation provenance collapses into one closed group — removing the per-request duplicate rows the pane renders today.

**Architecture:** Presentation-only. All new logic is pure static functions on the existing `TranscriptTelemetryPresentation` enum, unit-tested without a view. The view layer splits into a new components file plus a rewritten `TranscriptTelemetryView.body`. The transcript jump reuses the existing token-based external-jump machinery in `BlockTableController` (`scrollToBlock`), adding one more intent alongside `eventJumpToken`.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit (`NSTableView`-backed transcript), XCTest.

**Spec:** `docs/superpowers/plans/2026-09-10-session-info-inspector-SPEC.md`
**Visual reference:** `docs/superpowers/plans/assets/2026-09-10-session-info-inspector-mockup.html` — **open this in a browser before Task 5.** It carries the exact strings, sizes and colors.

---

## Global Constraints

- **Presentation only.** Do not modify any file under `AgentSessions/Model/`, any telemetry accumulator, the price manifest, or the quota calibration. If a number looks wrong, note it and move on — it is a separate bug.
- **No literal colors.** Every color is a semantic SwiftUI color (`.primary`, `.secondary`, `.accentColor`, `.orange`) or an `NSColor` role. No hex.
- **No literal spacing.** Use `LayoutTokens.xs/sm/md/lg/xl` from `AgentSessions/Utilities/LayoutTokens.swift`.
- **Absent values render as `—`** with the reason in `.help()`. The string `"Unavailable ("` must not appear in any visible label after Task 6.
- **Never fill missing evidence.** The file header comment on `TranscriptTelemetryView.swift` is binding: *"Presentation only: never fills missing evidence from Session.model or a parent."* A field the transcript did not record stays unknown.
- **Reasoning tokens are a subset of output.** Never add them to a total and never give them their own bar segment.
- Build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
- Tests: `./scripts/xcode_test_stable.sh`
- New Swift files must be registered with `./scripts/xcode_add_file.rb` — never hand-edit `project.pbxproj`. A correct run adds exactly 4 lines.
- **The test host opens the real `index.db`.** Running the suite touches the owner's live index. Expected and safe, but never add a test that writes to it.
- Commit style: Conventional Commits with `Tool:` / `Model:` / `Why:` trailers. **Do not commit or push unless the owner asks.** The commit steps below are written out so the owner can run them; an agent stops at the staged state and reports.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `AgentSessions/Views/TranscriptTelemetryView.swift` | `TranscriptTelemetryPresentation` (pure formatting + grouping) and the panel composition | Modify |
| `AgentSessions/Views/SessionInfoComponents.swift` | Reusable panel subviews: `SessionInfoRow`, `TokenShareBar`, `SessionInfoHistoryList`, `SessionInfoSection` | **Create** |
| `AgentSessions/Views/TranscriptPlainView.swift` | Hosts the panel; owns the jump-token state and passes `derivedState.snapshot.blocks` in | Modify |
| `AgentSessions/Views/TranscriptBlockListView.swift` | Consumes the new config-change jump intent | Modify |
| `AgentSessions/Views/UnifiedSessionsView.swift` | Toolbar entry point | Modify **(Task 8, gated on owner decision)** |
| `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift` | Unit tests for all pure functions | Modify |

---

## Task 1: Deduplicated pricing basis

Fixes the defect where a 23-request session renders 23 near-identical provenance lines.

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift:1-64` (the `TranscriptTelemetryPresentation` enum)
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionTelemetry.usageEvents: [TelemetryUsageEvent]`, `TelemetryUsageOwnership.session`
- Produces: `TelemetryPricingBasis` and `TranscriptTelemetryPresentation.pricingBasis(_:) -> [TelemetryPricingBasis]`, used by Task 6.

- [ ] **Step 1: Write the failing test**

Append to `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`, inside the existing class:

```swift
    private func usageEvent(model: String?,
                            speed: String = "standard-normalized",
                            geo: String? = nil,
                            context: Int?,
                            ownership: TelemetryUsageOwnership = .session,
                            anchorLine: Int = 0) -> TelemetryUsageEvent {
        TelemetryUsageEvent(recordID: nil, observedAt: nil, anchorLine: anchorLine,
                            usageFamily: "token_count", ownership: ownership,
                            model: model, reasoningEffort: nil, speed: speed, inferenceGeo: geo,
                            freshInputTokens: 100, cacheReadTokens: 900,
                            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
                            outputTokens: 10, reasoningOutputTokens: 4,
                            contextInputTokens: context)
    }

    private func telemetry(events: [TelemetryUsageEvent],
                           hasBreakdown: Bool = true,
                           changes: [ConfigurationChange] = [],
                           initial: SessionConfiguration? = nil,
                           current: SessionConfiguration? = nil) -> SessionTelemetry {
        let owned = events.filter { $0.ownership == .session }
        return SessionTelemetry(
            source: .codex,
            initialConfiguration: initial,
            currentConfiguration: current,
            configurationChanges: changes,
            usageSlices: [],
            usageEvents: events,
            usageSummary: TelemetryUsageSummary(
                topLineTokens: owned.reduce(0) { $0 + $1.topLineTokens },
                hasComponentBreakdown: hasBreakdown,
                recordedTotalTokens: nil,
                usageFamilies: ["token_count"],
                usageFamilyConflict: false),
            costEstimate: nil)
    }

    func testPricingBasisCollapsesRequestsThatDifferOnlyByContextSize() {
        let telemetry = telemetry(events: [
            usageEvent(model: "gpt-5.6-sol", context: 101_011),
            usageEvent(model: "gpt-5.6-sol", context: 109_354),
            usageEvent(model: "gpt-5.6-sol", context: 115_539)
        ])
        let basis = TranscriptTelemetryPresentation.pricingBasis(telemetry)
        XCTAssertEqual(basis.count, 1)
        XCTAssertEqual(basis[0].requestCount, 3)
        XCTAssertEqual(basis[0].minContextInputTokens, 101_011)
        XCTAssertEqual(basis[0].maxContextInputTokens, 115_539)
    }

    func testPricingBasisSeparatesModelSpeedAndRegionInFirstSeenOrder() {
        let telemetry = telemetry(events: [
            usageEvent(model: "gpt-5.6-sol", context: 100),
            usageEvent(model: "gpt-5.6-sol", speed: "fast", context: 100),
            usageEvent(model: "gpt-5.6-luna", context: 100),
            usageEvent(model: "gpt-5.6-sol", geo: "us", context: 100)
        ])
        let basis = TranscriptTelemetryPresentation.pricingBasis(telemetry)
        XCTAssertEqual(basis.count, 4)
        XCTAssertEqual(basis.map(\.model),
                       ["gpt-5.6-sol", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(basis[1].speed, "fast")
        XCTAssertEqual(basis[3].inferenceGeo, "us")
    }

    func testPricingBasisExcludesDelegatedWork() {
        let telemetry = telemetry(events: [
            usageEvent(model: "gpt-5.6-sol", context: 100),
            usageEvent(model: "claude-opus-5", context: 100, ownership: .descendant)
        ])
        let basis = TranscriptTelemetryPresentation.pricingBasis(telemetry)
        XCTAssertEqual(basis.map(\.model), ["gpt-5.6-sol"])
    }

    func testPricingBasisReportsNoContextRangeWhenNoRequestRecordedOne() {
        let telemetry = telemetry(events: [usageEvent(model: "gpt-5.6-sol", context: nil)])
        let basis = TranscriptTelemetryPresentation.pricingBasis(telemetry)
        XCTAssertNil(basis[0].minContextInputTokens)
        XCTAssertNil(basis[0].maxContextInputTokens)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./scripts/xcode_test_stable.sh
```

Expected: compile failure — `cannot find 'TelemetryPricingBasis' in scope` / no member `pricingBasis`.

- [ ] **Step 3: Write the implementation**

Insert into `AgentSessions/Views/TranscriptTelemetryView.swift`, above `enum TranscriptTelemetryPresentation`:

```swift
/// One row of the "How this was estimated" group: a distinct pricing identity,
/// NOT a request. Context size varies request to request and is summarised as a
/// range — keying on it is what produced one visible row per request.
public struct TelemetryPricingBasis: Equatable {
    public let model: String?
    public let speed: String
    public let inferenceGeo: String?
    public let requestCount: Int
    public let minContextInputTokens: Int?
    public let maxContextInputTokens: Int?
}
```

And inside `TranscriptTelemetryPresentation`:

```swift
    /// Session-owned requests grouped by pricing identity, in first-seen order.
    /// Delegated work is excluded: it is priced against its own transcript.
    static func pricingBasis(_ telemetry: SessionTelemetry) -> [TelemetryPricingBasis] {
        struct Key: Hashable {
            let model: String?
            let speed: String
            let geo: String?
        }
        var order: [Key] = []
        var grouped: [Key: [TelemetryUsageEvent]] = [:]
        for event in telemetry.usageEvents where event.ownership == .session {
            let key = Key(model: event.model, speed: event.speed, geo: event.inferenceGeo)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(event)
        }
        return order.map { key in
            let events = grouped[key] ?? []
            let contexts = events.compactMap(\.contextInputTokens)
            return TelemetryPricingBasis(model: key.model,
                                         speed: key.speed,
                                         inferenceGeo: key.geo,
                                         requestCount: events.count,
                                         minContextInputTokens: contexts.min(),
                                         maxContextInputTokens: contexts.max())
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
./scripts/xcode_test_stable.sh
```

Expected: PASS, and the total test count is 4 higher than before this task.

- [ ] **Step 5: Stage**

```bash
git add AgentSessions/Views/TranscriptTelemetryView.swift AgentSessionsTests/TranscriptTelemetryPresentationTests.swift
```

---

## Task 2: Token share for the bar

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift`
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionTelemetry.usageEvents`, `SessionTelemetry.usageSummary?.hasComponentBreakdown`
- Produces: `TelemetryTokenShare` with `cached`, `fresh`, `output`, `total`, `cachedFraction`, `freshFraction`, `outputFraction`, `cacheWriteTokens`, `reasoningTokens`; and `TranscriptTelemetryPresentation.tokenShare(_:) -> TelemetryTokenShare?`. Used by `TokenShareBar` in Task 5.

- [ ] **Step 1: Write the failing test**

```swift
    func testTokenShareFoldsCacheWritesIntoFreshAndKeepsReasoningOutOfTheTotal() {
        let event = TelemetryUsageEvent(
            recordID: nil, observedAt: nil, anchorLine: 0, usageFamily: "token_count",
            ownership: .session, model: "gpt-5.6-sol", reasoningEffort: nil,
            speed: "standard-normalized", inferenceGeo: nil,
            freshInputTokens: 300, cacheReadTokens: 600,
            cacheWrite5mTokens: 60, cacheWrite1hTokens: 40,
            outputTokens: 100, reasoningOutputTokens: 70, contextInputTokens: 900)
        let share = TranscriptTelemetryPresentation.tokenShare(telemetry(events: [event]))
        XCTAssertEqual(share?.cached, 600)
        XCTAssertEqual(share?.fresh, 400)          // 300 fresh + 100 cache writes
        XCTAssertEqual(share?.output, 100)
        XCTAssertEqual(share?.total, 1100)         // reasoning is inside output, never added
        XCTAssertEqual(share?.cacheWriteTokens, 100)
        XCTAssertEqual(share?.reasoningTokens, 70)
        XCTAssertEqual(share?.cachedFraction ?? 0, 600.0 / 1100.0, accuracy: 0.0001)
    }

    func testTokenShareIsUnavailableWithoutAComponentBreakdown() {
        let telemetry = telemetry(events: [usageEvent(model: "x", context: 1)],
                                  hasBreakdown: false)
        XCTAssertNil(TranscriptTelemetryPresentation.tokenShare(telemetry))
    }

    func testTokenShareIsUnavailableWhenOnlyDelegatedWorkExists() {
        let telemetry = telemetry(events: [
            usageEvent(model: "x", context: 1, ownership: .descendant)
        ])
        XCTAssertNil(TranscriptTelemetryPresentation.tokenShare(telemetry))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./scripts/xcode_test_stable.sh
```

Expected: compile failure — no member `tokenShare`.

- [ ] **Step 3: Write the implementation**

Above `enum TranscriptTelemetryPresentation`:

```swift
/// The three-way split behind the token bar. Cache writes fold into `fresh`
/// because they are input the request paid to write; reasoning is reported
/// separately and never enters `total` — both providers count it inside output.
public struct TelemetryTokenShare: Equatable {
    public let cached: Int
    public let fresh: Int
    public let output: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int

    public var total: Int { cached + fresh + output }
    public var cachedFraction: Double { fraction(cached) }
    public var freshFraction: Double { fraction(fresh) }
    public var outputFraction: Double { fraction(output) }

    private func fraction(_ part: Int) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}
```

Inside `TranscriptTelemetryPresentation`:

```swift
    /// nil when the bar must not be drawn: no session-owned usage, no component
    /// breakdown (legacy total-only logs), or a zero total.
    static func tokenShare(_ telemetry: SessionTelemetry) -> TelemetryTokenShare? {
        guard telemetry.usageSummary?.hasComponentBreakdown == true else { return nil }
        let owned = telemetry.usageEvents.filter { $0.ownership == .session }
        guard !owned.isEmpty else { return nil }
        let writes = owned.reduce(0) { $0 + $1.cacheWrite5mTokens + $1.cacheWrite1hTokens }
        let share = TelemetryTokenShare(
            cached: owned.reduce(0) { $0 + $1.cacheReadTokens },
            fresh: owned.reduce(0) { $0 + $1.freshInputTokens } + writes,
            output: owned.reduce(0) { $0 + $1.outputTokens },
            cacheWriteTokens: writes,
            reasoningTokens: owned.reduce(0) { $0 + $1.reasoningOutputTokens })
        return share.total > 0 ? share : nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
./scripts/xcode_test_stable.sh
```

Expected: PASS.

- [ ] **Step 5: Stage**

```bash
git add AgentSessions/Views/TranscriptTelemetryView.swift AgentSessionsTests/TranscriptTelemetryPresentationTests.swift
```

---

## Task 3: History rows sharing the marker anchoring

The timeline row and the inline transcript marker must land on the **same** block. The only way to guarantee that is to have both read one anchoring function, so this task refactors `markers(changes:blocks:)` onto a shared primitive rather than writing a second copy of the logic.

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift:48-63` (`markers`)
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionTranscriptBuilder.LogicalBlock` (`kind`, `eventID`, `globalBlockIndex`), `ConfigurationChange`, `SessionConfiguration`
- Produces: `SessionInfoHistoryRow` and `TranscriptTelemetryPresentation.historyRows(telemetry:blocks:) -> [SessionInfoHistoryRow]`. Used by Task 5 and Task 7.

- [ ] **Step 1: Write the failing test**

```swift
    func testHistoryRowsLeadWithTheStartedConfigurationAndMarkInference() {
        let started = SessionConfiguration(model: "gpt-5.6-sol", reasoningEffort: "medium",
                                           observedAt: nil, anchorLine: 0,
                                           provenance: .inferredFirstObservation)
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [], initial: started, current: started),
            blocks: [block(0, record: 1)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .started)
        XCTAssertEqual(rows[0].title, "Started gpt-5.6-sol · medium")
        XCTAssertTrue(rows[0].isInferred)
    }

    func testHistoryRowsAndInlineMarkersResolveToTheSameBlock() {
        let blocks = [block(0, record: 1), block(1, record: 9)]
        let changes = [change(7)]
        let markers = TranscriptTelemetryPresentation.markers(changes: changes, blocks: blocks)
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: changes), blocks: blocks)
        let changeRow = rows.first { $0.kind == .change }
        XCTAssertEqual(changeRow?.blockIndex, 1)
        XCTAssertEqual(markers.keys.sorted(), [1])
    }

    func testHistoryRowTitleReadsAsAChangeNotAFieldName() {
        let effort = ConfigurationChange(field: .reasoningEffort, oldValue: "medium",
                                         newValue: "high", observedAt: nil, anchorLine: 3,
                                         provenance: .effectiveTurnContext)
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [effort]),
            blocks: [block(0, record: 1), block(1, record: 9)])
        XCTAssertEqual(rows.first { $0.kind == .change }?.title,
                       "Thinking effort medium → high")
    }

    func testHistoryRowsAreEmptyWhenNothingWasRecorded() {
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: []), blocks: [])
        XCTAssertTrue(rows.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./scripts/xcode_test_stable.sh
```

Expected: compile failure — no member `historyRows`.

- [ ] **Step 3: Write the implementation**

Above `enum TranscriptTelemetryPresentation`:

```swift
/// One row of the Session info history timeline. `blockIndex` is the transcript
/// block the inline marker for this change was placed on — the two are resolved
/// by the same anchoring function so a jump can never land somewhere the marker
/// is not.
public struct SessionInfoHistoryRow: Equatable, Identifiable {
    public enum Kind: Equatable { case started, change }
    public let id: Int
    public let kind: Kind
    public let title: String
    public let observedAt: Date?
    /// True only for a started row the transcript never actually stated.
    public let isInferred: Bool
    public let blockIndex: Int?
}
```

Replace the body of `markers(changes:blocks:)` and add the shared primitive plus `historyRows`:

```swift
    /// (record index, block index) pairs for every non-meta block, in block order.
    /// Meta blocks are excluded because a marker attached to one would render
    /// inside chrome rather than beside a message.
    static func anchors(_ blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [(record: Int, block: Int)] {
        blocks.filter { $0.kind != .meta }.compactMap { block in
            guard let index = recordIndex(eventID: block.eventID) else { return nil }
            return (index, block.globalBlockIndex)
        }
    }

    /// The block a change's marker belongs on: the first block at or after the
    /// change's record, or a trailing anchor past the end when the change happened
    /// after the final message. Single source of truth for both the inline markers
    /// and the history timeline.
    static func anchorBlockIndex(change: ConfigurationChange,
                                 anchors: [(record: Int, block: Int)],
                                 blockCount: Int) -> Int? {
        guard !anchors.isEmpty else { return nil }
        return anchors.first(where: { $0.record >= change.anchorLine })?.block ?? blockCount
    }

    static func markers(changes: [ConfigurationChange],
                        blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        let anchors = Self.anchors(blocks)
        for change in changes {
            guard let target = anchorBlockIndex(change: change, anchors: anchors,
                                                blockCount: blocks.count) else { continue }
            let timestamp = change.observedAt.map { AppDateFormatting.transcriptTimestamp($0) + " · " } ?? ""
            result[target, default: []].append(timestamp + Self.change(change))
        }
        return result
    }

    /// The started baseline (when one is known) followed by every recorded change,
    /// in transcript order.
    static func historyRows(telemetry: SessionTelemetry,
                            blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [SessionInfoHistoryRow] {
        var rows: [SessionInfoHistoryRow] = []
        let anchors = Self.anchors(blocks)
        if let initial = telemetry.initialConfiguration,
           initial.model != nil || initial.reasoningEffort != nil {
            rows.append(SessionInfoHistoryRow(
                id: 0,
                kind: .started,
                title: "Started " + configuration(initial),
                observedAt: initial.observedAt,
                isInferred: initial.provenance == .inferredFirstObservation,
                blockIndex: anchors.first?.block))
        }
        for (offset, change) in telemetry.configurationChanges.enumerated() {
            let field = change.field == .model ? "Model" : "Thinking effort"
            rows.append(SessionInfoHistoryRow(
                id: offset + 1,
                kind: .change,
                title: "\(field) \(change.oldValue ?? "—") → \(change.newValue ?? "—")",
                observedAt: change.observedAt,
                isInferred: false,
                blockIndex: anchorBlockIndex(change: change, anchors: anchors,
                                             blockCount: blocks.count)))
        }
        return rows
    }
```

Note: `configuration(_:)` already exists and returns `"model · effort"` with per-field unavailable text. Leave it alone — Task 6 changes its unavailable strings.

- [ ] **Step 4: Run tests to verify they pass**

```bash
./scripts/xcode_test_stable.sh
```

Expected: PASS, including the four pre-existing marker tests (`testChangesMapByRecordInsteadOfTimestampOrVisibleIndex`, `testChangeAfterFinalMessageHasTrailingAnchor`, and the two `BlockTableController` row tests). If any of those now fail, the refactor changed marker placement — revert and re-derive; the inline markers are shipped behavior.

- [ ] **Step 5: Stage**

```bash
git add AgentSessions/Views/TranscriptTelemetryView.swift AgentSessionsTests/TranscriptTelemetryPresentationTests.swift
```

---

## Task 4: Value formatting — em dashes, two decimals, tooltips

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift:6-38` (`configuration`, `cost`, `weekly`, `tokens`)
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Produces: `TranscriptTelemetryPresentation.Value` (a `text` + `help` pair) and `costValue(_:)`, `weeklyValue(_:)`, `tokensValue(_:)`, `configurationValue(_:)`. Task 6 renders these; nothing else calls the old `cost`/`weekly` string functions afterward.

- [ ] **Step 1: Write the failing test**

```swift
    func testAbsentValuesRenderAsAnEmDashWithTheReasonInHelp() {
        let empty = telemetry(events: [], hasBreakdown: false)
        let weekly = TranscriptTelemetryPresentation.weeklyValue(empty)
        XCTAssertEqual(weekly.text, "—")
        XCTAssertFalse(weekly.help.isEmpty)
        XCTAssertFalse(weekly.text.contains("Unavailable"))
    }

    func testCostShowsTwoDecimalsAndKeepsFullPrecisionInHelp() {
        let estimate = TelemetryCostEstimate(apiEquivalentUSD: 12.3655,
                                             unpricedModels: [], missingPriceComponents: [],
                                             priceTableUpdated: "2026-09-10",
                                             priceTableRevision: 7)
        let session = SessionTelemetry(source: .codex, initialConfiguration: nil,
                                       currentConfiguration: nil, configurationChanges: [],
                                       usageSlices: [], usageEvents: [], usageSummary: nil,
                                       costEstimate: estimate)
        let value = TranscriptTelemetryPresentation.costValue(session)
        XCTAssertEqual(value.text, "$12.37")
        XCTAssertTrue(value.help.contains("12.3655"))
    }

    func testUnpricedModelsAreNamedInHelpNotInTheValue() {
        let estimate = TelemetryCostEstimate(apiEquivalentUSD: nil,
                                             unpricedModels: ["mystery-model"],
                                             missingPriceComponents: [],
                                             priceTableUpdated: "2026-09-10",
                                             priceTableRevision: 7)
        let session = SessionTelemetry(source: .codex, initialConfiguration: nil,
                                       currentConfiguration: nil, configurationChanges: [],
                                       usageSlices: [], usageEvents: [], usageSummary: nil,
                                       costEstimate: estimate)
        let value = TranscriptTelemetryPresentation.costValue(session)
        XCTAssertEqual(value.text, "—")
        XCTAssertTrue(value.help.contains("mystery-model"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./scripts/xcode_test_stable.sh
```

Expected: compile failure — no member `weeklyValue` / `costValue`.

- [ ] **Step 3: Write the implementation**

Inside `TranscriptTelemetryPresentation`:

```swift
    /// A displayable value plus the explanation that belongs in its tooltip.
    /// An absent value is always the em dash — the reason never occupies layout.
    struct Value: Equatable {
        let text: String
        let help: String

        static func absent(_ reason: String) -> Value { Value(text: "—", help: reason) }
    }

    static func costValue(_ telemetry: SessionTelemetry) -> Value {
        if let dollars = telemetry.costEstimate?.apiEquivalentUSD {
            return Value(
                text: dollars.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                help: "API-equivalent estimate at published rates: "
                    + dollars.formatted(.number.precision(.fractionLength(4)))
                    + " USD. Not a subscription charge.")
        }
        let reasons = (telemetry.costEstimate?.unpricedModels ?? [])
            + (telemetry.costEstimate?.missingPriceComponents ?? [])
        return .absent(reasons.isEmpty
                       ? "No priceable usage was recorded in this transcript."
                       : "No price entry for: " + reasons.joined(separator: ", "))
    }

    static func weeklyValue(_ telemetry: SessionTelemetry) -> Value {
        if let estimate = telemetry.weeklyQuotaEstimate,
           estimate.status == .estimated, let points = estimate.percentPoints {
            return Value(text: "≈\(points.formatted(.number.precision(.fractionLength(2))))%",
                         help: "Account-calibrated estimate of this session's share of the weekly allowance.")
        }
        return .absent(telemetry.weeklyQuotaEstimate?.unavailableReason
                       ?? "No compatible weekly calibration for this account.")
    }

    static func tokensValue(_ telemetry: SessionTelemetry) -> Value {
        guard let total = tokens(telemetry) else {
            return .absent("This transcript records no usage.")
        }
        return Value(text: total.formatted(), help: "Fresh input, cached input, cache writes and output. Reasoning tokens are counted inside output.")
    }

    static func configurationValue(_ value: SessionConfiguration?) -> Value {
        guard let value, value.model != nil || value.reasoningEffort != nil else {
            return .absent("This transcript records no model or effort setting.")
        }
        return Value(text: configuration(value),
                     help: value.provenance == .inferredFirstObservation
                         ? "Inferred from the first record, not a session-start setting."
                         : "Recorded by the provider.")
    }
```

Change `configuration(_:)` so an absent field reads as an em dash rather than a sentence:

```swift
    static func configuration(_ value: SessionConfiguration?) -> String {
        "\(value?.model ?? "—") · \(value?.reasoningEffort ?? "—")"
    }
```

Leave the old `cost(_:)` and `weekly(_:)` in place for now; Task 6 removes their last call sites and this task's step 4 must still pass with them present.

- [ ] **Step 4: Run tests to verify they pass**

```bash
./scripts/xcode_test_stable.sh
```

Expected: PASS.

- [ ] **Step 5: Stage**

```bash
git add AgentSessions/Views/TranscriptTelemetryView.swift AgentSessionsTests/TranscriptTelemetryPresentationTests.swift
```

---

## Task 5: Panel components

**Files:**
- Create: `AgentSessions/Views/SessionInfoComponents.swift`
- Test (throwaway, deleted in step 6): `AgentSessionsTests/SessionInfoRenderProbe.swift`

**Interfaces:**
- Consumes: `TelemetryTokenShare` (Task 2), `SessionInfoHistoryRow` (Task 3), `TranscriptTelemetryPresentation.Value` (Task 4), `LayoutTokens`
- Produces: `SessionInfoSection`, `SessionInfoRow`, `TokenShareBar`, `SessionInfoHistoryList` — all used by Task 6.

**Before starting: open `docs/superpowers/plans/assets/2026-09-10-session-info-inspector-mockup.html` in a browser.** Sizes and strings below must match it.

- [ ] **Step 1: Create the components file**

```swift
import SwiftUI

/// Small building blocks for the Session info inspector. Sizes come from the
/// locked mockup (docs/superpowers/plans/assets/2026-09-10-session-info-inspector-mockup.html);
/// spacing comes from LayoutTokens; every color is semantic.
enum SessionInfoType {
    static let hero = Font.system(size: 27, weight: .semibold)
    static let subhero = Font.system(size: 14, weight: .semibold)
    static let sectionHead = Font.system(size: 10.5, weight: .semibold)
    static let row = Font.system(size: 11.5)
    static let caption = Font.system(size: 10.5)
}

struct SessionInfoSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            if let title {
                Text(title.uppercased())
                    .font(SessionInfoType.sectionHead)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label/value line: secondary label left, tabular value right. The value is
/// dimmed when it is the em dash, so an absent field reads as absent at a glance.
struct SessionInfoRow: View {
    let label: String
    let value: TranscriptTelemetryPresentation.Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.md) {
            Text(label)
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
            Spacer(minLength: LayoutTokens.sm)
            Text(value.text)
                .font(SessionInfoType.row)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(value.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .help(value.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.text == "—" ? "unavailable" : value.text)")
    }
}

/// Cached / fresh / output as one bar. Segments below 1% keep a hairline width so
/// a real-but-tiny share (output is routinely 0.3%) does not vanish.
struct TokenShareBar: View {
    let share: TelemetryTokenShare

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.xs) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    segment(share.cachedFraction, width: geometry.size.width, color: AnyShapeStyle(Color.secondary.opacity(0.55)))
                    segment(share.freshFraction, width: geometry.size.width, color: AnyShapeStyle(Color.accentColor))
                    segment(share.outputFraction, width: geometry.size.width, color: AnyShapeStyle(Color.orange))
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            HStack(spacing: LayoutTokens.md) {
                legend("Cached", share.cached, AnyShapeStyle(Color.secondary.opacity(0.55)))
                legend("Fresh", share.fresh, AnyShapeStyle(Color.accentColor))
                legend("Output", share.output, AnyShapeStyle(Color.orange))
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        var lines = ["Cached input \(share.cached.formatted()), fresh input \(share.fresh.formatted()), output \(share.output.formatted())."]
        if share.cacheWriteTokens > 0 {
            lines.append("Fresh includes \(share.cacheWriteTokens.formatted()) cache-write tokens.")
        }
        if share.reasoningTokens > 0 {
            lines.append("Output includes \(share.reasoningTokens.formatted()) reasoning tokens.")
        }
        return lines.joined(separator: " ")
    }

    private func segment(_ fraction: Double, width: CGFloat, color: AnyShapeStyle) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: fraction > 0 ? max(1, width * fraction) : 0)
    }

    private func legend(_ name: String, _ tokens: Int, _ color: AnyShapeStyle) -> some View {
        HStack(spacing: LayoutTokens.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(name) \(tokens.formatted(.number.notation(.compactName)))")
                .font(SessionInfoType.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The configuration-change timeline. A row with a resolvable block index is a
/// button that jumps the transcript to that change's inline marker; a row without
/// one (Terminal or JSON mode, or an unmapped record) is static text.
struct SessionInfoHistoryList: View {
    let rows: [SessionInfoHistoryRow]
    let jump: ((Int) -> Void)?

    var body: some View {
        if rows.isEmpty {
            Text("No changes recorded")
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SessionInfoHistoryRow) -> some View {
        let content = HStack(alignment: .top, spacing: LayoutTokens.sm) {
            pip(row)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(SessionInfoType.row)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle(row))
                    .font(SessionInfoType.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: LayoutTokens.xs)
            if jump != nil, row.blockIndex != nil {
                Image(systemName: "arrow.up.forward")
                    .font(SessionInfoType.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, LayoutTokens.sm)
        .contentShape(Rectangle())

        if let jump, let target = row.blockIndex {
            Button { jump(target) } label: { content }
                .buttonStyle(.plain)
                .help("Show this change in the transcript")
        } else {
            content
        }
    }

    private func pip(_ row: SessionInfoHistoryRow) -> some View {
        Circle()
            .strokeBorder(row.kind == .started ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.clear),
                          lineWidth: 1.5)
            .background(Circle().fill(row.kind == .started
                                      ? AnyShapeStyle(Color.clear)
                                      : AnyShapeStyle(Color.accentColor)))
            .frame(width: 7, height: 7)
    }

    private func subtitle(_ row: SessionInfoHistoryRow) -> String {
        let time = row.observedAt.map { AppDateFormatting.transcriptTimestamp($0) } ?? "Time not recorded"
        return row.isInferred ? time + " · inferred" : time
    }
}
```

- [ ] **Step 2: Register the file with Xcode**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Views/SessionInfoComponents.swift AgentSessions/Views
```

Expected: exactly 4 added lines. Verify:

```bash
git diff --stat AgentSessions.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Write the render probe**

Views are verified by rendering to PNG, never by driving the app with screen automation. Create `AgentSessionsTests/SessionInfoRenderProbe.swift`:

```swift
import XCTest
import SwiftUI
@testable import AgentSessions

/// Throwaway visual probe: renders the components to /tmp so a reviewer can look
/// at them. Deleted before the task is committed — it asserts nothing.
final class SessionInfoRenderProbe: XCTestCase {
    @MainActor
    func testRenderComponents() throws {
        let share = TelemetryTokenShare(cached: 17_892_480, fresh: 1_020_423,
                                        output: 56_342, cacheWriteTokens: 0,
                                        reasoningTokens: 23_651)
        let rows = [
            SessionInfoHistoryRow(id: 0, kind: .started, title: "Started gpt-5.6-sol · medium",
                                  observedAt: Date(), isInferred: true, blockIndex: 0),
            SessionInfoHistoryRow(id: 1, kind: .change, title: "Thinking effort medium → high",
                                  observedAt: Date(), isInferred: false, blockIndex: 12)
        ]
        let view = VStack(alignment: .leading, spacing: LayoutTokens.md) {
            TokenShareBar(share: share)
            SessionInfoRow(label: "Model",
                           value: .init(text: "gpt-5.6-sol · high", help: "Recorded."))
            SessionInfoRow(label: "Weekly quota", value: .absent("No calibration."))
            SessionInfoSection(title: "History") {
                SessionInfoHistoryList(rows: rows, jump: { _ in })
            }
        }
        .padding(LayoutTokens.md)
        .frame(width: 296)
        .background(Color(nsColor: .controlBackgroundColor))

        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let data = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            else { return XCTFail("render failed") }
            try png.write(to: URL(fileURLWithPath: "/tmp/session-info-\(scheme).png"))
        }
    }
}
```

Register and run it:

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/SessionInfoRenderProbe.swift AgentSessionsTests
./scripts/xcode_test_stable.sh 2>&1 | tail -20
```

- [ ] **Step 5: Look at the output**

Open `/tmp/session-info-light.png` and `/tmp/session-info-dark.png` and compare against the mockup. Check specifically: the output segment is still visible at 0.3%; the em-dash row is dimmer than the model row; the legend digits are tabular; the pip for "Started" is a ring and the pip for the change is filled; nothing is clipped at 296 pt.

- [ ] **Step 6: Delete the probe**

```bash
git checkout AgentSessions.xcodeproj/project.pbxproj
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Views/SessionInfoComponents.swift AgentSessions/Views
rm AgentSessionsTests/SessionInfoRenderProbe.swift
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | tail -5
```

(The `checkout` + re-add restores the pbxproj to a state carrying only the production file; the build confirms it is intact.)

- [ ] **Step 7: Stage**

```bash
git add AgentSessions/Views/SessionInfoComponents.swift AgentSessions.xcodeproj/project.pbxproj
```

---

## Task 6: Rebuild the panel

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift:66-161` (the whole `TranscriptTelemetryView` struct)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: `TranscriptTelemetryView(telemetry:blocks:loading:isSubagent:jumpToBlock:refresh:close:)`. **Two new parameters** — `blocks: [SessionTranscriptBuilder.LogicalBlock]` and `jumpToBlock: ((Int) -> Void)?`. Task 7 supplies both from `TranscriptPlainView`.

- [ ] **Step 1: Replace the view struct**

Replace everything from `struct TranscriptTelemetryView: View {` to the end of the file:

```swift
struct TranscriptTelemetryView: View {
    let telemetry: SessionTelemetry?
    let blocks: [SessionTranscriptBuilder.LogicalBlock]
    let loading: Bool
    let isSubagent: Bool
    /// nil in Terminal and JSON modes, where there is no block table to scroll.
    let jumpToBlock: ((Int) -> Void)?
    let refresh: () -> Void
    let close: () -> Void

    @AppStorage("SessionInfoBasisExpanded") private var basisExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.md) {
                    if let telemetry {
                        summary(telemetry)
                        Divider()
                        facts(telemetry)
                        Divider()
                        history(telemetry)
                        Divider()
                        basis(telemetry)
                    } else {
                        Text(loading
                             ? "Loading session information…"
                             : "No supported telemetry, or the transcript could not be read.")
                            .font(SessionInfoType.row)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(LayoutTokens.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Session info").font(.headline)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Hide Session info (⇧⌘I)")
        }
        .padding(LayoutTokens.md)
    }

    private var footer: some View {
        HStack {
            Text("Estimates, not billing")
                .font(SessionInfoType.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh", action: refresh)
                .buttonStyle(.link)
                .font(SessionInfoType.row)
                .disabled(loading)
        }
        .padding(.horizontal, LayoutTokens.md)
        .padding(.vertical, LayoutTokens.sm)
    }

    /// One hero (cost) and one subhero (tokens). Two large numbers read as two
    /// competing answers; the token count explains the cost, so it sits under it.
    private func summary(_ telemetry: SessionTelemetry) -> some View {
        let cost = TranscriptTelemetryPresentation.costValue(telemetry)
        let tokens = TranscriptTelemetryPresentation.tokensValue(telemetry)
        let share = TranscriptTelemetryPresentation.tokenShare(telemetry)
        let requests = telemetry.usageEvents.filter { $0.ownership == .session }.count
        return VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.sm) {
                Text(cost.text)
                    .font(SessionInfoType.hero)
                    .monospacedDigit()
                    .foregroundStyle(cost.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text("API-equivalent")
                    .font(SessionInfoType.caption)
                    .foregroundStyle(.secondary)
            }
            .help(cost.help)

            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: LayoutTokens.xs) {
                    Text(tokens.text)
                        .font(SessionInfoType.subhero)
                        .monospacedDigit()
                        .foregroundStyle(tokens.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text("tokens")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if requests > 0 {
                    Text("\(requests) request\(requests == 1 ? "" : "s")")
                        .font(SessionInfoType.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help(tokens.help)

            if let share {
                TokenShareBar(share: share)
            }
        }
    }

    private func facts(_ telemetry: SessionTelemetry) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.xs) {
            SessionInfoRow(label: isSubagent ? "Subagent model" : "Model",
                           value: TranscriptTelemetryPresentation.configurationValue(telemetry.currentConfiguration))
            SessionInfoRow(label: "Weekly quota",
                           value: TranscriptTelemetryPresentation.weeklyValue(telemetry))
            SessionInfoRow(label: "Delegated", value: delegatedValue(telemetry))
        }
    }

    private func delegatedValue(_ telemetry: SessionTelemetry) -> TranscriptTelemetryPresentation.Value {
        guard let descendants = telemetry.descendantTopLineTokens else {
            return .absent("This session recorded no delegated work.")
        }
        return .init(text: "\(descendants.formatted()) tokens",
                     help: "Recorded here but excluded from the totals above. Open each subagent for its own configuration and cost.")
    }

    private func history(_ telemetry: SessionTelemetry) -> some View {
        SessionInfoSection(title: "History") {
            SessionInfoHistoryList(
                rows: TranscriptTelemetryPresentation.historyRows(telemetry: telemetry, blocks: blocks),
                jump: jumpToBlock)
        }
    }

    private func basis(_ telemetry: SessionTelemetry) -> some View {
        DisclosureGroup(isExpanded: $basisExpanded) {
            VStack(alignment: .leading, spacing: LayoutTokens.sm) {
                ForEach(Array(TranscriptTelemetryPresentation.pricingBasis(telemetry).enumerated()),
                        id: \.offset) { _, row in
                    SessionInfoRow(label: "Priced as", value: pricedAsValue(row))
                    SessionInfoRow(label: "Region",
                                   value: row.inferenceGeo.map { .init(text: $0, help: "Provider-reported inference region.") }
                                       ?? .absent("The provider did not record an inference region."))
                    SessionInfoRow(label: "Context in", value: contextValue(row))
                }
                if let cost = telemetry.costEstimate {
                    SessionInfoRow(label: "Price table",
                                   value: .init(text: cost.priceTableUpdated,
                                                help: "Date of the price manifest used."))
                    SessionInfoRow(label: "Revision",
                                   value: .init(text: "r…\(String(String(cost.priceTableRevision).suffix(6)))",
                                                help: "Full revision: \(cost.priceTableRevision)"))
                    SessionInfoRow(label: "Manifest", value: manifestValue(cost))
                }
                if let weekly = telemetry.weeklyQuotaEstimate {
                    SessionInfoRow(label: "Quota source",
                                   value: weekly.sourceFamily.map { .init(text: $0, help: "Which account window the calibration came from.") }
                                       ?? .absent("No quota source recorded."))
                    SessionInfoRow(label: "Calculated",
                                   value: .init(text: weekly.calculatedAt.formatted(date: .abbreviated, time: .shortened),
                                                help: "When this estimate was computed."))
                }
                Text("Cost is computed for each request from its model, speed, region and context size, then summed at published API rates. “Standard” is a pricing assumption, not an observed service tier.")
                    .font(SessionInfoType.caption)
                    .foregroundStyle(.secondary)
                if telemetry.initialConfiguration?.provenance == .inferredFirstObservation {
                    Text("Started configuration is inferred from the first record, not a session-start setting.")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, LayoutTokens.sm)
        } label: {
            Text("How this was estimated")
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
        }
    }

    private func pricedAsValue(_ row: TelemetryPricingBasis) -> TranscriptTelemetryPresentation.Value {
        .init(text: "\(row.model ?? "—") · \(row.speed)",
              help: "\(row.requestCount) request\(row.requestCount == 1 ? "" : "s") priced on this basis.")
    }

    private func contextValue(_ row: TelemetryPricingBasis) -> TranscriptTelemetryPresentation.Value {
        guard let low = row.minContextInputTokens, let high = row.maxContextInputTokens else {
            return .absent("No request recorded its context size.")
        }
        let text = low == high
            ? low.formatted(.number.notation(.compactName))
            : "\(low.formatted(.number.notation(.compactName))) – \(high.formatted(.number.notation(.compactName)))"
        return .init(text: text, help: "Context presented to each request: \(low.formatted()) to \(high.formatted()) tokens.")
    }

    private func manifestValue(_ cost: TelemetryCostEstimate) -> TranscriptTelemetryPresentation.Value {
        guard let fingerprint = cost.priceManifestFingerprint else {
            return .absent("No manifest fingerprint recorded.")
        }
        let short = fingerprint.count > 16
            ? "\(fingerprint.prefix(8))…\(fingerprint.suffix(5))"
            : fingerprint
        return .init(text: String(short), help: fingerprint)
    }
}
```

- [ ] **Step 2: Delete the superseded string functions**

Remove `cost(_:)` and `weekly(_:)` from `TranscriptTelemetryPresentation` — Task 4's `costValue` / `weeklyValue` replaced them and nothing else calls them.

```bash
grep -rn "TranscriptTelemetryPresentation.cost(\|TranscriptTelemetryPresentation.weekly(" --include="*.swift" .
```

Expected: no output. If a test references them, update the test to the `Value` API rather than keeping both.

- [ ] **Step 3: Build**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | tail -20
```

Expected: failure at the two `TranscriptTelemetryView(...)` call sites in `TranscriptPlainView.swift:813` — missing `blocks:` and `jumpToBlock:`. Task 7 fixes them.

- [ ] **Step 4: Verify no "Unavailable (" string survives in the panel**

```bash
grep -n "Unavailable (" AgentSessions/Views/TranscriptTelemetryView.swift
```

Expected: no output.

---

## Task 7: Wire the panel to the transcript

**Files:**
- Modify: `AgentSessions/Views/TranscriptPlainView.swift:806-820` (panel construction), `:733-760` (jump-token state), `:1330-1350` (block-list props)
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift:180-240` (props), `:2242-2262` (`seedConsumedJumpTokens`), plus a new intent handler
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionInfoHistoryRow.blockIndex` (Task 3), `BlockTableController.scrollToBlock(_:)` (existing, `TranscriptBlockListView.swift:2223`)
- Produces: `configJumpToken: Int` / `configJumpBlockIndex: Int?` props on `TranscriptBlockListView`, mirroring the existing `eventJumpToken` / `eventJumpID` pair.

- [ ] **Step 1: Write the failing test**

```swift
    func testHistoryRowBlockIndexIsAValidScrollTargetOrNil() {
        // A change past the final block anchors one past the end; the controller
        // widens and no-ops rather than scrolling to a row that does not exist.
        let blocks = [block(0, record: 1)]
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [change(99)]), blocks: blocks)
        XCTAssertEqual(rows.first { $0.kind == .change }?.blockIndex, blocks.count)
    }

    func testHistoryRowsHaveNoJumpTargetWithoutBlocks() {
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [change(3)]), blocks: [])
        XCTAssertNil(rows.first { $0.kind == .change }?.blockIndex)
    }
```

- [ ] **Step 2: Run tests to verify they pass or fail meaningfully**

```bash
./scripts/xcode_test_stable.sh
```

Expected: these two PASS already (Task 3 implemented the behavior) — they are regression pins for the jump contract. If either fails, Task 3's `anchorBlockIndex` is wrong; fix it there before continuing.

- [ ] **Step 3: Add the jump intent to `TranscriptBlockListView`**

Next to the existing `eventJumpToken` / `eventJumpID` props (around `:185-190`):

```swift
    /// Bumped alongside `configJumpBlockIndex` when a Session info history row is
    /// clicked. Token-based for the same reason as the other jump intents: a
    /// Terminal↔Rich remount must not replay a consumed jump.
    var configJumpToken: Int = 0
    var configJumpBlockIndex: Int?
```

In the coordinator's stored state (near `lastConsumedEventJumpToken`, around `:686`):

```swift
    private var lastConsumedConfigJumpToken: Int = 0
```

Extend `seedConsumedJumpTokens` (`:2253`) with a defaulted parameter so existing call sites keep compiling:

```swift
    func seedConsumedJumpTokens(firstPromptJumpToken: Int,
                                eventJumpToken: Int,
                                userPromptIndexJumpToken: Int,
                                roleJumpToken: Int = 0,
                                configJumpToken: Int = 0) {
        lastConsumedFirstPromptJumpToken = firstPromptJumpToken
        lastConsumedEventJumpToken = eventJumpToken
        lastConsumedUserPromptIndexJumpToken = userPromptIndexJumpToken
        lastConsumedRoleJumpToken = roleJumpToken
        lastConsumedConfigJumpToken = configJumpToken
    }
```

Add the handler in the `// MARK: External jump intents (Task 8)` section:

```swift
    /// Route a Session info history-row click into Rich mode. The block index was
    /// already resolved by `TranscriptTelemetryPresentation.historyRows`, using the
    /// same anchoring the inline markers use — so this lands on the marked block,
    /// not near it. `scrollToBlock` widens when the target is outside the window
    /// and no-ops when it cannot be materialised.
    func handleConfigJumpIntent(token: Int, blockIndex: Int?) {
        guard token != lastConsumedConfigJumpToken else { return }
        lastConsumedConfigJumpToken = token
        guard let blockIndex else { return }
        scrollToBlock(blockIndex)
    }
```

Call it from `updateNSView` beside the other jump-intent dispatches (around `:318`), and add `configJumpToken: configJumpToken` to the `seedConsumedJumpTokens` call in `makeNSView` (`:274-280`):

```swift
        controller.handleConfigJumpIntent(token: configJumpToken, blockIndex: configJumpBlockIndex)
```

- [ ] **Step 4: Own the state in `TranscriptPlainView`**

Beside the other `rich*JumpToken` `@State` declarations (around `:733`):

```swift
    // Session info history-row jump. Rich mode only: Terminal and JSON have no
    // block table, so the panel is handed a nil closure there and renders the
    // rows as static text instead of buttons.
    @State private var richConfigJumpToken: Int = 0
    @State private var richConfigJumpBlockIndex: Int?
```

Pass them to the block list (in `blocksTranscriptView`, after `eventJumpID:`):

```swift
            configJumpToken: richConfigJumpToken,
            configJumpBlockIndex: richConfigJumpBlockIndex,
```

- [ ] **Step 5: Update the panel construction**

Replace the `TranscriptTelemetryView(...)` call at `:813`:

```swift
                    TranscriptTelemetryView(
                        telemetry: selectedTelemetry,
                        blocks: derivedState.snapshot.blocks,
                        loading: telemetryLoading,
                        isSubagent: sessionID.flatMap { resolvedSessionForRender(id: $0) }?.isSubagent ?? false,
                        jumpToBlock: viewMode == .blocks ? { index in
                            richConfigJumpBlockIndex = index
                            richConfigJumpToken &+= 1
                        } : nil,
                        refresh: { telemetryRefresh &+= 1 },
                        close: { showSessionInfo = false })
                        .frame(width: min(320, max(200, geometry.size.width * 0.36)))
```

The width cap rises from 300 to 320 to match the mockup.

- [ ] **Step 6: Build and run the suite**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | tail -20
./scripts/xcode_test_stable.sh 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`, all tests pass.

- [ ] **Step 7: Confirm the test-count delta**

```bash
xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult
```

Expected: the total is **13 higher** than the pre-Task-1 baseline (4 + 3 + 4 + 2 new tests, no removals). A smaller number means a test was lost — find it before continuing; per `agents.md`, green with fewer tests is byte-identical to green.

- [ ] **Step 8: Look at the real panel**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-manual build 2>&1 | tail -5
killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app
```

Never launch from `.deriveddata-tests` — a bundle re-signed by `xcodebuild test` launches invisible.

Then check, in both light and dark: a long Codex session shows one "Priced as" row rather than one per request; the cache bar dominates; clicking a history row scrolls the transcript and flashes the marked block; switching to Terminal mode turns the history rows into static text with no `↗`.

- [ ] **Step 9: Stage**

```bash
git add AgentSessions/Views/TranscriptTelemetryView.swift \
        AgentSessions/Views/SessionInfoComponents.swift \
        AgentSessions/Views/TranscriptPlainView.swift \
        AgentSessions/Views/TranscriptBlockListView.swift \
        AgentSessionsTests/TranscriptTelemetryPresentationTests.swift \
        AgentSessions.xcodeproj/project.pbxproj
```

Suggested commit for the owner to run:

```
refactor(transcript): rebuild Session info around one hero and a token share bar

Cost leads at 27pt with the token count as a subhero carrying a
cached/fresh/output bar; configuration history becomes a clickable
timeline that jumps to the inline marker; all provenance collapses into
"How this was estimated". The pricing basis now groups by model, speed
and region instead of context size, which was rendering one row per
request.

Tool: Claude Code
Model: Opus 5
Why: the pane shipped unreadable at real session sizes
```

---

## Task 8: Toolbar entry point — GATED

**Do not start this task until the owner answers the open decision in the spec.** If the answer is "keep the toolbar toggle", skip the task entirely and record that in the plan.

**Files (option A only):**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:1984-1992` (remove the toggle)
- Modify: `AgentSessions/Views/TranscriptPlainView.swift:1446-1470` (add the control beside the ID button)

- [ ] **Step 1: Remove the toolbar toggle**

Delete the `ToolbarIconToggle(isOn: $showSessionInfo, ...)` block at `UnifiedSessionsView.swift:1985` and its `.disabled(!showTranscriptWindow)` modifier. Leave the `showTranscriptWindow` toggle above it untouched.

- [ ] **Step 2: Add the control to the transcript header row**

In `toolbarTopRow`, inside the `HStack(spacing: 10)` that holds the ID button (`TranscriptPlainView.swift:1446`), after the `if let fullID` block:

```swift
                    Button { showSessionInfo.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSessionInfo ? "info.circle.fill" : "info.circle")
                                .imageScale(.medium)
                            Text("Info")
                                .font(TranscriptToolbarStyle.baseFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(showSessionInfo ? "Hide Session info (⇧⌘I)" : "Show Session info (⇧⌘I)")
                    .accessibilityLabel("Session info")
```

- [ ] **Step 3: Build and check both entry points still work**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | tail -5
```

Then launch and confirm: the header Info button toggles the pane, `⇧⌘I` toggles it, and `View ▸ Session info` (`AgentSessionsApp.swift:423`) still reflects the state. All three read the same `@AppStorage("ShowSessionInfo")`, so a break here means a stale local copy of the key.

- [ ] **Step 4: Stage**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift AgentSessions/Views/TranscriptPlainView.swift
```

---

## Self-review notes

- **Spec coverage:** hero/subhero → Task 6 `summary`; share bar → Tasks 2, 5; facts → Task 6 `facts`; history → Tasks 3, 5, 7; provenance group → Tasks 1, 6; copy rules → Task 4 + Task 6 step 4 grep; type contract → Task 5; toolbar → Task 8 (gated).
- **Known deliberate gap:** the jump works in Rich (`.blocks`) mode only. Terminal mode has its own line-based scrolling (`SessionTerminalView.scrollTargetLineID`) and would need a record→line mapping that does not exist yet. The panel degrades honestly — no `↗`, no button — rather than offering a control that does nothing.
- **Naming consistency check:** `TelemetryPricingBasis`, `TelemetryTokenShare`, `SessionInfoHistoryRow`, `TranscriptTelemetryPresentation.Value`, `pricingBasis(_:)`, `tokenShare(_:)`, `historyRows(telemetry:blocks:)`, `anchorBlockIndex(change:anchors:blockCount:)`, `configJumpToken` / `configJumpBlockIndex`, `handleConfigJumpIntent(token:blockIndex:)` — each name appears with the same spelling in every task that references it.
