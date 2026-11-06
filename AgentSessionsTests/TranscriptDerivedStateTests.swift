import XCTest
@testable import AgentSessions

final class TranscriptDerivedStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    private func fixtureSession() -> Session {
        TranscriptTestFixtures.makeSyntheticSession(eventCount: 300)
    }

    func testSnapshotParityWithTerminalRebuildResult() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let legacy = SessionTerminalView.buildRebuildResult(
            session: session, skipAgentsPreamble: false, enableReviewCards: true)

        XCTAssertEqual(snap.totalBlockCount, blocks.count)

        // Anchor map moved out of RebuildResult into TranscriptDerivedState.
        // Recompute the expected map from the same primitives buildRebuildResult
        // used (verbatim derivation) so this stays a parity oracle for it.
        // skipAgentsPreamble: false → empty preamble set feeds the anchors.
        let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }
        let anchors = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                    preambleUserBlockIndexes: [],
                                                    blockCount: blocks.count)
        var expectedAnchorMap: [String: Int] = [:]
        for (idx, block) in blocks.enumerated() {
            let targetUserBlockOffset: Int? = block.kind == .user ? idx : anchors[idx]
            guard let targetUserBlockOffset, blocks.indices.contains(targetUserBlockOffset) else { continue }
            expectedAnchorMap[block.eventID] = blocks[targetUserBlockOffset].globalBlockIndex
        }
        XCTAssertEqual(snap.eventIDToAnchorBlockIndex, expectedAnchorMap)
        XCTAssertEqual(snap.preambleUserBlockIndexes, legacy.preambleUserBlockIndexes)
        XCTAssertEqual(snap.userBlockIndices,
                       blocks.indices.filter { blocks[$0].kind == .user }.map { blocks[$0].globalBlockIndex })
        XCTAssertEqual(snap.errorBlockIndices,
                       blocks.indices.filter { blocks[$0].kind == .error }.map { blocks[$0].globalBlockIndex })
        XCTAssertFalse(snap.errorBlockIndices.isEmpty,
                       "error-bearing fixture must actually exercise errorBlockIndices")
    }

    func testSnapshotCarriesInvocationIndexAndFailedIDs() {
        func call(_ id: String, _ callID: String, _ cmd: String) -> SessionEvent {
            SessionEvent(id: id, timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                         toolName: "exec_command", toolInput: #"{"cmd":"\#(cmd)"}"#, toolOutput: nil,
                         toolNamespace: nil, toolCallID: callID,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        }
        func result(_ id: String, _ callID: String, _ output: String) -> SessionEvent {
            SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                         toolName: nil, toolInput: nil, toolOutput: output,
                         toolNamespace: nil, toolCallID: callID,
                         messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
        }
        // 0 user · 1 call k1 · 2 result k1 (exit 2) · 3 call k2 · 4 result k2 · 5 assistant
        let events = [
            TranscriptTestFixtures.userEvent("u1", "build it"),
            call("c1", "k1", "make"),
            result("r1", "k1", "Process exited with code 2\nOutput:\nboom"),
            call("c2", "k2", "ls"),
            result("r2", "k2", "Process exited with code 0\nOutput:\nREADME.md"),
            TranscriptTestFixtures.assistantDelta("a1", "Build failed.", messageID: "m-a1"),
        ]
        let session = Session(id: "derived-invocations", source: .codex, startTime: nil, endTime: nil,
                              model: "test", filePath: "/tmp/derived-invocations.jsonl", fileSizeBytes: nil,
                              eventCount: events.count, events: events)
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)

        XCTAssertEqual(snap.invocationIndex.invocations.map(\.id), [1, 3])
        XCTAssertEqual(snap.invocationIndex.invocations.map(\.outputBlockIndices), [[2], [4]])
        XCTAssertEqual(snap.invocationIndex.invocations.map(\.status), [.failed(exitCode: 2), .success])
        XCTAssertEqual(snap.failedInvocationIDs, [1])
        // Errors stay block-based: a failed tool output is not an `.error` block.
        XCTAssertEqual(snap.errorBlockIndices, [])
        XCTAssertTrue(TranscriptDerivedState.Snapshot().invocationIndex.invocations.isEmpty)
        XCTAssertTrue(TranscriptDerivedState.Snapshot().failedInvocationIDs.isEmpty)
    }

    func testSnapshotKeyDedupe() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let k1 = TranscriptDerivedState.Key(session: session, settings: settings)
        let k2 = TranscriptDerivedState.Key(session: session, settings: settings)
        XCTAssertEqual(k1, k2)
        let other = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: true,
                                                           reviewCardsEnabled: true)
        XCTAssertNotEqual(k1, TranscriptDerivedState.Key(session: session, settings: other))
    }

    func testFindMatchesWholeSession() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)
        let needle = String(snap.blocks.first(where: { !$0.text.isEmpty })!.text.prefix(6))
        let matches = TranscriptDerivedState.computeFindMatches(blocks: snap.blocks, query: needle)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.map(\.ordinal), Array(0..<matches.count))
        // matches sorted by block, then location
        XCTAssertEqual(matches, matches.sorted {
            ($0.globalBlockIndex, $0.rangeInBlockText.location) < ($1.globalBlockIndex, $1.rangeInBlockText.location)
        })
    }

    /// Task: findMatches must hold more than one query at once so alternating
    /// between two queries (⌘F nav vs. unified search) doesn't thrash a
    /// single-slot memo into a permanent miss. A single-slot cache would return
    /// query B's matches (WRONG) after re-asking for query A a second time; this
    /// asserts the correct query-A results still come back post-alternation.
    @MainActor
    func testFindMatchesAlternatingQueriesStayCorrect() {
        let state = TranscriptDerivedState()
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        state.update(session: session, settings: settings)
        let deadline = Date().addingTimeInterval(5)
        while state.isComputing, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(state.isComputing, "snapshot compute should finish within the test deadline")

        let queryA = "Question"
        let queryB = "Answer"
        let matchesA1 = state.findMatches(query: queryA)
        let matchesB1 = state.findMatches(query: queryB)
        // Re-ask A, then B again — with a single-slot memo this second A call
        // would have been evicted by B and would need a rescan; with the bounded
        // multi-entry cache both stay resident. Either way, correctness must hold.
        let matchesA2 = state.findMatches(query: queryA)
        let matchesB2 = state.findMatches(query: queryB)

        XCTAssertFalse(matchesA1.isEmpty)
        XCTAssertFalse(matchesB1.isEmpty)
        XCTAssertEqual(matchesA1, matchesA2)
        XCTAssertEqual(matchesB1, matchesB2)
        XCTAssertNotEqual(matchesA1.map(\.globalBlockIndex), matchesB1.map(\.globalBlockIndex),
                          "sanity: the two queries must actually hit different blocks")
    }

    /// A stale cache key (snapshot changed under a new session) must recompute
    /// rather than returning the old session's matches. Session B has a
    /// deliberately different block count (10 cycles vs. 50) so a cache bug
    /// that keyed on query text ALONE (ignoring the snapshot key) would return
    /// A's match count for B — a divergence this test would catch.
    @MainActor
    func testFindMatchesRecomputesAfterSnapshotKeyChanges() {
        let state = TranscriptDerivedState()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let sessionA = TranscriptTestFixtures.makeSyntheticSession(eventCount: 250, id: "s-a")
        state.update(session: sessionA, settings: settings)
        var deadline = Date().addingTimeInterval(5)
        while state.isComputing, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let matchesInA = state.findMatches(query: "Question")

        let sessionB = TranscriptTestFixtures.makeSyntheticSession(eventCount: 50, id: "s-b")
        state.update(session: sessionB, settings: settings)
        deadline = Date().addingTimeInterval(5)
        while state.isComputing, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let matchesInB = state.findMatches(query: "Question")

        // Same query text, but the snapshot key changed underneath it (different
        // session id + event count) — the cache must key on (snapshotKey, query),
        // not query alone, so this recomputes against session B's smaller block
        // set instead of replaying session A's stale, larger match list.
        XCTAssertFalse(matchesInA.isEmpty)
        XCTAssertFalse(matchesInB.isEmpty)
        XCTAssertNotEqual(matchesInA.count, matchesInB.count)
        XCTAssertEqual(matchesInB.count, sessionB.events.count / 5,
                       "one 'Question' match per 5-event cycle in the smaller session")
    }

    // MARK: - Find on decoded tool text (Task 15)

    /// 0 user · 1 exec_command call · 2 its output (a JSON string literal with escapes) · 3 assistant.
    private func codexToolSession(id: String) -> Session {
        let events = [
            TranscriptTestFixtures.userEvent("u1", "go"),
            SessionEvent(id: "c1", timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                         toolName: "exec_command", toolInput: #"{"cmd":"printf hi"}"#, toolOutput: nil,
                         toolNamespace: nil, toolCallID: "k1",
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"),
            SessionEvent(id: "r1", timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                         toolName: nil, toolInput: nil, toolOutput: #""say \"x\"\nline2 done""#,
                         toolNamespace: nil, toolCallID: "k1",
                         messageID: "m-r1", parentID: nil, isDelta: false, rawJSON: "{}"),
            TranscriptTestFixtures.assistantDelta("a1", "ok", messageID: "m-a1"),
        ]
        return Session(id: id, source: .codex, startTime: nil, endTime: nil,
                       model: "test", filePath: "/tmp/\(id).jsonl", fileSizeBytes: nil,
                       eventCount: events.count, events: events)
    }

    @MainActor
    private func spin(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false, reviewCardsEnabled: true)

    @MainActor
    func testFindRerunsOnceWhenDecodePassCompletes() {
        let gate = DecodeGate()
        defer { gate.open() }
        let state = TranscriptDerivedState(toolSearchStore: ToolSearchTextStore(build: gate.build))
        state.update(session: codexToolSession(id: "decode-rerun"), settings: settings)
        spin { !state.isComputing }
        spin(0.2) { false }   // the pass starts after the snapshot landed, then waits at the gate
        XCTAssertTrue(state.isDecodingToolText, "the pass is still running")

        // A query before the pass ends searches the raw text where nothing is decoded yet.
        let before = state.findMatches(query: "done")
        XCTAssertEqual(before.map(\.space), [.raw])
        XCTAssertEqual(before.first?.globalBlockIndex, 2)
        XCTAssertEqual(state.findComputeCount, 1)
        _ = state.findMatches(query: "done")
        XCTAssertEqual(state.findComputeCount, 1, "cached while the pass runs")
        XCTAssertEqual(state.toolTextGeneration, 0)

        gate.open()
        spin { !state.isDecodingToolText }
        XCTAssertFalse(state.isDecodingToolText)
        XCTAssertEqual(state.toolTextGeneration, 1, "the pass end is announced once")
        let after = state.findMatches(query: "done")
        XCTAssertEqual(after.map(\.space), [.decoded])
        XCTAssertEqual(after.first?.globalBlockIndex, 1, "reported at the invocation's row block")
        XCTAssertEqual(state.findComputeCount, 2, "exactly one recompute after the pass")
        _ = state.findMatches(query: "done")
        XCTAssertEqual(state.findComputeCount, 2)
    }

    @MainActor
    func testOpeningSessionDoesNotWaitForDecodePass() {
        let gate = DecodeGate()
        defer { gate.open() }
        let store = ToolSearchTextStore(build: gate.build)
        let state = TranscriptDerivedState(toolSearchStore: store)
        state.update(session: codexToolSession(id: "decode-open"), settings: settings)
        spin { !state.isComputing }

        // The snapshot is complete and shown while every tool decode is still held back.
        XCTAssertFalse(state.isComputing)
        XCTAssertEqual(state.snapshot.totalBlockCount, 4)
        XCTAssertEqual(state.snapshot.invocationIndex.invocations.map(\.id), [1])
        spin(0.2) { false }
        XCTAssertTrue(state.isDecodingToolText)
        XCTAssertFalse(store.isComplete)
        XCTAssertNil(store.text(forBlock: 1))

        gate.open()
        spin { !state.isDecodingToolText }
        XCTAssertTrue(store.isComplete)
        XCTAssertNotNil(store.text(forBlock: 1))

        // A session switch cancels the pass and drops the decoded text.
        state.update(session: TranscriptTestFixtures.makeSyntheticSession(eventCount: 10, id: "decode-other"),
                     settings: settings)
        XCTAssertNil(store.text(forBlock: 1))
    }
}
