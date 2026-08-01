import XCTest

// LogicTests compiles app sources directly (see SessionFilterShims.swift).

final class ClaudeCloudCatalogTests: XCTestCase {

    private func raw(_ id: String,
                     kind: String?,
                     status: String = "active",
                     bucket: String = "working",
                     worker: String = "running",
                     conn: String = "connected",
                     title: String? = "t") -> ClaudeCloudRawSession {
        ClaudeCloudRawSession(id: id, title: title, status: status, statusBucket: bucket,
                              workerStatus: worker, connectionStatus: conn,
                              environmentKind: kind, lastEventAt: nil, unread: 0)
    }

    // MARK: - Cloud filter

    func test_keepsOnlyAnthropicCloudRows_notThePrefix() {
        let rows = [raw("cse_a", kind: "anthropic_cloud"),
                    raw("cse_b", kind: "bridge"),
                    raw("cse_c", kind: nil)]
        XCTAssertEqual(ClaudeCloudFilter.cloudOnly(rows).map(\.id), ["cse_a"],
                       "all three are cse_-prefixed; only environment_kind distinguishes them")
    }

    func test_bridgeRowsAreExcludedEvenWhenWorking() {
        let rows = [raw("cse_bridge", kind: "bridge", bucket: "working", worker: "running")]
        XCTAssertTrue(ClaudeCloudFilter.cloudOnly(rows).isEmpty,
                      "bridge sessions are already shown by the local indexer")
    }

    // MARK: - Active predicate

    func test_activeRowsExcludeArchivedSessions() {
        let rows = [raw("cse_working", kind: "anthropic_cloud"),
                    raw("cse_review", kind: "anthropic_cloud", bucket: "review_ready", worker: "idle"),
                    raw("cse_done", kind: "anthropic_cloud", status: "archived",
                        bucket: "completed", worker: "idle")]
        let ids = ClaudeCloudFilter.activeRows(ClaudeCloudFilter.cloudOnly(rows)).map(\.id)
        XCTAssertEqual(Set(ids), Set(["cse_working", "cse_review"]))
    }

    /// Regression: presence must not depend on worker_status. An active session
    /// whose worker is momentarily idle stays listed — tying visibility to
    /// worker_status made the row blink out between turns, because worker_status
    /// is "idle" for the overwhelming majority of sessions at any instant.
    func test_activeSessionStaysListedWhileWorkerIsIdle() {
        let rows = ClaudeCloudFilter.cloudOnly(
            [raw("cse_between_turns", kind: "anthropic_cloud", bucket: "completed", worker: "idle")])
        let row = ClaudeCloudFilter.activeRows(rows).first
        XCTAssertEqual(row?.id, "cse_between_turns", "an active session must not vanish between turns")
        XCTAssertEqual(row?.isWorking, false, "…but it is styled as not working")
    }

    func test_runningWorkerMapsToWorking() {
        let rows = ClaudeCloudFilter.cloudOnly([raw("cse_a", kind: "anthropic_cloud")])
        XCTAssertEqual(ClaudeCloudFilter.activeRows(rows).first?.isWorking, true)
    }

    func test_unspecifiedWorkerStatusFallsBackToBucket() {
        let rows = ClaudeCloudFilter.cloudOnly(
            [raw("cse_x", kind: "anthropic_cloud", worker: "WORKER_STATUS_UNSPECIFIED")])
        XCTAssertEqual(ClaudeCloudFilter.activeRows(rows).first?.isWorking, true,
                       "bucket=working carries it when worker_status is uninformative")
    }

    func test_reviewReadyIsNotWorkingButIsStillLive() {
        let rows = ClaudeCloudFilter.cloudOnly(
            [raw("cse_r", kind: "anthropic_cloud", bucket: "review_ready", worker: "idle")])
        let row = ClaudeCloudFilter.activeRows(rows).first
        XCTAssertEqual(row?.isWorking, false)
        XCTAssertEqual(row?.isAwaitingReview, true)
    }

    func test_disconnectedIsSurfacedNotDropped() {
        let rows = ClaudeCloudFilter.cloudOnly(
            [raw("cse_d", kind: "anthropic_cloud", conn: "disconnected")])
        XCTAssertEqual(ClaudeCloudFilter.activeRows(rows).first?.isDisconnected, true)
    }

    func test_missingTitleGetsAPlaceholderRatherThanEmptyRow() {
        let rows = ClaudeCloudFilter.cloudOnly([raw("cse_n", kind: "anthropic_cloud", title: nil)])
        XCTAssertEqual(ClaudeCloudFilter.activeRows(rows).first?.title, "Cloud session")
    }

    // MARK: - State machine (anti-spinner guards)

    private let allStates: [ClaudeCloudSourceState] = [
        .disabled, .notConnected, .expired, .rateLimited(until: nil),
        .offline, .contractDrift("x"), .empty, .ok(count: 2)
    ]

    func test_everyStateHasDistinctNonEmptyMessage() {
        let msgs = allStates.map(\.displayMessage)
        XCTAssertFalse(msgs.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                       "a state with no copy renders as a silent spinner")
        XCTAssertEqual(Set(msgs).count, allStates.count, "two states collapsed to identical copy")
    }

    func test_emptyAndNotConnectedNeverReadTheSame() {
        XCTAssertNotEqual(ClaudeCloudSourceState.empty.displayMessage,
                          ClaudeCloudSourceState.notConnected.displayMessage,
                          "conflating these is what makes 'not set up' look like 'app is broken'")
    }

    func test_onlyDegradedStatesAreStale() {
        XCTAssertTrue(ClaudeCloudSourceState.offline.isStale)
        XCTAssertTrue(ClaudeCloudSourceState.rateLimited(until: nil).isStale)
        XCTAssertFalse(ClaudeCloudSourceState.ok(count: 1).isStale)
        XCTAssertFalse(ClaudeCloudSourceState.empty.isStale)
        XCTAssertFalse(ClaudeCloudSourceState.disabled.isStale)
    }

    func test_rateLimitedRendersTheRetryTimeWhenKnown() {
        let until = Date(timeIntervalSince1970: 1_785_000_000)
        XCTAssertNotEqual(ClaudeCloudSourceState.rateLimited(until: until).displayMessage,
                          ClaudeCloudSourceState.rateLimited(until: nil).displayMessage)
    }

    func test_okCountIsSingularForOne() {
        XCTAssertEqual(ClaudeCloudSourceState.ok(count: 1).displayMessage, "1 active cloud session")
    }
}
