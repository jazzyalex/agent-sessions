import XCTest
@testable import AgentSessions

final class TerminalGlobalIdentityParityTests: XCTestCase {

    // MARK: Fixtures

    private func makeEvent(id: String,
                           kind: SessionEventKind,
                           text: String? = nil,
                           toolName: String? = nil,
                           toolOutput: String? = nil,
                           messageID: String? = nil,
                           isDelta: Bool = false) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: toolName,
                     toolInput: nil,
                     toolOutput: toolOutput,
                     messageID: messageID ?? id,
                     parentID: nil,
                     isDelta: isDelta,
                     rawJSON: "{}")
    }

    private func makeSession(source: SessionSource, events: [SessionEvent]) -> Session {
        Session(id: "s-global",
                source: source,
                startTime: nil,
                endTime: nil,
                model: "test-model",
                filePath: "/tmp/s-global.jsonl",
                fileSizeBytes: nil,
                eventCount: events.count,
                events: events)
    }

    /// Mixed session: two user prompts, assistant deltas that coalesce, a tool
    /// call + output, and an error — enough to exercise every role + a merge.
    private func mixedEvents() -> [SessionEvent] {
        [
            makeEvent(id: "u1", kind: .user, text: "First question"),
            makeEvent(id: "a1", kind: .assistant, text: "Part one ", messageID: "m1", isDelta: true),
            makeEvent(id: "a2", kind: .assistant, text: "part two.", messageID: "m1", isDelta: true),
            makeEvent(id: "tc1", kind: .tool_call, text: "ls -la", toolName: "shell"),
            makeEvent(id: "to1", kind: .tool_result, toolName: "shell", toolOutput: "file.txt\nother.txt"),
            makeEvent(id: "u2", kind: .user, text: "Second question"),
            makeEvent(id: "a3", kind: .assistant, text: "Answer two."),
            makeEvent(id: "er1", kind: .error, text: "boom"),
        ]
    }

    // MARK: Task 3 assertions

    func testCoalesceAssignsContiguousGlobalBlockIndexes() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertFalse(blocks.isEmpty)
        for (offset, block) in blocks.enumerated() {
            XCTAssertEqual(block.globalBlockIndex, offset,
                           "block at offset \(offset) must carry globalBlockIndex == offset")
        }
    }

    func testCoalesceAssignsFirstEventIndexOfMergeChain() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // The merged assistant block (a1+a2) must report the FIRST event's index.
        guard let merged = blocks.first(where: { $0.kind == .assistant && $0.text.contains("Part one") }) else {
            return XCTFail("expected merged assistant block")
        }
        // a1 is events[1] in mixedEvents().
        XCTAssertEqual(merged.firstEventIndex, 1,
                       "merged block firstEventIndex must be the first event in the chain")
    }

    // MARK: Task 4 assertions

    /// Helper: temporarily can't flip a `static let`, so we assert the SHAPE the
    /// builder must produce when the global scheme is active by reading the flag
    /// directly. The flag is compile-time; these assertions branch on it so the
    /// suite is correct whether the flag ships off (today) or on (Phase 4).
    func testBuildLinesGlobalIDsEncodeBlockAndOrdinal() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex)

        XCTAssertFalse(lines.isEmpty)

        if FeatureFlags.transcriptWindowedBuild {
            // Every non-synthetic line's id must decode to its blockIndex, and
            // blockIndex must equal the originating block's globalBlockIndex.
            for line in lines {
                guard let bi = line.blockIndex, bi >= 0 else { continue } // skip synthetic
                guard let decoded = TerminalLineID.globalBlockIndex(from: line.id) else {
                    return XCTFail("real line id \(line.id) failed to decode")
                }
                XCTAssertEqual(decoded, bi,
                               "line id \(line.id) must decode to its blockIndex \(bi)")
            }
            // eventIndex must be populated (non-nil) for every real-block line.
            for line in lines where (line.blockIndex ?? -1) >= 0 {
                XCTAssertNotNil(line.eventIndex, "real-block line must carry eventIndex")
            }
        } else {
            // Today's behavior: ids are 0..N-1 contiguous, eventIndex is nil.
            XCTAssertEqual(lines.map(\.id), Array(0..<lines.count),
                           "with flag off, ids stay contiguous from 0")
            XCTAssertTrue(lines.allSatisfy { $0.eventIndex == nil },
                          "with flag off, eventIndex stays nil")
        }
    }

    func testBuildLinesIDsAreUniqueAndMonotonicEitherWay() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        let ids = lines.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "line ids must be unique")
        // Real (non-synthetic) ids must be strictly increasing in render order.
        let realIDs = lines.filter { ($0.blockIndex ?? -1) >= 0 }.map(\.id)
        for (a, b) in zip(realIDs, realIDs.dropFirst()) {
            XCTAssertLessThan(a, b, "real line ids must increase in render order")
        }
    }

    /// A slice of the block stream must produce the SAME ids/blockIndex for those
    /// blocks as the whole-session build — the core slice-stability property.
    /// (Only meaningful with the flag on; asserted unconditionally as documentation.)
    func testSliceBuildMatchesWholeSessionForSharedBlocks() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        guard blocks.count >= 4 else { return XCTFail("need >= 4 blocks") }

        let whole = TerminalBuilder.buildLines(from: blocks, source: .codex)
        let tailSlice = Array(blocks.suffix(2))
        let tail = TerminalBuilder.buildLines(from: tailSlice, source: .codex)

        if FeatureFlags.transcriptWindowedBuild {
            // For the last two blocks, the slice build must reproduce the exact
            // ids + blockIndex + text the whole build produced for those blocks.
            let lastTwoBlockIndices = Set(tailSlice.map(\.globalBlockIndex))
            let wholeTail = whole.filter { ($0.blockIndex).map(lastTwoBlockIndices.contains) ?? false }
            XCTAssertEqual(tail.map(\.id), wholeTail.map(\.id),
                           "slice build ids must match whole-session ids for shared blocks")
            XCTAssertEqual(tail.map(\.text), wholeTail.map(\.text),
                           "slice build text must match whole-session text for shared blocks")
            XCTAssertEqual(tail.map(\.blockIndex), wholeTail.map(\.blockIndex),
                           "slice build blockIndex must match whole-session for shared blocks")
        } else {
            // With the flag off, a slice build renumbers from 0 — this documents
            // exactly why Phase 2 is needed. Assert the slice DOES start at 0.
            XCTAssertEqual(tail.first?.id, 0, "flag-off slice build renumbers from 0")
        }
    }

    // MARK: Task 5 assertions

    func testImageMapperBlockKeyMatchesGlobalBlockIndexWhenFlagOn() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // userEventIDToBlockKey must map each user block's eventID to the key the
        // renderer will read from line.blockIndex.
        let keyMap = SessionInlineImageMapper.userEventIDToBlockKey(blocks: blocks)
        for block in blocks where block.kind == .user {
            let expected = FeatureFlags.transcriptWindowedBuild ? block.globalBlockIndex : block.globalBlockIndex
            // (Both equal globalBlockIndex here because coalesce assigns
            // globalBlockIndex == offset for a single whole-session build; the
            // point is the mapper keys by globalBlockIndex, not a re-enumeration.)
            XCTAssertEqual(keyMap[block.eventID], expected,
                           "mapper key for user block \(block.eventID) must equal its globalBlockIndex")
        }
    }

    // MARK: Task 6 assertions

    /// Mirror of buildRebuildResult's user-line join, using only public APIs, to
    /// prove the global blockIndex keys resolve consistently. The key assertion:
    /// every user block's globalBlockIndex appears as a line.blockIndex, so the
    /// first-line-of-block lookup the view performs cannot miss.
    func testEveryUserBlockHasAFirstLineUnderGlobalKeys() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex)

        var firstLineForBlock: [Int: Int] = [:]
        for line in lines {
            guard let bi = line.blockIndex, bi >= 0 else { continue }
            if firstLineForBlock[bi] == nil { firstLineForBlock[bi] = line.id }
        }

        for block in blocks where block.kind == .user {
            let key = FeatureFlags.transcriptWindowedBuild ? block.globalBlockIndex : block.globalBlockIndex
            XCTAssertNotNil(firstLineForBlock[key],
                            "user block \(block.eventID) (key \(key)) must have a first line")
        }
    }
}
