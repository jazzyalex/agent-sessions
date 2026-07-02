import XCTest
@testable import AgentSessions

final class PerfQuickWinsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    // MARK: - Fixtures

    private func userEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func assistantDelta(_ id: String, _ text: String, messageID: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: messageID, parentID: nil, isDelta: true, rawJSON: "{}")
    }

    private func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: "t-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func session(_ events: [SessionEvent], id: String = "s-perf") -> Session {
        Session(id: id, source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    private func metaEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .meta, role: "system", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    // MARK: - Task 1: coalescer delta-merge must be linear, not CoW-quadratic

    func testCoalesceLongDeltaChainIsLinearAndLossless() {
        let chunk = String(repeating: "x", count: 200)
        var events: [SessionEvent] = []
        events.reserveCapacity(20_000)
        for i in 0..<20_000 {
            events.append(assistantDelta("a-\(i)", chunk, messageID: "m-single"))
        }
        let s = session(events)

        let start = Date()
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(blocks.count, 1, "one merge chain must coalesce to one block")
        XCTAssertEqual(blocks[0].text.utf8.count, 20_000 * 200, "no bytes lost in merge")
        XCTAssertEqual(blocks[0].globalBlockIndex, 0)
        XCTAssertEqual(blocks[0].firstEventIndex, 0)
        // Quadratic CoW copies ~40 GB here (minutes); linear is milliseconds.
        XCTAssertLessThan(elapsed, 2.0,
            "coalescing a long delta chain must be linear (CoW append was quadratic)")
    }

    // MARK: - Task 2: error/code detection behavior pins (guard the regex hoist)

    func testToolResultErrorClassificationByExitCodeAndPrefix() {
        let cases: [(output: String, isError: Bool)] = [
            ("exit code: 1\nboom", true),
            ("Exit Code: 0\nfine", false),
            ("exit status 2", true),
            ("[error] failed to fetch", true),
            ("error: no such file", true),
            ("all good\nexit code: 1 mentioned later is ignored", false),
            ("plain output", false)
        ]
        for (index, testCase) in cases.enumerated() {
            let (output, isError) = testCase
            // Distinct session id per case: same event COUNT (1) across iterations would
            // otherwise collide on the (session id, event count, includeMeta) memo cache key
            // and return a stale block from a prior iteration.
            let s = session([toolResultEvent("t1", output: output)], id: "s-perf-errclass-\(index)")
            let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0].isErrorOutput, isError, "output: \(output)")
        }
    }

    func testReadToolNumberedDumpClassifiedAsCode() {
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.semanticKind == .code },
                      "line-numbered read-tool output must render as a code segment")
    }

    // MARK: - Task 3: user-anchor sweep parity with the legacy quadratic scan

    /// Verbatim port of the legacy nearestUserBlockIndex closure, used as the oracle.
    private func legacyNearestUserBlockIndex(idx: Int,
                                             userBlockIndices: [Int],
                                             preamble: Set<Int>) -> Int? {
        let prior = userBlockIndices.filter { $0 <= idx }
        if let preferred = prior.last(where: { !preamble.contains($0) }) ?? prior.last {
            return preferred
        }
        let after = userBlockIndices.filter { $0 > idx }
        if let preferred = after.first(where: { !preamble.contains($0) }) ?? after.first {
            return preferred
        }
        return nil
    }

    func testUserAnchorsMatchLegacySemanticsAcrossRandomizedConfigurations() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let blockCount = Int.random(in: 1...80, using: &generator)
            let userBlockIndices = (0..<blockCount).filter { _ in Bool.random(using: &generator) }
            let preamble = Set(userBlockIndices.filter { _ in Bool.random(using: &generator) })

            let fast = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                     preambleUserBlockIndexes: preamble,
                                                     blockCount: blockCount)
            XCTAssertEqual(fast.count, blockCount)
            for idx in 0..<blockCount {
                XCTAssertEqual(fast[idx],
                               legacyNearestUserBlockIndex(idx: idx,
                                                           userBlockIndices: userBlockIndices,
                                                           preamble: preamble),
                               "idx \(idx), users \(userBlockIndices), preamble \(preamble)")
            }
        }
    }

    func testUserAnchorsEdgeCases() {
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 3),
                       [nil, nil, nil])
        // Block before the first user block anchors forward.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [2],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 4),
                       [2, 2, 2, 2])
        // Non-preamble prior beats a later preamble prior.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [0, 2],
                                                     preambleUserBlockIndexes: [2],
                                                     blockCount: 4),
                       [0, 0, 0, 0])
    }

    // MARK: - Task 4c: toolbar nav index caching must be parity-identical with the old per-call scans

    /// Verbatim port of the old `indicesForRole` per-call scan, used as the oracle.
    private func legacyRoleIndices(allIndices: [Int], visibleLineIDs: Set<Int>) -> [Int] {
        allIndices.filter { visibleLineIDs.contains($0) }
    }

    /// Verbatim port of the old `semanticLineIndices` per-call scan, used as the oracle.
    private func legacySemanticLineIndices(_ kind: SemanticKind, in source: [TerminalLine]) -> [Int] {
        var seenGroups: Set<Int> = []
        var out: [Int] = []
        for line in source {
            guard line.semanticKind == kind else { continue }
            if seenGroups.insert(line.decorationGroupID).inserted {
                out.append(line.id)
            }
        }
        return out.sorted()
    }

    func testRoleNavIndicesFiltersToVisibleIDsAndSorts() {
        let allIndices = [40, 10, 30, 20, 50]
        let visibleIDs: Set<Int> = [10, 20, 40]

        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: allIndices, visibleLineIDs: visibleIDs)

        XCTAssertEqual(result, [10, 20, 40], "must filter to visible ids and return sorted order")
        XCTAssertEqual(result, legacyRoleIndices(allIndices: allIndices, visibleLineIDs: visibleIDs).sorted())
    }

    func testRoleNavIndicesEmptyVisibleSetReturnsEmpty() {
        let allIndices = [1, 2, 3]
        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: allIndices, visibleLineIDs: [])
        XCTAssertEqual(result, [])
    }

    func testRoleNavIndicesEmptyAllIndicesReturnsEmpty() {
        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: [], visibleLineIDs: [1, 2, 3])
        XCTAssertEqual(result, [])
    }

    func testSemanticNavIndicesMatchesLegacyLoopOnCodeFencedToolOutput() {
        // A line-numbered Read-tool dump renders as `.code` semantic lines grouped
        // by decorationGroupID; verify the fast path returns exactly the legacy
        // first-line-per-group, sorted result.
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)

        XCTAssertTrue(lines.contains { $0.semanticKind == .code }, "fixture must actually produce code lines")

        for kind in [SemanticKind.code, .diff, .plan, .reviewSummary] {
            let fast = TranscriptNavIndexBuilder.semanticNavIndices(kind: kind, source: lines)
            let legacy = legacySemanticLineIndices(kind, in: lines)
            XCTAssertEqual(fast, legacy, "kind \(kind) must match legacy per-call scan exactly")
        }
    }

    func testSemanticNavIndicesEmptySourceReturnsEmpty() {
        XCTAssertEqual(TranscriptNavIndexBuilder.semanticNavIndices(kind: .code, source: []), [])
    }

    // MARK: - Task 4b: memo cache for coalesced blocks

    func testCoalescedBlocksCacheReturnsIdenticalResults() {
        let events: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1"),
            metaEvent("meta1", "some meta note")
        ]
        let s = session(events)

        let firstNoMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let secondNoMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        XCTAssertEqual(firstNoMeta, secondNoMeta, "repeated calls with identical args must return identical blocks")

        let withMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: true)
        XCTAssertNotEqual(firstNoMeta, withMeta,
                           "includeMeta:true and includeMeta:false must not collide on the same cache key")

        // Calling back-to-back with alternating includeMeta must still be correct (no stale hit).
        let noMetaAgain = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let withMetaAgain = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: true)
        XCTAssertEqual(noMetaAgain, firstNoMeta)
        XCTAssertEqual(withMetaAgain, withMeta)
    }

    func testCoalescedBlocksCacheInvalidatesOnEventCountChange() {
        let baseEvents: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1")
        ]
        let sessionID = "s-perf-growing"
        let sessionA = session(baseEvents, id: sessionID)
        let firstResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionA, includeMeta: false)

        var grownEvents = baseEvents
        grownEvents.append(userEvent("u2", "a brand new message"))
        let sessionB = session(grownEvents, id: sessionID)
        let secondResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionB, includeMeta: false)

        XCTAssertNotEqual(firstResult, secondResult,
                           "same session id but different event count must NOT reuse the stale cache entry")
        XCTAssertEqual(secondResult.count, firstResult.count + 1,
                       "appended user event must produce an additional block")
        XCTAssertEqual(secondResult.last?.text, "a brand new message")
    }

    func testCoalescedBlocksCacheInvalidatesOnFileSizeChange() {
        let sessionID = "s-perf-samecounter-rewrite"
        let eventsA: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1")
        ]
        let sessionA = Session(id: sessionID, source: .codex, startTime: nil, endTime: nil,
                                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: 100,
                                eventCount: eventsA.count, events: eventsA)
        let firstResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionA, includeMeta: false)

        // Same id, same event COUNT, but the file was rewritten in place (external edit /
        // crash-recovery re-parse) with different content and a different byte size.
        let eventsB: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "completely different text after rewrite", messageID: "m1")
        ]
        let sessionB = Session(id: sessionID, source: .codex, startTime: nil, endTime: nil,
                                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: 999,
                                eventCount: eventsB.count, events: eventsB)
        let secondResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionB, includeMeta: false)

        XCTAssertNotEqual(firstResult, secondResult,
                           "same id and event count but different fileSizeBytes must NOT reuse the stale cache entry")
        XCTAssertEqual(secondResult.last?.text, "completely different text after rewrite",
                        "must reflect the rewritten session's content, not the cached original")
    }

    func testSemanticNavIndicesDedupesByDecorationGroupID() {
        let lines = [
            TerminalLine(id: 1, text: "a", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 7, semanticKind: .code),
            TerminalLine(id: 2, text: "b", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 7, semanticKind: .code),
            TerminalLine(id: 3, text: "c", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 8, semanticKind: .code),
            TerminalLine(id: 4, text: "d", role: .assistant, eventIndex: nil, blockIndex: nil, decorationGroupID: 9, semanticKind: nil)
        ]
        let result = TranscriptNavIndexBuilder.semanticNavIndices(kind: .code, source: lines)
        XCTAssertEqual(result, [1, 3], "only first line id per decorationGroupID should be kept, sorted")
    }
}
