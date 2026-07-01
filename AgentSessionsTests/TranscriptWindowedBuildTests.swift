import XCTest
@testable import AgentSessions

final class TranscriptWindowedBuildTests: XCTestCase {

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

    /// Alternating user prompt + 3-chunk assistant delta stream, repeated `pairs` times.
    private func deltaSession(pairs: Int) -> Session {
        var events: [SessionEvent] = []
        for p in 0..<pairs {
            events.append(userEvent("u-\(p)", "Question number \(p)\nwith two lines"))
            let mid = "asst-\(p)"
            events.append(assistantDelta("a-\(p)-0", "Answer \(p) chunk-0\n", messageID: mid))
            events.append(assistantDelta("a-\(p)-1", "chunk-1\n", messageID: mid))
            events.append(assistantDelta("a-\(p)-2", "chunk-2", messageID: mid))
        }
        return Session(id: "s-delta", source: .codex, startTime: nil, endTime: nil,
                       model: "test", filePath: "/tmp/delta.jsonl", fileSizeBytes: nil,
                       eventCount: events.count, events: events)
    }

    // MARK: - Parity: a full window equals the matching slice of the whole-session build
    //
    // The global-id parity below only holds when the windowed-build flag is on (flag
    // off, both whole and slice builds use local contiguous ids from 0, so a slice
    // renumbers). Tests branch on the flag so they are correct in either shipped state.

    func testWindowedBuildMatchesWholeSessionBuildForFullWindow() {
        let session = deltaSession(pairs: 50)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertGreaterThan(blocks.count, 20)

        let whole = TerminalBuilder.buildLines(from: blocks, source: session.source, enableReviewCards: true)

        // Build a middle window of whole blocks.
        let range = 10...(blocks.count - 5)
        let windowed = TerminalBuilder.buildLines(from: blocks, blockRange: range,
                                                  source: session.source, enableReviewCards: true)
        XCTAssertFalse(windowed.isEmpty)

        if FeatureFlags.transcriptWindowedBuild {
            // Every windowed line must be byte-identical (id, text, role, blockIndex,
            // eventIndex, decorationGroupID, semanticKind) to the same global line in
            // the whole-session build.
            let wholeByID = Dictionary(uniqueKeysWithValues: whole.map { ($0.id, $0) })
            for line in windowed {
                guard let match = wholeByID[line.id] else {
                    XCTFail("windowed line id \(line.id) not present in whole build")
                    continue
                }
                XCTAssertEqual(line.text, match.text)
                XCTAssertEqual(line.role, match.role)
                XCTAssertEqual(line.blockIndex, match.blockIndex)
                XCTAssertEqual(line.eventIndex, match.eventIndex)
                XCTAssertEqual(line.decorationGroupID, match.decorationGroupID)
                XCTAssertEqual(line.semanticKind, match.semanticKind)
            }
        } else {
            // Flag off: a slice renumbers ids contiguously from 0 (documents why the
            // global-id substrate is needed for windowing).
            XCTAssertEqual(windowed.first?.id, 0)
        }
    }

    // MARK: - Global id stability across prepend (older window built separately)

    func testOlderWindowProducesGloballyDistinctNonOverlappingLineIDs() {
        let session = deltaSession(pairs: 50)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)

        let tail = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 8)
        let older = tail.expandedOlder(blockTarget: 8)
        // The "newly revealed" older slice is older.lowerBlock ..< tail.lowerBlock.
        let olderOnlyRange = older.lowerBlock...(tail.lowerBlock - 1)

        let tailLines = TerminalBuilder.buildLines(from: blocks, blockRange: tail.lowerBlock...tail.upperBlock,
                                                   source: session.source, enableReviewCards: true)
        let olderLines = TerminalBuilder.buildLines(from: blocks, blockRange: olderOnlyRange,
                                                    source: session.source, enableReviewCards: true)
        XCTAssertFalse(tailLines.isEmpty)
        XCTAssertFalse(olderLines.isEmpty)

        if FeatureFlags.transcriptWindowedBuild {
            let tailIDs = Set(tailLines.map(\.id))
            let olderIDs = Set(olderLines.map(\.id))
            // Prepend dedupe relies on disjoint ids between the older slice and the tail.
            XCTAssertTrue(tailIDs.isDisjoint(with: olderIDs),
                          "older + tail windows must not share line ids (prepend would dupe)")
            // And concatenation equals the whole-window build for lowerOlder...tailUpper.
            let combined = TerminalBuilder.buildLines(from: blocks,
                                                      blockRange: older.lowerBlock...tail.upperBlock,
                                                      source: session.source, enableReviewCards: true)
            XCTAssertEqual(olderLines.map(\.id) + tailLines.map(\.id), combined.map(\.id))
        }
    }

    // MARK: - Delta/tool stream is one whole block; window never splits it

    func testAssistantDeltaStreamIsSingleBlockSoWindowCannotSplitIt() {
        let session = deltaSession(pairs: 3)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // Each pair = 1 user block + 1 coalesced assistant block (3 deltas merged).
        XCTAssertEqual(blocks.count, 6)
        let assistantBlocks = blocks.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantBlocks.count, 3)
        // The merged assistant text contains all three chunks — proves coalescing
        // happened, so any block-index window keeps the whole stream intact.
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-0"))
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-1"))
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-2"))
    }
}
