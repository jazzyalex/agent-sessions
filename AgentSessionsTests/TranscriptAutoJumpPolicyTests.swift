import XCTest
@testable import AgentSessions

/// Covers the search-filtered "select any session -> auto-jump to first match" behavior.
///
/// Causal chain under test (see AgentSessions/Views/UnifiedSessionsView.swift
/// handleSelectionChange + AgentSessions/Views/TranscriptPlainView.swift):
/// 1. UnifiedSessionsView.handleSelectionChange debounces every selection change through a
///    150ms `selectionPropagationTask`; only the row the user rests on reaches
///    `settledSelection = id`.
/// 2. Immediately after settling, it calls `scheduleAutoJump(for: id)`, which (while a search
///    query is active) calls `UnifiedSearchState.requestAutoJump(sessionID:)` — bumping
///    `autoJumpToken` and recording `autoJumpSessionID`.
/// 3. TranscriptPlainView observes `autoJumpToken` and — via TranscriptAutoJumpPolicy.shouldLatch —
///    only latches the request as pending if search is still active AND the requested session id
///    matches the session currently displayed (which tracks `settledSelection`, not the raw,
///    possibly still-scrubbing `selection`).
/// 4. TranscriptAutoJumpPolicy.shouldApply then gates firing the actual jump (reusing
///    performUnifiedFind, the same function the manual arrow button invokes) on the pending
///    token being new, the session still matching, search still active, and the transcript
///    build for that session having completed.
///
/// Routing scheduleAutoJump through the settled block (rather than eagerly off the raw
/// selection stream) is what fixed manual clicks/arrow-key selections: previously the request
/// could fire before `settledSelection` (and therefore the transcript pane's session) caught
/// up, so `shouldLatch` would reject it and the jump was silently dropped forever.
final class TranscriptAutoJumpPolicyTests: XCTestCase {

    // MARK: - shouldLatch (searchState.autoJumpToken observer gate)

    func testLatchesWhenSearchActiveAndSessionMatches() {
        XCTAssertTrue(
            TranscriptAutoJumpPolicy.shouldLatch(
                requestedSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-1"
            )
        )
    }

    func testDoesNotLatchWhenSearchIsInactive() {
        // Search cleared mid-flight: a stale request must not be latched even if the id matches.
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldLatch(
                requestedSessionID: "session-1",
                isSearchActive: false,
                displayedSessionID: "session-1"
            )
        )
    }

    func testDoesNotLatchWhenDisplayedSessionHasNotSettledYet() {
        // This is the race that used to drop manual-click auto-jumps: the request targets the
        // newly-selected session, but the transcript pane is still showing the previous
        // (not-yet-settled) session.
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldLatch(
                requestedSessionID: "session-2",
                isSearchActive: true,
                displayedSessionID: "session-1"
            )
        )
    }

    func testDoesNotLatchWhenRequestedSessionIsNil() {
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldLatch(
                requestedSessionID: nil,
                isSearchActive: true,
                displayedSessionID: "session-1"
            )
        )
    }

    // MARK: - shouldApply (fires the actual jump once latched)

    func testAppliesWhenPendingTokenIsNewAndTranscriptReady() {
        XCTAssertTrue(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: 2,
                lastHandledToken: 1,
                pendingSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-1",
                isTranscriptReady: true
            )
        )
    }

    func testDoesNotApplyWhenTranscriptNotYetBuilt() {
        // Term-absent / not-yet-rendered case: no scroll jump until the transcript is ready.
        // The pending token stays latched for a later rebuild to retry.
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: 2,
                lastHandledToken: 1,
                pendingSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-1",
                isTranscriptReady: false
            )
        )
    }

    func testDoesNotApplyWhenTokenAlreadyHandled() {
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: 1,
                lastHandledToken: 1,
                pendingSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-1",
                isTranscriptReady: true
            )
        )
    }

    func testDoesNotApplyWhenNoPendingToken() {
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: nil,
                lastHandledToken: 0,
                pendingSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-1",
                isTranscriptReady: true
            )
        )
    }

    func testDoesNotApplyWhenSearchClearedMidFlight() {
        // Search was cleared between the request and the transcript becoming ready.
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: 2,
                lastHandledToken: 1,
                pendingSessionID: "session-1",
                isSearchActive: false,
                displayedSessionID: "session-1",
                isTranscriptReady: true
            )
        )
    }

    func testDoesNotApplyWhenPendingSessionDoesNotMatchDisplayedSession() {
        // Selection moved on again before the earlier request's transcript became ready.
        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldApply(
                pendingToken: 2,
                lastHandledToken: 1,
                pendingSessionID: "session-1",
                isSearchActive: true,
                displayedSessionID: "session-2",
                isTranscriptReady: true
            )
        )
    }
}

/// Covers the list-side half of the pipeline: UnifiedSearchState is the plain ObservableObject
/// that carries the auto-jump request from UnifiedSessionsView to TranscriptPlainView.
final class UnifiedSearchStateAutoJumpTests: XCTestCase {
    func testRequestAutoJumpRecordsSessionAndBumpsToken() {
        let state = UnifiedSearchState()
        XCTAssertEqual(state.autoJumpToken, 0)
        XCTAssertNil(state.autoJumpSessionID)

        state.requestAutoJump(sessionID: "session-1")

        XCTAssertEqual(state.autoJumpSessionID, "session-1")
        XCTAssertEqual(state.autoJumpToken, 1)
    }

    func testRepeatedRequestsForSameSessionStillBumpToken() {
        // A settled selection landing on the same session twice (e.g. scrub returns to the
        // previously-settled row) must still produce a fresh token so TranscriptPlainView's
        // onChange fires again and re-applies the jump.
        let state = UnifiedSearchState()
        state.requestAutoJump(sessionID: "session-1")
        let firstToken = state.autoJumpToken

        state.requestAutoJump(sessionID: "session-1")

        XCTAssertEqual(state.autoJumpToken, firstToken + 1)
    }

    func testClearingSessionIDDropsAnyOutstandingRequestTarget() {
        // Mirrors UnifiedSessionsView.cancelAutoJump(), used both when the search query is
        // cleared and when the selection is lost entirely.
        let state = UnifiedSearchState()
        state.requestAutoJump(sessionID: "session-1")

        state.autoJumpSessionID = nil

        XCTAssertFalse(
            TranscriptAutoJumpPolicy.shouldLatch(
                requestedSessionID: state.autoJumpSessionID,
                isSearchActive: true,
                displayedSessionID: "session-1"
            )
        )
    }
}
