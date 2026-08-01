import XCTest
@testable import AgentSessions

final class ClaudeCloudHUDRowMapperTests: XCTestCase {

    private func session(_ id: String,
                         working: Bool = true,
                         review: Bool = false,
                         disconnected: Bool = false,
                         unread: Int = 0,
                         lastEventAt: Date? = Date(timeIntervalSince1970: 1_785_000_000)) -> ClaudeCloudSession {
        ClaudeCloudSession(id: id,
                           title: "PingCraft game design prototype",
                           isWorking: working,
                           isAwaitingReview: review,
                           isDisconnected: disconnected,
                           lastEventAt: lastEventAt,
                           unread: unread)
    }

    func test_workingSessionMapsToActiveRow() throws {
        let row = try XCTUnwrap(ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")]).first)
        XCTAssertEqual(row.liveState, .active)
        XCTAssertEqual(row.agentType, .claude)
        XCTAssertEqual(row.source, .claude)
        XCTAssertEqual(row.displayName, "PingCraft game design prototype")
        XCTAssertNil(row.idleReason)
    }

    func test_reviewReadyMapsToIdleWaiting() throws {
        let row = try XCTUnwrap(
            ClaudeCloudHUDRowMapper.rows(from: [session("cse_b", working: false, review: true)]).first)
        XCTAssertEqual(row.liveState, .idle)
        XCTAssertEqual(row.idleReason, .generic)
        XCTAssertEqual(row.preview, "Waiting for review")
    }

    func test_disconnectedIsSurfacedInPreview() throws {
        let row = try XCTUnwrap(
            ClaudeCloudHUDRowMapper.rows(from: [session("cse_c", disconnected: true)]).first)
        XCTAssertEqual(row.preview, "Disconnected from sandbox")
    }

    /// A cloud session has no local process. Fabricating tty/logPath/revealURL would
    /// make downstream navigation follow a path that does not exist.
    func test_carriesNoFakeProcessData() throws {
        let row = try XCTUnwrap(ClaudeCloudHUDRowMapper.rows(from: [session("cse_d")]).first)
        XCTAssertNil(row.tty)
        XCTAssertNil(row.logPath)
        XCTAssertNil(row.revealURL)
        XCTAssertNil(row.workingDirectory)
        XCTAssertNil(row.termProgram)
        XCTAssertNil(row.itermSessionId)
        XCTAssertEqual(row.navigationConfidence, HUDNavigationConfidence.none)
    }

    func test_rowIdIsStableAndNamespaced() {
        let a = ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")]).first
        let b = ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")]).first
        XCTAssertEqual(a?.id, b?.id, "row identity must be stable across polls")
        XCTAssertEqual(a?.id, "claude-cloud:cse_a")
    }

    func test_missingTimestampLeavesElapsedBlank() throws {
        let row = try XCTUnwrap(
            ClaudeCloudHUDRowMapper.rows(from: [session("cse_e", lastEventAt: nil)]).first)
        XCTAssertEqual(row.elapsed, "", "no timestamp must not read as 'just started'")
        XCTAssertNil(row.lastSeenAt)
    }

    func test_elapsedFormatsFromLastEvent() throws {
        let now = Date(timeIntervalSince1970: 1_785_000_000 + 3 * 60)
        let row = try XCTUnwrap(
            ClaudeCloudHUDRowMapper.rows(from: [session("cse_f")], now: now).first)
        XCTAssertEqual(row.elapsed, "3m")
    }

    func test_unreadCountAppearsWhenNothingMoreUrgent() throws {
        let row = try XCTUnwrap(
            ClaudeCloudHUDRowMapper.rows(from: [session("cse_g", unread: 2)]).first)
        XCTAssertEqual(row.preview, "2 unread")
    }

    func test_emptyInputProducesNoRows() {
        XCTAssertTrue(ClaudeCloudHUDRowMapper.rows(from: []).isEmpty)
    }
}
