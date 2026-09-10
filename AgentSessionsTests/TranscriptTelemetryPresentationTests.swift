import XCTest
@testable import AgentSessions

final class TranscriptTelemetryPresentationTests: XCTestCase {
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
        XCTAssertTrue(TranscriptTelemetryPresentation.cost(telemetry).hasPrefix("Unavailable"))
        XCTAssertTrue(TranscriptTelemetryPresentation.weekly(telemetry).hasPrefix("Unavailable"))
        XCTAssertTrue(TranscriptTelemetryPresentation.configuration(nil).contains("model not recorded"))
    }

    @MainActor
    func testLongMarkersReserveMoreHeightAtNarrowWidth() {
        let text = String(repeating: "Model changed: long-model-name → another-model-name ", count: 3)
        XCTAssertGreaterThan(BlockTableController.telemetryMarkerHeight(text: text, width: 180),
                             BlockTableController.telemetryMarkerHeight(text: text, width: 600))
    }
}
