import XCTest
@testable import AgentSessions

final class TranscriptDerivedStateTests: XCTestCase {
    func testPresentationFindUsesUTF16AndSkipsHiddenContext() {
        var typed = TranscriptTestFixtures.block(.user, text: "<user_input>😀 **needle**</user_input>")
        typed.presentation = MessagePresentation(origin: .typed, body: "😀 **needle**", summary: nil)
        var context = TranscriptTestFixtures.block(.user, text: "needle context")
        context.presentation = MessagePresentation(origin: .context(kinds: ["environment"]), body: "needle context", summary: "Context")
        let blocks = TranscriptTestFixtures.sequence([typed, context])
        let hidden = TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "needle", includeMessageContext: true)
        XCTAssertEqual(hidden.count, 1)
        XCTAssertEqual(hidden.first?.space, .presentation)
        XCTAssertEqual(hidden.first?.rangeInBlockText, NSRange(location: 5, length: 6))
        XCTAssertEqual(TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "needle", includeMessageContext: true, showsContext: true).count, 2)
        XCTAssertEqual(TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "needle").first?.rangeInBlockText.location, 17)
    }

    func testProjectionAndParentMetadataAreSnapshotIdentity() {
        var meta = SessionEvent(id: "context", timestamp: nil, kind: .meta, role: nil, text: "environment", toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        meta.messageOrigin = .context(kinds: ["environment"])
        let events = [meta, TranscriptTestFixtures.userEvent("u", "do it")]
        func session(parent: String? = nil, source: SessionSource = .codex) -> Session {
            Session(id: "same-id", source: source, startTime: nil, endTime: nil, model: nil, filePath: "/tmp/same.jsonl", fileSizeBytes: 200, eventCount: events.count, events: events, parentSessionID: parent, subagentType: parent == nil ? nil : "worker")
        }
        let rawSettings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false, reviewCardsEnabled: true)
        let richSettings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false, reviewCardsEnabled: true, includeMessageContext: true)
        let raw = TranscriptDerivedState.computeSnapshot(session: session(), settings: rawSettings)
        let rich = TranscriptDerivedState.computeSnapshot(session: session(), settings: richSettings)
        let child = TranscriptDerivedState.computeSnapshot(session: session(parent: "parent"), settings: richSettings)
        XCTAssertEqual(raw.blocks.count, 1)
        XCTAssertEqual(rich.blocks.count, 2)
        XCTAssertNotEqual(raw.key, rich.key)
        XCTAssertNotEqual(rich.key, child.key)
        XCTAssertNotEqual(rich.key, TranscriptDerivedState.Key(session: session(source: .claude), settings: richSettings))
        XCTAssertEqual(rich.blocks.last?.presentation?.origin, .typed)
        XCTAssertEqual(child.blocks.last?.presentation?.origin, .parentTask)
        XCTAssertEqual(rich.userBlockIndices, [1])
        XCTAssertEqual(child.userBlockIndices, [])
    }

    func testCodexMixedDisplayPreservesInlineImageMarkerNormalization() {
        var event = TranscriptTestFixtures.userEvent("u", "harness context\nlook <image name=[image #1]>")
        event.messageOrigin = .typed
        event.messageDisplayText = "look <image name=[image #1]>"
        let session = Session(id: "mixed-image", source: .codex, startTime: nil, endTime: nil, model: nil, filePath: "/tmp/mixed.jsonl", eventCount: 1, events: [event])
        let snapshot = TranscriptDerivedState.computeSnapshot(session: session, settings: .init(skipAgentsPreamble: false, reviewCardsEnabled: true, includeMessageContext: true))
        XCTAssertEqual(snapshot.blocks.first?.presentation?.body, "look [Image #1]")
        XCTAssertEqual(session.events.first?.text, event.text)
    }

    func testOriginEventJumpsOwnRowsAndChildRepliesUseParentTask() {
        func event(_ id: String, _ origin: MessageOrigin, kind: SessionEventKind = .user) -> SessionEvent {
            var e = SessionEvent(id: id, timestamp: nil, kind: kind, role: nil, text: id, toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
            e.messageOrigin = origin
            return e
        }
        let events = [event("parent", .parentTask), event("peer", .peer(from: "Ada"), kind: .meta), event("context", .context(kinds: ["environment"]), kind: .meta), TranscriptTestFixtures.assistantDelta("reply", "done", messageID: "reply")]
        let session = Session(id: "child-jumps", source: .codex, startTime: nil, endTime: nil, model: nil, filePath: "/tmp/child-jumps.jsonl", eventCount: events.count, events: events)
        let snapshot = TranscriptDerivedState.computeSnapshot(session: session, settings: .init(skipAgentsPreamble: false, reviewCardsEnabled: true, includeMessageContext: true))
        XCTAssertEqual(snapshot.userBlockIndices, [])
        XCTAssertEqual(snapshot.imageUserBlockIndices, [0], "retained meta peer is not an original image-browser user ordinal")
        XCTAssertEqual(snapshot.eventIDToAnchorBlockIndex, ["parent": 0, "peer": 1, "context": 2, "reply": 0])
    }

    @MainActor
    func testSessionPreambleUsesCachedOriginAndKeepsExplicitTypedFirstPrompt() {
        for source in [SessionSource.codex, .droid, .claude] {
            func event(_ id: String, _ body: String, _ origin: MessageOrigin) -> SessionEvent {
                var result = TranscriptTestFixtures.userEvent(id, body)
                result.messageOrigin = origin
                return result
            }
            var retainedMeta = SessionEvent(id: "meta-context", timestamp: nil, kind: .meta, role: nil,
                text: "retained environment", toolName: nil, toolInput: nil, toolOutput: nil,
                messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
            retainedMeta.messageOrigin = .context(kinds: ["environment"])
            let events = [
                event("context", "plain injected environment", .context(kinds: ["environment"])),
                event("typed", "# AGENTS.md instructions for /literal\n<INSTRUCTIONS>These are my words.</INSTRUCTIONS>", .typed),
                event("skill", "loaded skill body", .skill(name: "demo")),
                event("retry", "retry body", .harnessRetry),
                event("peer", "peer body", .peer(from: "other")),
                event("later", "later prompt", .typed), retainedMeta
            ]
            let session = Session(id: "semantic-preamble-" + source.rawValue, source: source,
                                  startTime: nil, endTime: nil, model: nil, filePath: "/tmp/preamble.jsonl",
                                  eventCount: events.count, events: events)
            let snapshot = TranscriptDerivedState.computeSnapshot(session: session,
                settings: .init(skipAgentsPreamble: true, reviewCardsEnabled: true, includeMessageContext: true))
            XCTAssertEqual(snapshot.preambleUserBlockIndexes, [0, 2, 3], source.rawValue)
            XCTAssertEqual(snapshot.userBlockIndices, [1, 5], source.rawValue)
            XCTAssertEqual(BlockTableController.firstPromptBlockIndex(userBlockIndices: snapshot.userBlockIndices,
                preambleUserBlockIndexes: snapshot.preambleUserBlockIndexes), 1, source.rawValue)
            XCTAssertEqual(snapshot.blocks[1].presentation?.body, events[1].text, source.rawValue)
            let unfiltered = TranscriptDerivedState.computeSnapshot(session: session,
                settings: .init(skipAgentsPreamble: false, reviewCardsEnabled: true, includeMessageContext: true))
            XCTAssertTrue(unfiltered.preambleUserBlockIndexes.isEmpty, source.rawValue)
        }
    }

    func testRawSnapshotPreambleRetainsLegacyHeuristicWithExplicitTypedProvenance() {
        for source in [SessionSource.codex, .droid, .claude] {
            var typed = TranscriptTestFixtures.userEvent("typed", "# AGENTS.md instructions for /literal\n<INSTRUCTIONS>Typed literal</INSTRUCTIONS>")
            typed.messageOrigin = .typed
            let events = [typed, TranscriptTestFixtures.userEvent("later", "later prompt")]
            let session = Session(id: "raw-preamble-" + source.rawValue, source: source, startTime: nil,
                                  endTime: nil, model: nil, filePath: "/tmp/raw-preamble.jsonl",
                                  eventCount: events.count, events: events)
            let snapshot = TranscriptDerivedState.computeSnapshot(session: session,
                settings: .init(skipAgentsPreamble: true, reviewCardsEnabled: true))
            XCTAssertEqual(snapshot.preambleUserBlockIndexes,
                SessionTerminalView.computePreambleUserBlockIndexes(session: session, blocks: snapshot.blocks))
            XCTAssertEqual(snapshot.preambleUserBlockIndexes, source == .claude ? [] : [0])
            let unfiltered = TranscriptDerivedState.computeSnapshot(session: session,
                settings: .init(skipAgentsPreamble: false, reviewCardsEnabled: true))
            XCTAssertTrue(unfiltered.preambleUserBlockIndexes.isEmpty)
        }
    }

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

    func testTailRowSummariesMatchTheBuilderAndKeepUnchangedEntries() throws {
        let F = TranscriptTestFixtures.self
        var raw = [F.block(.user, text: "go")]
        for i in 0..<300 {
            raw.append(F.block(.toolCall, id: "t\(i)", toolName: "Bash", toolInput: #"{"command":"echo \#(i)"}"#))
            raw.append(F.block(.toolOut, id: "t\(i)", text: "ok \(i)"))
        }
        let blocks = F.sequence(raw)
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)
        let summaries = TranscriptDerivedState.tailRowSummaries(blocks: blocks, index: index, source: .claude)

        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count,
                                                 blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        let expected = Set((window.lowerBlock...window.upperBlock).compactMap { index.invocationIDByBlock[$0] })
        XCTAssertEqual(Set(summaries.keys), expected)
        XCTAssertLessThan(summaries.count, index.invocations.count, "only the tail window is built")
        for (id, entry) in summaries {
            let ref = try XCTUnwrap(TranscriptToolRows.invocationRef(id: id, in: index))
            XCTAssertEqual(entry.summary, ToolInvocationBuilder.rowSummary(ref, blocks: blocks, index: index, source: .claude))
            XCTAssertEqual(entry.stamp, ToolSearchTextStore.contentStamp(of: ref, blocks: blocks))
            XCTAssertEqual(entry.status, ref.status)
        }

        // A live append keeps an entry whose stamp and status did not change, and rebuilds one
        // whose stamp did.
        let id = try XCTUnwrap(summaries.keys.max())
        var kept = try XCTUnwrap(summaries[id])
        kept.summary.actions = []
        var previous = summaries
        previous[id] = kept
        XCTAssertEqual(TranscriptDerivedState.tailRowSummaries(blocks: blocks, index: index, source: .claude,
                                                               previous: previous)[id], kept)
        var stale = kept
        stale.stamp &+= 1
        previous[id] = stale
        XCTAssertEqual(TranscriptDerivedState.tailRowSummaries(blocks: blocks, index: index, source: .claude,
                                                               previous: previous)[id], summaries[id])
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
        // Jump stops (Task 16): one per invocation; the failed one is the only error stop.
        XCTAssertEqual(snap.toolJumpIDs, [1, 3])
        XCTAssertEqual(snap.errorJumpIDs, [1])
        // L1 summaries of the tail window, built off main (the whole stream is the tail here).
        XCTAssertEqual(Set(snap.rowSummaries.keys), [1, 3])
        XCTAssertEqual(snap.rowSummaries[1]?.status, .failed(exitCode: 2))
        XCTAssertTrue(TranscriptDerivedState.Snapshot().toolJumpIDs.isEmpty)
        XCTAssertTrue(TranscriptDerivedState.Snapshot().errorJumpIDs.isEmpty)
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

    private func codexCall(_ id: String, _ callID: String, _ command: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                     toolName: "exec_command", toolInput: #"{"cmd":"\#(command)"}"#, toolOutput: nil,
                     toolNamespace: nil, toolCallID: callID,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func codexResult(_ id: String, _ callID: String, _ output: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: nil, toolInput: nil, toolOutput: output,
                     toolNamespace: nil, toolCallID: callID,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func codexSession(id: String, _ events: [SessionEvent]) -> Session {
        Session(id: id, source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/\(id).jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    /// 0 user · 1 exec_command call · 2 its output (a JSON string literal with escapes) · 3 assistant.
    /// `appended`: · 4 a second call · 5 its output · 6 assistant (a live append).
    private func codexToolSession(id: String, appended: Bool = false) -> Session {
        var events = [
            TranscriptTestFixtures.userEvent("u1", "go"),
            codexCall("c1", "k1", "printf hi"),
            codexResult("r1", "k1", #""say \"x\"\nline2 done""#),
            TranscriptTestFixtures.assistantDelta("a1", "ok", messageID: "m-a1"),
        ]
        if appended {
            events += [codexCall("c2", "k2", "printf again"),
                       codexResult("r2", "k2", #""done again""#),
                       TranscriptTestFixtures.assistantDelta("a2", "ok", messageID: "m-a2")]
        }
        return codexSession(id: id, events)
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
        let state = TranscriptDerivedState(toolSearchStore: ToolSearchTextStore(build: gate.build), decodesToolText: true)
        state.update(session: codexToolSession(id: "decode-rerun"), settings: settings)
        spin { !state.isComputing }
        XCTAssertFalse(state.isDecodingToolText, "no find-bar label for a pass shorter than 300 ms")
        spin(0.6) { false }   // the pass starts after the snapshot landed, then waits at the gate
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
        let state = TranscriptDerivedState(toolSearchStore: store, decodesToolText: true)
        state.update(session: codexToolSession(id: "decode-open"), settings: settings)
        spin { !state.isComputing }

        // The snapshot is complete and shown while every tool decode is still held back.
        XCTAssertFalse(state.isComputing)
        XCTAssertEqual(state.snapshot.totalBlockCount, 4)
        XCTAssertEqual(state.snapshot.invocationIndex.invocations.map(\.id), [1])
        spin(0.6) { false }
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

    // MARK: - Task 15 fix round 1

    @MainActor
    func testAppendWithFindActiveScansOnce() {
        let store = ToolSearchTextStore()
        let state = TranscriptDerivedState(toolSearchStore: store, decodesToolText: true)
        state.update(session: codexToolSession(id: "decode-append"), settings: settings)
        spin { state.toolTextGeneration == 1 }
        XCTAssertEqual(state.toolTextGeneration, 1, "the opening pass decoded the session")
        XCTAssertEqual(state.findMatches(query: "done").map(\.space), [.decoded])
        let scansBefore = state.findComputeCount

        // A live append with Find open: the new invocation decodes in the snapshot task, so the
        // scan at landing is final and no pass (and no second scan) follows.
        state.update(session: codexToolSession(id: "decode-append", appended: true), settings: settings)
        spin { !state.isComputing }
        let landing = state.findMatches(query: "done")
        XCTAssertEqual(landing.map(\.space), [.decoded, .decoded])
        XCTAssertEqual(landing.map(\.globalBlockIndex), [1, 4])
        spin(0.6) { false }
        _ = state.findMatches(query: "done")
        XCTAssertEqual(state.findComputeCount, scansBefore + 1, "one Find scan per append")
        XCTAssertEqual(state.toolTextGeneration, 1, "no pass ran after the append")
        XCTAssertFalse(state.isDecodingToolText, "the find bar never said Searching")
        XCTAssertTrue(store.isComplete)
    }

    @MainActor
    func testDecodePassStartsAtTheViewportBlock() {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [Int] = []
            func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
            var order: [Int] { lock.lock(); defer { lock.unlock() }; return ids }
        }
        let recorder = Recorder()
        let store = ToolSearchTextStore(build: { ref, blocks, index, source, duration in
            recorder.add(ref.id)
            return ToolInvocationBuilder.build(ref, blocks: blocks, index: index, source: source, duration: duration)
        })
        // 0 user · invocations at 1, 3, …, 19 (call + output each) · 21 assistant.
        var events = [TranscriptTestFixtures.userEvent("u1", "go")]
        for n in 1...10 {
            events += [codexCall("c\(n)", "k\(n)", "printf \(n)"), codexResult("r\(n)", "k\(n)", "\"out \(n)\"")]
        }
        events.append(TranscriptTestFixtures.assistantDelta("a1", "ok", messageID: "m-a1"))
        let state = TranscriptDerivedState(toolSearchStore: store, decodesToolText: true)
        state.toolDecodeViewportProvider = { 9 }
        state.update(session: codexSession(id: "decode-viewport", events), settings: settings)
        spin { state.toolTextGeneration == 1 }
        XCTAssertEqual(state.snapshot.invocationIndex.invocations.map(\.id), Array(stride(from: 1, through: 19, by: 2)))
        XCTAssertEqual(Array(recorder.order.prefix(3)), [9, 11, 7], "nearest the viewport block first")
        XCTAssertEqual(recorder.order.count, 10)
    }

    @MainActor
    func testDecodePassRunsOnlyWhileTheSessionViewAsksForIt() {
        let gate = DecodeGate()
        defer { gate.open() }
        let store = ToolSearchTextStore(build: gate.build)
        let state = TranscriptDerivedState(toolSearchStore: store)   // not in the Session view
        state.update(session: codexToolSession(id: "decode-mode"), settings: settings)
        spin { !state.isComputing }
        spin(0.6) { false }
        XCTAssertFalse(state.isDecodingToolText, "no pass outside the Session view")
        XCTAssertNil(store.text(forBlock: 1))

        state.setDecodesToolText(true)
        spin(0.6) { false }
        XCTAssertTrue(state.isDecodingToolText, "the Session view showed: the pass runs")

        // The view goes away mid-pass: the pass stops and never reports.
        state.setDecodesToolText(false)
        XCTAssertFalse(state.isDecodingToolText)
        gate.open()
        spin(0.5) { false }
        XCTAssertEqual(state.toolTextGeneration, 0)
        XCTAssertNil(store.text(forBlock: 1), "the stopped pass stored nothing")

        // Back in the Session view: it decodes what is missing.
        state.setDecodesToolText(true)
        spin { state.toolTextGeneration == 1 }
        XCTAssertNotNil(store.text(forBlock: 1))
    }
}
