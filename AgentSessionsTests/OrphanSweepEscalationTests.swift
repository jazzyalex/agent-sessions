import XCTest
@testable import AgentSessions

final class OrphanSweepEscalationTests: XCTestCase {
    func testManagedLiveServerEscalatesAfterCap() {
        let a = ClaudeStatusService.orphanSweepAction(
            isManagedLabel: true, attempts: 2, maxAttempts: 2, serverAlive: true)
        XCTAssertEqual(a, .escalateSIGKILL)   // was .giveUp before the fix
    }
    func testManagedUnderCapRetries() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: true, attempts: 1, maxAttempts: 2, serverAlive: true),
            .retryKillServer)
    }
    func testNonManagedRespectsCap() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: false, attempts: 2, maxAttempts: 2, serverAlive: true),
            .giveUp)
    }
    func testDeadServerNeedsNoAction() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: true, attempts: 5, maxAttempts: 2, serverAlive: false),
            .giveUp)
    }
}
