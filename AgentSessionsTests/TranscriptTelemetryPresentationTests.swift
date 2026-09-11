import XCTest
@testable import AgentSessions

final class TranscriptTelemetryPresentationTests: XCTestCase {
    func testTelemetryLoadRequestDoesNotTrackSelectionWhileInspectorIsHidden() {
        XCTAssertNil(TranscriptTelemetryLoadRequest.key(
            isVisible: false, selectionKey: "codex|session-a|/tmp/a.jsonl", refresh: 0))
        XCTAssertNil(TranscriptTelemetryLoadRequest.key(
            isVisible: false, selectionKey: "codex|session-b|/tmp/b.jsonl", refresh: 0))
    }

    func testTelemetryLoadRequestTracksVisibleSelectionAndRefresh() {
        XCTAssertEqual(
            TranscriptTelemetryLoadRequest.key(
                isVisible: true, selectionKey: "codex|session-a|/tmp/a.jsonl", refresh: 2),
            "codex|session-a|/tmp/a.jsonl|2"
        )
        XCTAssertNil(TranscriptTelemetryLoadRequest.key(
            isVisible: true, selectionKey: "none", refresh: 2))
    }

    private func block(_ index: Int, record: Int, kind: SessionTranscriptBuilder.LogicalBlock.Kind = .assistant) -> SessionTranscriptBuilder.LogicalBlock {
        .init(kind: kind, text: "Original message \(index)", timestamp: nil, messageID: nil,
              toolName: nil, isDelta: false, toolInput: nil, isErrorOutput: false,
              eventID: SessionIndexer.eventID(forPath: "/test.jsonl", index: record + 1),
              rawJSON: "{}", globalBlockIndex: index, firstEventIndex: index)
    }

    private func change(_ record: Int) -> ConfigurationChange {
        .init(field: .model, oldValue: "sol", newValue: "luna", observedAt: nil,
              anchorLine: record, provenance: .effectiveTurnContext)
    }

    func testReaderAnchorsIncludeClaudeContentSuffixes() {
        let id = SessionIndexer.eventID(forPath: "/test.jsonl", index: 12345)
        XCTAssertEqual(TranscriptTelemetryPresentation.recordIndex(eventID: id + "-p02"), 12344)
        XCTAssertNil(TranscriptTelemetryPresentation.recordIndex(eventID: "event-12345"))
    }

    func testChangesMapByRecordInsteadOfTimestampOrVisibleIndex() {
        let blocks = [block(0, record: 1), block(1, record: 9)]
        let markers = TranscriptTelemetryPresentation.markers(changes: [change(7)], blocks: blocks)
        XCTAssertNil(markers[0])
        XCTAssertEqual(markers[1], ["Model changed: sol → luna"])
    }

    func testChangeAfterFinalMessageHasTrailingAnchor() {
        let markers = TranscriptTelemetryPresentation.markers(changes: [change(10)], blocks: [block(0, record: 1)])
        XCTAssertEqual(markers[1]?.count, 1)
    }

    @MainActor
    func testMarkerSplitsToolGroupAndPreservesBodyIDsAndText() {
        let blocks = [block(0, record: 1, kind: .toolCall), block(1, record: 3, kind: .toolOut)]
        let rows = BlockTableController.rowsWithTelemetry(from: blocks[...], markers: [1: ["Model changed"]],
                                                          totalBlockCount: 2, activeRoles: [])
        XCTAssertEqual(rows.map(\.id), [0, -2, 1])
        XCTAssertEqual(rows[0].primaryBlock, blocks[0])
        XCTAssertEqual(rows[2].primaryBlock, blocks[1])
        XCTAssertTrue(rows[1].isMeta)
        XCTAssertFalse(rows[1].isToolCard)
    }

    @MainActor
    func testRoleFilterKeepsConfigurationMarkers() {
        let blocks = [block(0, record: 1), block(1, record: 4)]
        let rows = BlockTableController.rowsWithTelemetry(from: blocks[...], markers: [1: ["Changed"]],
                                                          totalBlockCount: 2, activeRoles: [.user])
        XCTAssertEqual(rows.map(\.id), [-2])
    }

    @MainActor
    func testWindowingDoesNotRepeatEarlierMarkersOrEmitTailEarly() {
        let blocks = [block(0, record: 1), block(1, record: 4), block(2, record: 7)]
        let markers = [0: ["Before"], 2: ["During"], 3: ["After"]]
        let first = BlockTableController.rowsWithTelemetry(from: blocks[0...1], markers: markers,
                                                           totalBlockCount: 3, activeRoles: [])
        XCTAssertEqual(first.map(\.id), [-1, 0, 1])
        let tail = BlockTableController.rowsWithTelemetry(from: blocks[2...2], markers: markers,
                                                          totalBlockCount: 3, activeRoles: [])
        XCTAssertEqual(tail.map(\.id), [-3, 2, -4])
    }

    func testMissingUsageDoesNotBecomeZero() {
        let telemetry = SessionTelemetry(source: .claude, initialConfiguration: nil, currentConfiguration: nil,
                                         configurationChanges: [], usageSlices: [],
                                         usageSummary: .init(topLineTokens: 0, hasComponentBreakdown: false,
                                                             recordedTotalTokens: nil, usageFamilies: [], usageFamilyConflict: false),
                                         costEstimate: nil)
        XCTAssertNil(TranscriptTelemetryPresentation.tokens(telemetry))
        XCTAssertEqual(TranscriptTelemetryPresentation.costValue(telemetry).text, "—")
        XCTAssertEqual(TranscriptTelemetryPresentation.weeklyValue(telemetry).text, "—")
        XCTAssertEqual(TranscriptTelemetryPresentation.tokensValue(telemetry).text, "—")
        XCTAssertEqual(TranscriptTelemetryPresentation.configurationValue(nil).text, "—")
        // The reason is a tooltip, never layout.
        XCTAssertFalse(TranscriptTelemetryPresentation.weeklyValue(telemetry).help.isEmpty)
    }

    @MainActor
    func testLongMarkersReserveMoreHeightAtNarrowWidth() {
        let text = String(repeating: "Model changed: long-model-name → another-model-name ", count: 3)
        XCTAssertGreaterThan(BlockTableController.telemetryMarkerHeight(text: text, width: 180),
                             BlockTableController.telemetryMarkerHeight(text: text, width: 600))
    }

    /// The history-row jump targets the marker row, which sits ABOVE the anchored
    /// block. If these two ever disagree the jump lands one row low and the change
    /// the user clicked scrolls off the top of the viewport.
    @MainActor
    func testJumpTargetMatchesTheMarkerRowIDNotTheAnchoredBlock() {
        let blocks = [block(0, record: 1), block(1, record: 9)]
        let rows = BlockTableController.rowsWithTelemetry(
            from: blocks[...], markers: [1: ["Model changed"]], totalBlockCount: 2, activeRoles: [])
        let markerRowID = BlockTableController.telemetryMarkerRowID(forBlock: 1)
        XCTAssertEqual(rows.map(\.id), [0, markerRowID, 1])
        XCTAssertLessThan(rows.firstIndex(where: { $0.id == markerRowID })!,
                          rows.firstIndex(where: { $0.id == 1 })!)
    }

    // MARK: - Fixtures for the Session info panel

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

    private func costOnlyTelemetry(_ estimate: TelemetryCostEstimate) -> SessionTelemetry {
        SessionTelemetry(source: .codex, initialConfiguration: nil, currentConfiguration: nil,
                         configurationChanges: [], usageSlices: [], usageEvents: [],
                         usageSummary: nil, costEstimate: estimate)
    }

    // MARK: - Task 1: deduplicated pricing basis

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
        XCTAssertEqual(TranscriptTelemetryPresentation.pricingBasis(telemetry).map(\.model),
                       ["gpt-5.6-sol"])
    }

    func testPricingBasisReportsNoContextRangeWhenNoRequestRecordedOne() {
        let telemetry = telemetry(events: [usageEvent(model: "gpt-5.6-sol", context: nil)])
        let basis = TranscriptTelemetryPresentation.pricingBasis(telemetry)
        XCTAssertNil(basis[0].minContextInputTokens)
        XCTAssertNil(basis[0].maxContextInputTokens)
    }

    // MARK: - Task 2: token share

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
        XCTAssertNil(TranscriptTelemetryPresentation.tokenShare(
            telemetry(events: [usageEvent(model: "x", context: 1)], hasBreakdown: false)))
    }

    func testTokenShareIsUnavailableWhenOnlyDelegatedWorkExists() {
        XCTAssertNil(TranscriptTelemetryPresentation.tokenShare(
            telemetry(events: [usageEvent(model: "x", context: 1, ownership: .descendant)])))
    }

    // MARK: - Task 3: history rows

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
        XCTAssertEqual(rows.first { $0.kind == .change }?.blockIndex, 1)
        XCTAssertEqual(markers.keys.sorted(), [1])
    }

    func testHistoryRowTitleReadsAsAChangeNotAFieldName() {
        let effort = ConfigurationChange(field: .reasoningEffort, oldValue: "medium",
                                         newValue: "high", observedAt: nil, anchorLine: 3,
                                         provenance: .effectiveTurnContext)
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [effort]),
            blocks: [block(0, record: 1), block(1, record: 9)])
        XCTAssertEqual(rows.first { $0.kind == .change }?.title, "Thinking effort medium → high")
    }

    func testHistoryRowsAreEmptyWhenNothingWasRecorded() {
        XCTAssertTrue(TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: []), blocks: []).isEmpty)
    }

    // MARK: - Task 4: value formatting

    func testAbsentValuesRenderAsAnEmDashWithTheReasonInHelp() {
        let weekly = TranscriptTelemetryPresentation.weeklyValue(
            telemetry(events: [], hasBreakdown: false))
        XCTAssertEqual(weekly.text, "—")
        XCTAssertFalse(weekly.help.isEmpty)
        XCTAssertFalse(weekly.text.contains("Unavailable"))
    }

    func testCostShowsTwoDecimalsAndKeepsFullPrecisionInHelp() {
        let value = TranscriptTelemetryPresentation.costValue(costOnlyTelemetry(
            TelemetryCostEstimate(apiEquivalentUSD: 12.3655, unpricedModels: [],
                                  missingPriceComponents: [], priceTableUpdated: "2026-09-10",
                                  priceTableRevision: 7)))
        XCTAssertEqual(value.text, "$12.37")
        XCTAssertTrue(value.help.contains("12.3655"))
    }

    func testUnpricedModelsAreNamedInHelpNotInTheValue() {
        let value = TranscriptTelemetryPresentation.costValue(costOnlyTelemetry(
            TelemetryCostEstimate(apiEquivalentUSD: nil, unpricedModels: ["mystery-model"],
                                  missingPriceComponents: [], priceTableUpdated: "2026-09-10",
                                  priceTableRevision: 7)))
        XCTAssertEqual(value.text, "—")
        XCTAssertTrue(value.help.contains("mystery-model"))
    }

    // MARK: - Task 7: jump-target contract

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

    /// The panel is handed an empty block array while the transcript snapshot
    /// still belongs to a previously selected session. Every row must then be
    /// target-less, so a click cannot resolve into the wrong transcript.
    func testStaleSnapshotYieldsRowsWithNoTargetsAtAll() {
        let started = SessionConfiguration(model: "gpt-5.6-sol", reasoningEffort: "medium",
                                           observedAt: nil, anchorLine: 0,
                                           provenance: .effectiveTurnContext)
        let rows = TranscriptTelemetryPresentation.historyRows(
            telemetry: telemetry(events: [], changes: [change(3), change(9)], initial: started),
            blocks: [])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.blockIndex == nil })
    }
}
