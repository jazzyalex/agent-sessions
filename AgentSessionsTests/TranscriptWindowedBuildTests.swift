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

    /// No messageID/parentID and an empty-of-group-hints rawJSON, so
    /// `ToolTextBlockNormalizer.normalize`'s `groupKey` resolves to nil for both
    /// halves of the pair. That forces the toolOut to inherit its key from the
    /// `lastToolGroupKey` chain (same-tool-name carry-forward from the preceding
    /// toolCall) instead of resolving its own groupKey directly — the realistic
    /// shape of the boundary-fallback case this task's fix can perturb.
    private func toolCallEvent(_ id: String, toolName: String = "shell", input: String = "{\"command\":[\"ls\"]}") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                     toolName: toolName, toolInput: input, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    /// Alternating user + toolCall + toolOut events, repeated `pairs` times. Each
    /// tool pair carries distinct output text so `ToolTextBlockNormalizer.normalize`
    /// does real (non-trivially-empty) work per block, matching the monster-session
    /// hot spot: the tool-group-key pass paying the normalizer per block. See the
    /// toolCallEvent/toolResultEvent doc comment for why groupKey resolution falls
    /// through to the same-tool-name chain (exercising the boundary-fallback path).
    private func toolHeavySession(pairs: Int, id: String = "s-tool-heavy") -> Session {
        var events: [SessionEvent] = []
        events.reserveCapacity(pairs * 3)
        for p in 0..<pairs {
            events.append(userEvent("u-\(p)", "Do thing \(p)"))
            events.append(toolCallEvent("call-\(p)", input: "{\"command\":[\"echo\",\"\(p)\"]}"))
            events.append(toolResultEvent("out-\(p)", output: "line \(p) of output\nexit code: 0"))
        }
        return Session(id: id, source: .codex, startTime: nil, endTime: nil,
                       model: "test", filePath: "/tmp/toolheavy.jsonl", fileSizeBytes: nil,
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

    // MARK: - RebuildResult slice parity (two-stage open substrate)

    func testSliceRebuildResultIsConsistentSubsetOfFullBuild() {
        let session = deltaSession(pairs: 60)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let full = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                          blockRange: nil,
                                                          skipAgentsPreamble: false,
                                                          enableReviewCards: true)
        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 16)
        let slice = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                           blockRange: window.lowerBlock...window.upperBlock,
                                                           skipAgentsPreamble: false,
                                                           enableReviewCards: true)
        XCTAssertFalse(slice.lines.isEmpty)
        XCTAssertLessThan(slice.lines.count, full.lines.count)

        if FeatureFlags.transcriptWindowedBuild {
            // Slice lines are exactly the suffix of the full build (global ids).
            XCTAssertEqual(slice.lines.map(\.id),
                           Array(full.lines.map(\.id).suffix(slice.lines.count)))
            // Role nav indices are full-build entries restricted to windowed line ids.
            let sliceIDs = Set(slice.lines.map(\.id))
            XCTAssertEqual(slice.userLineIndices, full.userLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.assistantLineIndices, full.assistantLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.toolLineIndices, full.toolLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.errorLineIndices, full.errorLineIndices.filter { sliceIDs.contains($0) })
            // Every slice eventID→line entry agrees with the full map.
            for (eventID, lineID) in slice.eventIDToUserLineID {
                XCTAssertEqual(full.eventIDToUserLineID[eventID], lineID, "eventID \(eventID)")
            }
        } else {
            // Flag off: local ids renumber; only structural sanity applies.
            XCTAssertEqual(slice.lines.first?.id, 0)
        }
    }

    func testNilBlockRangeMatchesLegacyEntryPoint() {
        let session = deltaSession(pairs: 20)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let viaBlocks = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                               blockRange: nil,
                                                               skipAgentsPreamble: false,
                                                               enableReviewCards: true)
        let legacy = SessionTerminalView.buildRebuildResult(session: session,
                                                            skipAgentsPreamble: false,
                                                            enableReviewCards: true)
        XCTAssertEqual(viaBlocks.lines.map(\.id), legacy.lines.map(\.id))
        XCTAssertEqual(viaBlocks.lines.map(\.text), legacy.lines.map(\.text))
        XCTAssertEqual(viaBlocks.userLineIndices, legacy.userLineIndices)
        XCTAssertEqual(viaBlocks.eventIDToUserLineID, legacy.eventIDToUserLineID)
    }

    // MARK: - Task 9b: tool-group-key pass clamped to the window (cost fix)

    /// Slice build's tool-group-key pass must only touch windowed blocks. Verifies
    /// behavior stays the documented boundary case: when the window starts ON a
    /// toolOut whose toolCall chain-head sits below the window, the FULL build
    /// grouped that toolOut under the (off-window) toolCall's key — so the group's
    /// chosen nav line lives on a block that isn't in the slice at all, and
    /// filtering full's nav entries down to windowed-line-ids silently drops that
    /// pair. The SLICE build, with fresh chain state at the window's lower bound,
    /// can't see the off-window toolCall either, so the toolOut falls back to its
    /// own stable "tool-block-N" key and gets an independent nav entry. Net effect:
    /// slice has exactly one MORE tool nav entry than full-filtered-to-window — the
    /// boundary toolOut, which full would have silently swallowed. This is the
    /// "degrade to independent, never wrong" contract: the boundary block still
    /// gets a correct, navigable entry; it just isn't merged with an off-window
    /// sibling the slice literally cannot see.
    func testSliceToolGroupKeysComputedOnlyForWindowedBlocks() {
        let session = toolHeavySession(pairs: 60)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertEqual(blocks.count, 180, "3 blocks (user, toolCall, toolOut) per pair")

        let full = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                           blockRange: nil,
                                                           skipAgentsPreamble: false,
                                                           enableReviewCards: true)

        // A window that starts mid-pair, ON a toolOut block, so that toolOut's
        // toolCall chain-head is below the window's lower bound — the exact
        // boundary case the fix's degrade-to-independent semantics documents.
        // Pair p occupies blocks [3p, 3p+1, 3p+2] = [user, toolCall, toolOut].
        // Start the window at the toolOut of pair 40 (block index 3*40+2 = 122).
        let lowerBlock = 122
        let upperBlock = blocks.count - 1
        XCTAssertEqual(blocks[lowerBlock].kind, .toolOut, "window must start ON a toolOut to hit the boundary case")

        let slice = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                            blockRange: lowerBlock...upperBlock,
                                                            skipAgentsPreamble: false,
                                                            enableReviewCards: true)
        XCTAssertFalse(slice.lines.isEmpty)

        guard FeatureFlags.transcriptWindowedBuild else {
            // Flag off: local ids renumber; the global-id subset comparison below
            // doesn't apply. Structural sanity only.
            XCTAssertEqual(slice.lines.first?.id, 0)
            return
        }

        let sliceIDs = Set(slice.lines.map(\.id))
        let fullToolFiltered = full.toolLineIndices.filter { sliceIDs.contains($0) }
        let sliceTool = Set(slice.toolLineIndices)
        let fullToolFilteredSet = Set(fullToolFiltered)

        // Every windowed tool block still gets SOME nav entry in the slice build —
        // the documented boundary case means slice has exactly one MORE entry than
        // full-filtered (the boundary toolOut, which full silently merged into an
        // off-window sibling's group and which therefore vanished on filtering).
        let onlyInFull = fullToolFilteredSet.subtracting(sliceTool)
        let onlyInSlice = sliceTool.subtracting(fullToolFilteredSet)
        XCTAssertEqual(onlyInFull.count, 0,
                       "full-filtered must not contain any entry slice is missing " +
                       "(slice never drops a windowed block's nav entry)")
        XCTAssertEqual(onlyInSlice.count, 1,
                       "exactly the one documented boundary case (the window's lower-bound " +
                       "toolOut) must gain an independent nav entry not present in full-filtered")

        if let divergentSliceLineID = onlyInSlice.first {
            // The extra entry must be the boundary block itself (window's lower
            // bound), and must be its own first line (an independent, ungrouped key).
            let sliceBlockIndex = TerminalLineID.globalBlockIndex(from: divergentSliceLineID)
            XCTAssertEqual(sliceBlockIndex, lowerBlock,
                           "the only block allowed to diverge is the window's lower-bound toolOut")
            XCTAssertEqual(divergentSliceLineID, slice.lines.first?.id,
                           "the boundary toolOut's independent key groups only itself, " +
                           "so its nav line must be the first line of the slice")
        }

        // Sanity: the boundary block's line ID is present in full.lines (whole
        // session) but its FULL-BUILD nav entry (grouped under the off-window
        // toolCall's key) points at a line OUTSIDE the window — confirming why
        // filtering full.toolLineIndices to sliceIDs drops the pair entirely,
        // rather than the pair simply not existing in the full build.
        let boundaryLineID = firstLineID(forGlobalBlockIndex: lowerBlock, in: full.lines)
        XCTAssertNotNil(boundaryLineID, "the boundary block must still produce a line in the full build")
        if let boundaryLineID {
            XCTAssertFalse(full.toolLineIndices.contains(boundaryLineID),
                           "full build must NOT have chosen the boundary toolOut's own line as " +
                           "its group's nav entry (it chose the off-window toolCall's line instead)")
        }
    }

    private func firstLineID(forGlobalBlockIndex blockIndex: Int, in lines: [TerminalLine]) -> Int? {
        lines.first(where: { TerminalLineID.globalBlockIndex(from: $0.id) == blockIndex })?.id
    }

    /// Perf canary: on a large tool-heavy session, the slice build over a small
    /// window must not pay the JSON-heavy normalizer for the whole session. Pre-fix,
    /// the tool-group-key pass iterated ALL blocks; post-fix it's clamped to the
    /// window. 20,000 tool-call/tool-out pairs (60,000 blocks incl. user turns,
    /// close to the 49k-block session that measured 8.6s pre-fix in production)
    /// with a 40-block window is what it takes to meaningfully discriminate on this
    /// machine — at 4,000 pairs (12,000 blocks) the pre-fix pass still finished in
    /// ~0.35s (memoized-normalize + no cache eviction pressure on a fresh, warm
    /// NSCache keeps per-block cost low enough that the 1.0s bar didn't trip).
    func testSliceToolGroupKeyPassIsWindowClampedPerfCanary() {
        ToolTextBlockNormalizer._testResetNormalizeCache()
        let session = toolHeavySession(pairs: 20_000, id: "s-tool-heavy-canary")
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertEqual(blocks.count, 60_000)

        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 40)

        let start = Date()
        let slice = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                            blockRange: window.lowerBlock...window.upperBlock,
                                                            skipAgentsPreamble: false,
                                                            enableReviewCards: true)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(slice.lines.isEmpty)
        XCTAssertLessThan(elapsed, 1.0,
                          "slice build over a 40-block window of a 60,000-block session took \(elapsed)s; " +
                          "the tool-group-key pass must be clamped to the window, not iterate all blocks")
    }

    // MARK: - Stage-2 full-swap threshold policy

    func testFullSwapThresholdPolicy() {
        XCTAssertTrue(SessionTerminalView.shouldSwapToFullBuild(totalChars: 0))
        XCTAssertTrue(SessionTerminalView.shouldSwapToFullBuild(totalChars: FeatureFlags.transcriptFullSwapMaxChars))
        XCTAssertFalse(SessionTerminalView.shouldSwapToFullBuild(totalChars: FeatureFlags.transcriptFullSwapMaxChars + 1))
    }

    // MARK: - Live-tail debounce policy (background throttle)

    func testLiveTailDebounceForegroundUnchanged() {
        XCTAssertEqual(SessionTerminalView.liveTailDebounce(isActive: true), 150_000_000)
    }

    func testLiveTailDebounceBackgroundThrottled() {
        XCTAssertEqual(SessionTerminalView.liveTailDebounce(isActive: false), 5_000_000_000)
    }

    // MARK: - Activation catch-up: forced dispatch bypasses a sleeping pending build

    /// Pins all four force/no-force x pending/completed combinations for
    /// `shouldSkipRebuild`. The activation catch-up's whole fix is expressed in
    /// this pure decision: `force: true` must bypass ONLY the `pending` half of
    /// the guard, never the `lastCompleted` half.
    private func signature(eventCount: Int) -> SessionTerminalView.BuildSignature {
        SessionTerminalView.BuildSignature(sessionID: "s", eventCount: eventCount,
                                           fileSizeBytes: -1, skipAgentsPreamble: false,
                                           reviewCardsEnabled: true)
    }

    func testShouldSkipRebuild_matchesPending_noForce_skips() {
        let sig = signature(eventCount: 10)
        XCTAssertTrue(SessionTerminalView.shouldSkipRebuild(signature: sig, lastCompleted: nil,
                                                            pending: sig, force: false),
                      "an identical sleeping/in-flight build must still block a duplicate non-forced dispatch")
    }

    func testShouldSkipRebuild_matchesPending_force_proceeds() {
        let sig = signature(eventCount: 10)
        XCTAssertFalse(SessionTerminalView.shouldSkipRebuild(signature: sig, lastCompleted: nil,
                                                             pending: sig, force: true),
                       "force must bypass the pending guard so the activation catch-up can supersede a sleeping debounce")
    }

    func testShouldSkipRebuild_matchesLastCompleted_noForce_skips() {
        let sig = signature(eventCount: 10)
        XCTAssertTrue(SessionTerminalView.shouldSkipRebuild(signature: sig, lastCompleted: sig,
                                                            pending: nil, force: false),
                      "truly current content is a no-op without force")
    }

    func testShouldSkipRebuild_matchesLastCompleted_force_stillSkips() {
        let sig = signature(eventCount: 10)
        XCTAssertTrue(SessionTerminalView.shouldSkipRebuild(signature: sig, lastCompleted: sig,
                                                            pending: nil, force: true),
                      "force must NOT bypass the lastCompleted guard — truly current content stays a no-op even when forced")
    }
}
