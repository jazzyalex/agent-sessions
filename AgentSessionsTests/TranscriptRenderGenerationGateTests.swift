import XCTest
@testable import AgentSessions

final class TranscriptRenderGenerationGateTests: XCTestCase {
    func testGateAllowsCurrentGenerationAndSession() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertTrue(gate.allowsApply(candidateGeneration: generation,
                                       activeSessionID: "session-1",
                                       expectedSessionID: "session-1"))
    }

    func testGateRejectsStaleGeneration() {
        var gate = TranscriptRenderGenerationGate()
        let staleGeneration = gate.begin()
        _ = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: staleGeneration,
                                        activeSessionID: "session-1",
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsSessionMismatch() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: generation,
                                        activeSessionID: "session-2",
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsWhenActiveSessionIsNil() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: generation,
                                        activeSessionID: nil,
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsPreviousGenerationAfterNewBegin() {
        var gate = TranscriptRenderGenerationGate()
        let firstGeneration = gate.begin()
        let secondGeneration = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: firstGeneration,
                                        activeSessionID: "session-1",
                                        expectedSessionID: "session-1"))
        XCTAssertTrue(gate.allowsApply(candidateGeneration: secondGeneration,
                                       activeSessionID: "session-1",
                                       expectedSessionID: "session-1"))
    }
}

final class UnifiedTableSelectionPolicyTests: XCTestCase {
    func testDoesNotClearSelectionWhileDatasetIsChurning() {
        XCTAssertFalse(
            UnifiedTableSelectionPolicy.shouldClearCanonicalSelectionOnTableDeselection(
                isDatasetChurning: true,
                currentSelectionID: "session-1",
                visibleRowIDs: []
            )
        )
    }

    func testDoesNotClearSelectionWhenRowIsNotVisible() {
        XCTAssertFalse(
            UnifiedTableSelectionPolicy.shouldClearCanonicalSelectionOnTableDeselection(
                isDatasetChurning: false,
                currentSelectionID: "session-1",
                visibleRowIDs: ["session-2"]
            )
        )
    }

    func testClearsSelectionWhenDatasetStableAndRowStillVisible() {
        XCTAssertTrue(
            UnifiedTableSelectionPolicy.shouldClearCanonicalSelectionOnTableDeselection(
                isDatasetChurning: false,
                currentSelectionID: "session-1",
                visibleRowIDs: ["session-1", "session-2"]
            )
        )
    }
}

final class UnifiedRowsStabilityPolicyTests: XCTestCase {
    func testHoldsRowsDuringRunningSearchWhenResultsTransientlyEmpty() {
        XCTAssertTrue(
            UnifiedRowsStabilityPolicy.shouldHoldRowsDuringRunningSearch(
                isSearchRunning: true,
                nextRowsEmpty: true,
                showActiveSessionsOnly: false,
                cachedRowsEmpty: false
            )
        )
    }

    func testDoesNotHoldRowsDuringRunningSearchWhenCacheIsEmpty() {
        XCTAssertFalse(
            UnifiedRowsStabilityPolicy.shouldHoldRowsDuringRunningSearch(
                isSearchRunning: true,
                nextRowsEmpty: true,
                showActiveSessionsOnly: false,
                cachedRowsEmpty: true
            )
        )
    }

    func testHoldsRowsDuringTransientBusyRefreshWhenSelectionExists() {
        XCTAssertTrue(
            UnifiedRowsStabilityPolicy.shouldHoldRowsDuringTransientEmptyRefresh(
                query: "",
                isSearchRunning: false,
                isDatasetChurning: true,
                isIndexing: false,
                nextRowsEmpty: true,
                showActiveSessionsOnly: false,
                cachedRowsEmpty: false,
                hasSelection: true
            )
        )
    }

    func testHoldsRowsDuringIndexingWhenSelectionExists() {
        XCTAssertTrue(
            UnifiedRowsStabilityPolicy.shouldHoldRowsDuringTransientEmptyRefresh(
                query: "",
                isSearchRunning: false,
                isDatasetChurning: false,
                isIndexing: true,
                nextRowsEmpty: true,
                showActiveSessionsOnly: false,
                cachedRowsEmpty: false,
                hasSelection: true
            )
        )
    }

    func testDoesNotHoldRowsForStableTrueEmptyDataset() {
        XCTAssertFalse(
            UnifiedRowsStabilityPolicy.shouldHoldRowsDuringTransientEmptyRefresh(
                query: "",
                isSearchRunning: false,
                isDatasetChurning: false,
                isIndexing: false,
                nextRowsEmpty: true,
                showActiveSessionsOnly: false,
                cachedRowsEmpty: false,
                hasSelection: true
            )
        )
    }
}

final class TranscriptSessionRenderKeyTests: XCTestCase {
    func testRenderKeyChangesWhenEventCountChanges() {
        let base = makeSession(eventCount: 10, events: [makeEvent(id: "e1")], isFavorite: false)
        let updated = makeSession(eventCount: 11, events: [makeEvent(id: "e1")], isFavorite: false)

        XCTAssertNotEqual(
            TranscriptSessionRenderKey.build(for: base),
            TranscriptSessionRenderKey.build(for: updated)
        )
    }

    func testRenderKeyChangesWhenEventsArrayChanges() {
        let base = makeSession(eventCount: 10, events: [makeEvent(id: "e1")], isFavorite: false)
        let updated = makeSession(eventCount: 10, events: [makeEvent(id: "e1"), makeEvent(id: "e2")], isFavorite: false)

        XCTAssertNotEqual(
            TranscriptSessionRenderKey.build(for: base),
            TranscriptSessionRenderKey.build(for: updated)
        )
    }

    func testRenderKeyChangesWhenFavoriteToggles() {
        let unstarred = makeSession(eventCount: 10, events: [makeEvent(id: "e1")], isFavorite: false)
        let starred = makeSession(eventCount: 10, events: [makeEvent(id: "e1")], isFavorite: true)

        XCTAssertNotEqual(
            TranscriptSessionRenderKey.build(for: unstarred),
            TranscriptSessionRenderKey.build(for: starred)
        )
    }

    private func makeSession(eventCount: Int, events: [SessionEvent], isFavorite: Bool) -> Session {
        var session = Session(
            id: "session-1",
            source: .codex,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 100),
            model: "gpt-test",
            filePath: "/tmp/session-1.jsonl",
            fileSizeBytes: 1024,
            eventCount: eventCount,
            events: events
        )
        session.isFavorite = isFavorite
        return session
    }

    private func makeEvent(id: String) -> SessionEvent {
        SessionEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .assistant,
            role: "assistant",
            text: "hello",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
    }
}

final class TranscriptSessionResolutionPolicyTests: XCTestCase {
    func testPrefersCachedWhenLiveSessionIsTransientlyEmpty() {
        let live = makeSession(id: "session-1", events: [])
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e1")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: live,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: true,
            loadingSessionID: "session-1"
        )

        XCTAssertEqual(preferred?.events.count, 1)
        XCTAssertEqual(preferred?.id, "session-1")
    }

    func testPrefersLiveEmptyWhenNotLoading() {
        let live = makeSession(id: "session-1", events: [], eventCount: 0, fileSizeBytes: 0)
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e1")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: live,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: false,
            loadingSessionID: nil
        )

        XCTAssertEqual(preferred?.events.count, 0)
        XCTAssertEqual(preferred?.id, "session-1")
    }

    func testPrefersLiveEmptyWhenDifferentSessionIsLoading() {
        let live = makeSession(id: "session-1", events: [], eventCount: 0, fileSizeBytes: 0)
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e1")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: live,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: true,
            loadingSessionID: "session-2"
        )

        XCTAssertEqual(preferred?.events.count, 0)
        XCTAssertEqual(preferred?.id, "session-1")
    }

    func testPrefersLiveWhenLiveHasEvents() {
        let live = makeSession(id: "session-1", events: [makeEvent(id: "e-live")])
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e-cached")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: live,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: true,
            loadingSessionID: "session-1"
        )

        XCTAssertEqual(preferred?.events.first?.id, "e-live")
    }

    func testPrefersCachedWhenLiveLooksTransientlyLightweightOutsideLoading() {
        let live = makeSession(id: "session-1", events: [], eventCount: 4)
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e1")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: live,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: false,
            loadingSessionID: nil
        )

        XCTAssertEqual(preferred?.events.count, 1)
        XCTAssertEqual(preferred?.id, "session-1")
    }

    func testUsesCachedWhenLiveMissing() {
        let cached = makeSession(id: "session-1", events: [makeEvent(id: "e1")])

        let preferred = TranscriptSessionResolutionPolicy.preferredSession(
            live: nil,
            cached: cached,
            sessionID: "session-1",
            isLoadingSession: false,
            loadingSessionID: nil
        )

        XCTAssertEqual(preferred?.events.count, 1)
        XCTAssertEqual(preferred?.id, "session-1")
    }

    private func makeSession(id: String,
                             events: [SessionEvent],
                             eventCount: Int? = nil,
                             fileSizeBytes: Int? = 1024) -> Session {
        Session(
            id: id,
            source: .claude,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 100),
            model: "claude-test",
            filePath: "/tmp/\(id).jsonl",
            fileSizeBytes: fileSizeBytes,
            eventCount: eventCount ?? max(events.count, 1),
            events: events
        )
    }

    private func makeEvent(id: String) -> SessionEvent {
        SessionEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .assistant,
            role: "assistant",
            text: "hello",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
    }
}

final class TranscriptTailUpdateStateTests: XCTestCase {
    func testJumpArrowVisibleBeforeViewportMeasurement() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)

        XCTAssertTrue(state.shouldShowJumpToLatestButton)
    }

    func testJumpArrowHiddenAtBottom() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)

        state.viewportChanged(isNearBottom: true)

        XCTAssertFalse(state.shouldShowJumpToLatestButton)
    }

    func testJumpArrowVisibleAwayFromBottom() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)

        state.viewportChanged(isNearBottom: false)

        XCTAssertTrue(state.shouldShowJumpToLatestButton)
    }

    func testDetachedContentUpdateKeepsJumpArrowVisible() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)
        state.viewportChanged(isNearBottom: false)

        state.contentVersionChanged(sessionID: "s1", contentVersion: 11)

        XCTAssertTrue(state.shouldShowJumpToLatestButton)
    }

    func testContentUpdateAtBottomRequestsAutoScroll() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)

        state.contentVersionChanged(sessionID: "s1", contentVersion: 11)

        XCTAssertEqual(state.scrollToBottomToken, 1)
        XCTAssertFalse(state.hasUnseenUpdates)
        XCTAssertTrue(state.stickyFollowEnabled)
    }

    func testContentUpdateWhileDetachedShowsUnseenIndicator() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)
        state.viewportChanged(isNearBottom: false)

        state.contentVersionChanged(sessionID: "s1", contentVersion: 11)

        XCTAssertEqual(state.scrollToBottomToken, 0)
        XCTAssertTrue(state.hasUnseenUpdates)
        XCTAssertFalse(state.stickyFollowEnabled)
    }

    func testJumpToLatestClearsUnseenAndRequestsScroll() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)
        state.viewportChanged(isNearBottom: false)
        state.contentVersionChanged(sessionID: "s1", contentVersion: 11)

        state.jumpToLatest()

        XCTAssertEqual(state.scrollToBottomToken, 1)
        XCTAssertFalse(state.hasUnseenUpdates)
        XCTAssertTrue(state.stickyFollowEnabled)
    }

    func testReturningToBottomClearsUnseenAndRestoresFollow() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)
        state.viewportChanged(isNearBottom: false)
        state.contentVersionChanged(sessionID: "s1", contentVersion: 11)

        state.viewportChanged(isNearBottom: true)

        XCTAssertFalse(state.hasUnseenUpdates)
        XCTAssertTrue(state.stickyFollowEnabled)
        XCTAssertTrue(state.isNearBottom)
    }

    func testDifferentSessionResetsWithoutScrollRequest() {
        var state = TranscriptTailUpdateState()
        state.reset(sessionID: "s1", contentVersion: 10)

        state.contentVersionChanged(sessionID: "s2", contentVersion: 1)

        XCTAssertEqual(state.sessionID, "s2")
        XCTAssertEqual(state.lastContentVersion, 1)
        XCTAssertEqual(state.scrollToBottomToken, 0)
        XCTAssertFalse(state.hasUnseenUpdates)
    }
}
