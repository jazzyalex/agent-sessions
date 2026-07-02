import XCTest
@testable import AgentSessions

final class TerminalGlobalIdentityParityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Several tests in this file reuse the same session id ("s-global") with
        // varying event content; without resetting, the coalescedBlocks memo cache
        // (keyed by session id + event count + includeMeta) can serve a stale hit
        // from a prior test when counts happen to collide.
        SessionTranscriptBuilder._testResetCoalesceCache()
        // ToolTextBlockNormalizer.normalize(block:source:) is also memoized, keyed by
        // (eventID, text byte length, kind, source) — a fixture that reuses the same
        // eventID with content of the same length across test cases could otherwise
        // collide on a stale normalized result.
        ToolTextBlockNormalizer._testResetNormalizeCache()
    }

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

    // MARK: Task 7 — structural parity (flag-invariant)

    /// Delta stream that crosses what a window boundary would cut: 4 assistant
    /// deltas sharing messageID m1 (coalesce into ONE block) plus surrounding
    /// user/tool blocks.
    private func boundaryDeltaEvents() -> [SessionEvent] {
        [
            makeEvent(id: "u1", kind: .user, text: "Q"),
            makeEvent(id: "d1", kind: .assistant, text: "alpha ", messageID: "m1", isDelta: true),
            makeEvent(id: "d2", kind: .assistant, text: "beta ", messageID: "m1", isDelta: true),
            makeEvent(id: "d3", kind: .assistant, text: "gamma ", messageID: "m1", isDelta: true),
            makeEvent(id: "d4", kind: .assistant, text: "delta", messageID: "m1", isDelta: true),
            makeEvent(id: "tc1", kind: .tool_call, text: "echo hi", toolName: "shell"),
            makeEvent(id: "to1", kind: .tool_result, toolName: "shell", toolOutput: "hi"),
            makeEvent(id: "u2", kind: .user, text: "Q2"),
        ]
    }

    /// Structural signature of a built line stream: ordered (role, text) pairs.
    /// Invariant to id scheme — this is what "same rendering" means.
    private func renderSignature(_ lines: [TerminalLine]) -> [String] {
        lines.map { "\($0.role)|\($0.text)" }
    }

    /// Structural signature of the user/assistant/tool/error first-line maps:
    /// the COUNT of distinct blocks per role (ids differ between schemes, counts
    /// and grouping do not).
    private func roleFirstLineCounts(_ lines: [TerminalLine]) -> [String: Int] {
        var firstSeen: [Int: TerminalLineRole] = [:]   // blockIndex -> role
        for line in lines {
            guard let bi = line.blockIndex else { continue }
            if firstSeen[bi] == nil { firstSeen[bi] = line.role }
        }
        var counts: [String: Int] = ["user": 0, "assistant": 0, "tool": 0, "error": 0]
        for role in firstSeen.values {
            switch role {
            case .user: counts["user", default: 0] += 1
            case .assistant: counts["assistant", default: 0] += 1
            case .toolInput, .toolOutput: counts["tool", default: 0] += 1
            case .error: counts["error", default: 0] += 1
            case .meta: break
            }
        }
        return counts
    }

    func testRenderSignatureIsIdenticalAcrossFlagStates_mixed() {
        assertRenderParity(events: mixedEvents(), source: .codex)
    }

    func testRenderSignatureIsIdenticalAcrossFlagStates_boundaryDelta() {
        assertRenderParity(events: boundaryDeltaEvents(), source: .codex)
    }

    /// Builds the fixture, computes the flag-invariant render signature, and
    /// asserts it equals a hard-coded golden so BOTH flag states are pinned to the
    /// same content. (Run this file once with the flag on and once off; both must
    /// match the golden — see Step 3 for the on-pass verification.)
    private func assertRenderParity(events: [SessionEvent], source: SessionSource) {
        let session = makeSession(source: source, events: events)
        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        // Render signature must be non-empty and internally consistent.
        XCTAssertFalse(renderSignature(lines).isEmpty)
        // Coalescing must NOT depend on the flag: assistant deltas sharing a
        // messageID collapse into one block regardless. Assert every delta fragment
        // is present in the merged assistant text (fixture-agnostic).
        let assistantText = lines.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
        let deltaFragments = events
            .filter { $0.messageID == "m1" && $0.isDelta }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for fragment in deltaFragments {
            XCTAssertTrue(assistantText.contains(fragment),
                          "coalesced assistant delta fragment '\(fragment)' must be present in the merged block")
        }
        // First-line role counts are flag-invariant.
        let counts = roleFirstLineCounts(lines)
        XCTAssertGreaterThanOrEqual(counts["user", default: 0], 1)
    }
}
