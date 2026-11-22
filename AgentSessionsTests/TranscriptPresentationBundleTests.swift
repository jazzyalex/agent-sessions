import XCTest
@testable import AgentSessions

final class TranscriptPresentationBundleTests: XCTestCase {
    private let settings = TranscriptDerivedState.DerivedSettings(
        skipAgentsPreamble: false,
        reviewCardsEnabled: true,
        includeMessageContext: true)

    @MainActor
    func testKeyChangesForMiddleEditWithSameCountAndFileSize() {
        let originalEvents = (0..<5).map { typedEvent("event-\($0)", "message \($0)") }
        var editedEvents = originalEvents
        editedEvents[2] = typedEvent("event-2", "changed middle message")
        let original = makeSession(id: "same-shape", events: originalEvents, fileSize: 4096)
        let edited = makeSession(id: "same-shape", events: editedEvents, fileSize: 4096)

        XCTAssertEqual(original.events.count, edited.events.count)
        XCTAssertEqual(original.fileSizeBytes, edited.fileSizeBytes)
        XCTAssertNotEqual(
            TranscriptDerivedState.Key(session: original, settings: settings),
            TranscriptDerivedState.Key(session: edited, settings: settings))
    }

    @MainActor
    func testKeyChangesWhenSameCountSessionBecomesFullyHydrated() {
        let events = (0..<4).map { typedEvent("event-\($0)", "message \($0)") }
        var provisional = makeSession(id: "hydration", events: events, fileSize: 2048)
        provisional.isPartiallyHydrated = true
        var full = provisional
        full.isPartiallyHydrated = false

        XCTAssertEqual(provisional.contentRevision, full.contentRevision)
        XCTAssertEqual(provisional.events.count, full.events.count)
        XCTAssertEqual(provisional.fileSizeBytes, full.fileSizeBytes)
        XCTAssertNotEqual(
            TranscriptDerivedState.Key(session: provisional, settings: settings),
            TranscriptDerivedState.Key(session: full, settings: settings))
    }

    @MainActor
    func testSameCountTimestampAndPairingRefreshUsesNewSnapshotTiming() throws {
        func events(callID: String, base: Double, resultOffset: Double, answerOffset: Double) -> [SessionEvent] {
            [
                timedUserEvent("prompt", "do the work", at: base),
                timedAssistantEvent("note", "working", at: base + 1),
                timedToolCallEvent("call", callID: callID, at: base + 2),
                timedToolResultEvent("result", callID: callID,
                                     output: "Process exited with code 0\nOutput:\ndone",
                                     at: resultOffset),
                timedAssistantEvent("answer", "finished", at: answerOffset)
            ]
        }

        let oldSession = makeSession(id: "timing-refresh",
                                     events: events(callID: "old-call", base: 0, resultOffset: 4, answerOffset: 8),
                                     fileSize: 4096)
        let oldKey = TranscriptDerivedState.Key(session: oldSession, settings: settings)
        let oldSnapshot = TranscriptDerivedState.computeSnapshot(session: oldSession, settings: settings)
        let oldInputs = makeInputs(key: oldKey)
        let oldBundle = TranscriptDerivedState.computePresentation(snapshot: oldSnapshot, inputs: oldInputs)
        XCTAssertEqual(oldBundle.snapshot.toolTiming[3]?.durationSeconds, 2)
        XCTAssertEqual(oldBundle.chipAnchors.values.first?.durationSeconds, 8)

        let newSession = makeSession(id: "timing-refresh",
                                     events: events(callID: "new-call", base: 100,
                                                    resultOffset: 110, answerOffset: 112),
                                     fileSize: 4096)
        XCTAssertEqual(oldSession.events.count, newSession.events.count)
        XCTAssertEqual(oldSession.fileSizeBytes, newSession.fileSizeBytes)
        let newKey = TranscriptDerivedState.Key(session: newSession, settings: settings)
        XCTAssertNotEqual(oldKey, newKey)
        let newSnapshot = TranscriptDerivedState.computeSnapshot(session: newSession, settings: settings)
        let newInputs = makeInputs(key: newKey)
        let refreshed = TranscriptDerivedState.computePresentation(
            snapshot: newSnapshot, inputs: newInputs, previous: oldBundle, revision: 2)

        XCTAssertEqual(refreshed.snapshot.toolTiming[3]?.durationSeconds, 8,
                       "the replacement call/output pairing and timestamps must be used")
        XCTAssertEqual(refreshed.snapshot.turnTiming[1]?.durationSeconds, 12)
        XCTAssertEqual(refreshed.chipAnchors.values.first?.durationSeconds, 12,
                       "the presented timing chip must come from the replacement snapshot")
    }

    @MainActor
    func testRoleOnlyInputsReuseGroupRevisionAndRecomputeStopsAcrossAllMasks() {
        let events = [
            timedUserEvent("user-1", "first prompt", at: 0),
            timedAssistantEvent("note", "intermediate note", at: 1),
            timedToolCallEvent("failed-call", callID: "failed-1", at: 2),
            timedToolResultEvent("failed-result", callID: "failed-1",
                                 output: "Process exited with code 2\nOutput:\nfailed", at: 4),
            timedAssistantEvent("answer-1", "first answer", at: 6),
            SessionEvent(id: "standalone-error", timestamp: Date(timeIntervalSince1970: 7),
                         kind: .error, role: nil, text: "standalone error",
                         toolName: nil, toolInput: nil, toolOutput: nil,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"),
            timedUserEvent("user-2", "second prompt", at: 9),
            timedAssistantEvent("answer-2", "second answer", at: 11)
        ]
        let session = makeSession(id: "role-only-presentation", events: events)
        let snapshot = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)
        let key = TranscriptDerivedState.Key(session: session, settings: settings)
        let allInputs = makeInputs(key: key)
        let allRoles = TranscriptDerivedState.computePresentation(
            snapshot: snapshot, inputs: allInputs, revision: 40)

        XCTAssertEqual(snapshot.failedInvocationIDs.count, 1)
        XCTAssertEqual(snapshot.errorJumpIDs.count, 2)
        XCTAssertEqual(allRoles.userStops, 2)
        XCTAssertEqual(allRoles.agentStopIDs.count, 3)
        XCTAssertEqual(allRoles.errorStopIDs, snapshot.errorJumpIDs)
        XCTAssertTrue(allRoles.hiddenNotes.isEmpty)

        for mask in 0..<(1 << TranscriptRoleFilter.allCases.count) {
            let active = Set(TranscriptRoleFilter.allCases.enumerated().compactMap { index, role in
                mask & (1 << index) == 0 ? nil : role
            })
            var inputs = allInputs
            inputs.activeRoles = active
            let bundle = TranscriptDerivedState.computePresentation(
                snapshot: snapshot, inputs: inputs, previous: allRoles, revision: 100 + mask)

            let userShown = active.isEmpty || active.contains(.user)
            let assistantShown = active.isEmpty || active.contains(.assistant)
            let toolsShown = active.isEmpty || active.contains(.tools)
            XCTAssertEqual(bundle.userStops, userShown ? 2 : 0, "user stops for role mask \(mask)")
            XCTAssertEqual(bundle.agentStopIDs.count,
                           assistantShown ? (toolsShown ? 3 : 2) : 0,
                           "agent stops for role mask \(mask)")
            XCTAssertEqual(bundle.hiddenNotes,
                           toolsShown ? [] : snapshot.turnIndex.noteBlockIndices,
                           "hidden notes for role mask \(mask)")
            let expectedErrors = toolsShown
                ? snapshot.errorJumpIDs
                : snapshot.errorJumpIDs.filter { !snapshot.failedInvocationIDs.contains($0) }
            XCTAssertEqual(bundle.errorStopIDs, expectedErrors, "error stops for role mask \(mask)")
            XCTAssertEqual(bundle.groups.revision, allRoles.groups.revision,
                           "role-only changes reuse grouping revision for role mask \(mask)")
            XCTAssertEqual(bundle.groups.groupIDByBlock, allRoles.groups.groupIDByBlock,
                           "role-only changes cannot alter group ownership for role mask \(mask)")
        }
    }

    @MainActor
    func testCurrentInputsRejectStaleBundleBeforeReplacementSnapshotLands() {
        let original = makeSession(id: "stale-presentation", events: [
            typedEvent("one", "first prompt"),
            typedEvent("two", "second prompt")
        ], fileSize: 2048)
        var changedEvents = original.events
        changedEvents[1] = typedEvent("two", "replacement prompt")
        let replacement = makeSession(id: "stale-presentation", events: changedEvents, fileSize: 2048)
        let originalKey = TranscriptDerivedState.Key(session: original, settings: settings)
        let replacementKey = TranscriptDerivedState.Key(session: replacement, settings: settings)
        XCTAssertNotEqual(originalKey, replacementKey)

        let state = TranscriptDerivedState()
        state.update(session: original, settings: settings)
        spin { !state.isComputing }
        XCTAssertEqual(state.snapshot.key, originalKey)
        let originalInputs = makeInputs(key: originalKey)
        state.preparePresentation(originalInputs)
        spin { state.presentation(matching: originalInputs) != nil }
        XCTAssertNotNil(state.presentation(matching: originalInputs))

        let replacementInputs = makeInputs(key: replacementKey)
        state.preparePresentation(replacementInputs)

        XCTAssertEqual(state.snapshot.key, originalKey, "the replacement snapshot has not landed yet")
        XCTAssertEqual(state.presentationBundle?.inputs, originalInputs,
                       "the published bundle is still the old snapshot at this point")
        XCTAssertNil(state.presentation(matching: replacementInputs),
                     "current inputs must not expose the stale published bundle")
        XCTAssertNil(state.presentation(matching: originalInputs),
                     "the previous inputs are no longer current either")
    }

    @MainActor
    func testPresentationInputsInvalidateForContextTelemetryImagesAndLocale() {
        let repeated = typedBlock("repeat", eventIndex: 0)
        let context = contextBlock("environment", eventIndex: 1)
        let blocks = [repeated, context, typedBlock("repeat", eventIndex: 2)]
        let session = makeSession(id: "presentation-inputs", events: [
            typedEvent("a", "repeat"),
            typedEvent("context", "environment"),
            typedEvent("b", "repeat")
        ])
        let key = TranscriptDerivedState.Key(session: session, settings: settings)
        let snapshot = makeSnapshot(blocks: blocks, key: key)
        let base = makeInputs(key: key)
        let baseBundle = TranscriptDerivedState.computePresentation(snapshot: snapshot, inputs: base)
        XCTAssertEqual(baseBundle.userStops, 1, "hidden context leaves the repeated typed prompts adjacent")

        var contextInputs = base
        contextInputs.showsContext = true
        XCTAssertNotEqual(base, contextInputs)
        let contextBundle = TranscriptDerivedState.computePresentation(snapshot: snapshot, inputs: contextInputs)
        XCTAssertEqual(contextBundle.userStops, 2, "visible context separates the repeated typed prompts")

        var telemetryInputs = base
        telemetryInputs.configurationChanges = [ConfigurationChange(
            field: .model,
            oldValue: "old-model",
            newValue: "new-model",
            observedAt: nil,
            anchorLine: 2,
            provenance: .providerChangeRecord)]
        XCTAssertNotEqual(base, telemetryInputs)
        let telemetryBundle = TranscriptDerivedState.computePresentation(snapshot: snapshot, inputs: telemetryInputs)
        XCTAssertEqual(telemetryBundle.markers[2]?.count, 1)
        XCTAssertEqual(telemetryBundle.userStops, 2, "a telemetry marker separates the repeated typed prompts")

        var imageInputs = base
        imageInputs.imageBlocks = [2]
        XCTAssertNotEqual(base, imageInputs)
        let imageBundle = TranscriptDerivedState.computePresentation(snapshot: snapshot, inputs: imageInputs)
        XCTAssertEqual(imageBundle.userStops, 2, "an image block remains a separate typed stop")

        var localeInputs = telemetryInputs
        localeInputs.localeIdentifier = "fr_FR"
        XCTAssertNotEqual(telemetryInputs, localeInputs)
        let localeBundle = TranscriptDerivedState.computePresentation(snapshot: snapshot, inputs: localeInputs)
        XCTAssertEqual(localeBundle.inputs.localeIdentifier, "fr_FR")
    }

    @MainActor
    func testPreparePresentationPublishesOnlyLatestABAGeneration() {
        let events = (0..<8).map { typedEvent("event-\($0)", "message \($0)") }
        let session = makeSession(id: "presentation-aba", events: events)
        let state = TranscriptDerivedState()
        state.update(session: session, settings: settings)
        spin { !state.isComputing }
        XCTAssertFalse(state.isComputing)

        let key = TranscriptDerivedState.Key(session: session, settings: settings)
        let firstA = makeInputs(key: key)
        var b = firstA
        b.localeIdentifier = "fr_FR"
        state.preparePresentation(firstA)
        state.preparePresentation(b)
        state.preparePresentation(firstA)

        spin { state.presentation(matching: firstA) != nil }
        let published = state.presentation(matching: firstA)
        XCTAssertNotNil(published)
        XCTAssertNil(state.presentation(matching: b), "the superseded B request cannot be observed")
        XCTAssertEqual(published?.inputs, firstA)
        XCTAssertEqual(published?.groups.revision, 4, "snapshot landing plus A/B/A advances one publication generation each")
    }

    @MainActor
    func testAppendExtensionMatchesFreshGroupBuild() {
        let oldEvents = (0..<12).map { typedEvent("old-\($0)", "same message") }
        let newEvents = (0..<14).map { typedEvent("new-\($0)", "same message") }
        let oldSession = makeSession(id: "group-append", events: oldEvents, fileSize: 1200)
        let newSession = makeSession(id: "group-append", events: newEvents, fileSize: 1400)
        let oldKey = TranscriptDerivedState.Key(session: oldSession, settings: settings)
        let newKey = TranscriptDerivedState.Key(session: newSession, settings: settings)
        let oldBlocks = (0..<12).map { typedBlock("same message", eventIndex: $0) }
        let newBlocks = (0..<14).map { typedBlock("same message", eventIndex: $0) }
        let oldSnapshot = makeSnapshot(blocks: oldBlocks, key: oldKey)
        let newSnapshot = makeSnapshot(blocks: newBlocks, key: newKey)
        let oldInputs = makeInputs(key: oldKey)
        let newInputs = makeInputs(key: newKey)
        let previous = TranscriptDerivedState.computePresentation(snapshot: oldSnapshot, inputs: oldInputs)

        let extended = TranscriptDerivedState.computePresentation(
            snapshot: newSnapshot,
            inputs: newInputs,
            previous: previous,
            revision: 2)
        let fresh = TranscriptMessageGroupIndex.build(
            blocks: newSnapshot.blocks[...],
            source: newSnapshot.source,
            showsContext: newInputs.showsContext,
            markers: extended.markers,
            noncollapsibleBlockIndices: newInputs.imageBlocks)

        XCTAssertEqual(extended.groups.groupIDByBlock, fresh.groupIDByBlock)
        XCTAssertEqual(Set(extended.groups.groupsByID.keys), Set(fresh.groupsByID.keys))
        for id in fresh.groupsByID.keys {
            XCTAssertEqual(extended.groups.groupsByID[id]?.block, fresh.groupsByID[id]?.block)
            XCTAssertEqual(extended.groups.groupsByID[id]?.representedBlockIndices,
                           fresh.groupsByID[id]?.representedBlockIndices)
        }
    }

    @MainActor
    func testUserStopsProjectConsistentlyAcrossEveryRoleMask() {
        let blocks = [
            typedBlock("first", eventIndex: 0),
            ordinaryBlock(.assistant, "assistant", eventIndex: 1),
            typedBlock("second", eventIndex: 2),
            ordinaryBlock(.toolCall, "tool", eventIndex: 3),
            ordinaryBlock(.error, "error", eventIndex: 4)
        ]
        let session = makeSession(id: "role-mask-stops", events: (0..<5).map {
            typedEvent("event-\($0)", "event \($0)")
        })
        let key = TranscriptDerivedState.Key(session: session, settings: settings)
        let bundle = TranscriptDerivedState.computePresentation(
            snapshot: makeSnapshot(blocks: blocks, key: key),
            inputs: makeInputs(key: key))
        XCTAssertEqual(bundle.userStops, 2)

        for mask in 0..<(1 << TranscriptRoleFilter.allCases.count) {
            let active = Set(TranscriptRoleFilter.allCases.enumerated().compactMap { index, role in
                mask & (1 << index) == 0 ? nil : role
            })
            let raw = active.map(\.rawValue).sorted().joined(separator: ",")
            let parsed = SessionRoleFilters.parsed(raw)
            XCTAssertEqual(parsed, active, "role mask \(mask)")
            let projected = parsed.isEmpty || parsed.contains(.user) ? bundle.userStops : 0
            let expected = active.isEmpty || active.contains(.user) ? 2 : 0
            XCTAssertEqual(projected, expected, "role mask \(mask)")
        }
    }

    @MainActor
    private func spin(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private func makeSession(id: String, events: [SessionEvent], fileSize: Int? = 1000) -> Session {
        Session(id: id, source: .codex, startTime: nil, endTime: nil, model: "test",
                filePath: "/tmp/\(id).jsonl", fileSizeBytes: fileSize,
                eventCount: events.count, events: events)
    }

    @MainActor
    private func makeInputs(key: TranscriptDerivedState.Key,
                            showsContext: Bool = false) -> TranscriptDerivedState.PresentationInputs {
        .init(snapshotKey: key, showsContext: showsContext, configurationChanges: [], imageBlocks: [],
              localeIdentifier: "en_US")
    }

    @MainActor
    private func makeSnapshot(blocks: [SessionTranscriptBuilder.LogicalBlock],
                              key: TranscriptDerivedState.Key) -> TranscriptDerivedState.Snapshot {
        var snapshot = TranscriptDerivedState.Snapshot()
        snapshot.blocks = blocks
        snapshot.blockDigests = blocks.indices.map { $0 }
        snapshot.totalBlockCount = blocks.count
        snapshot.source = key.source
        snapshot.key = key
        return snapshot
    }

    @MainActor
    private func typedEvent(_ id: String, _ text: String) -> SessionEvent {
        var event = TranscriptTestFixtures.userEvent(id, text)
        event.messageOrigin = .typed
        return event
    }

    @MainActor
    private func timedUserEvent(_ id: String, _ text: String, at seconds: Double) -> SessionEvent {
        var event = SessionEvent(id: id, timestamp: Date(timeIntervalSince1970: seconds),
                                 kind: .user, role: "user", text: text,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
        event.messageOrigin = .typed
        return event
    }

    @MainActor
    private func timedAssistantEvent(_ id: String, _ text: String, at seconds: Double) -> SessionEvent {
        SessionEvent(id: id, timestamp: Date(timeIntervalSince1970: seconds),
                     kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    @MainActor
    private func timedToolCallEvent(_ id: String, callID: String, at seconds: Double) -> SessionEvent {
        SessionEvent(id: id, timestamp: Date(timeIntervalSince1970: seconds),
                     kind: .tool_call, role: "assistant", text: nil,
                     toolName: "exec_command", toolInput: #"{"cmd":"true"}"#, toolOutput: nil,
                     toolNamespace: nil, toolCallID: callID,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    @MainActor
    private func timedToolResultEvent(_ id: String, callID: String, output: String,
                                      at seconds: Double) -> SessionEvent {
        SessionEvent(id: id, timestamp: Date(timeIntervalSince1970: seconds),
                     kind: .tool_result, role: "tool", text: nil,
                     toolName: nil, toolInput: nil, toolOutput: output,
                     toolNamespace: nil, toolCallID: callID,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    @MainActor
    private func typedBlock(_ body: String, eventIndex: Int) -> SessionTranscriptBuilder.LogicalBlock {
        var block = TranscriptTestFixtures.block(.user, text: body)
        block.globalBlockIndex = eventIndex
        block.eventID = SessionIndexer.eventID(forPath: "/presentation.jsonl", index: eventIndex + 1)
        block.messageOrigin = .typed
        block.presentation = MessagePresentation(origin: .typed, body: body, summary: nil)
        return block
    }

    @MainActor
    private func contextBlock(_ body: String, eventIndex: Int) -> SessionTranscriptBuilder.LogicalBlock {
        var block = TranscriptTestFixtures.block(.user, text: body)
        block.globalBlockIndex = eventIndex
        block.eventID = SessionIndexer.eventID(forPath: "/presentation.jsonl", index: eventIndex + 1)
        block.messageOrigin = .context(kinds: ["environment"])
        block.presentation = MessagePresentation(origin: .context(kinds: ["environment"]), body: body, summary: "Context")
        return block
    }

    @MainActor
    private func ordinaryBlock(_ kind: SessionTranscriptBuilder.LogicalBlock.Kind,
                               _ text: String,
                               eventIndex: Int) -> SessionTranscriptBuilder.LogicalBlock {
        var block = TranscriptTestFixtures.block(kind, text: text)
        block.globalBlockIndex = eventIndex
        block.eventID = SessionIndexer.eventID(forPath: "/presentation.jsonl", index: eventIndex + 1)
        return block
    }
}
