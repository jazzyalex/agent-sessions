import XCTest
@testable import AgentSessions

final class ClaudeUsageSourceManagerTests: XCTestCase {

    // MARK: - Mode switching

    func testInit_tmuxOnlyMode_doesNotAttemptOAuth() async {
        var deliveredSnapshots: [ClaudeLimitSnapshot] = []
        let mgr = ClaudeUsageSourceManager()

        await mgr.start(
            mode: .tmuxOnly,
            handler: { snap in deliveredSnapshots.append(snap) },
            availabilityHandler: { _ in }
        )

        // tmuxOnly mode activates tmux adapter, not OAuth
        let diagnostics = await mgr.currentSourceDescription()
        XCTAssertEqual(diagnostics, "tmux")

        await mgr.stop()
    }

    func testDiagnosticsSnapshot_returnsNonEmpty() async {
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(
            mode: .auto,
            handler: { _ in },
            availabilityHandler: { _ in }
        )
        let diag = await mgr.diagnosticsSnapshot()
        XCTAssertFalse(diag.isEmpty)
        XCTAssertTrue(diag.contains("mode:"))
        await mgr.stop()
    }

    func testStop_canBeCalledMultipleTimes() async {
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.stop()
        await mgr.stop() // Should not crash
    }

    func testSetVisibility_doesNotCrash() async {
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.setVisibility(menuVisible: true, stripVisible: false, appIsActive: false)
        await mgr.setVisibility(menuVisible: false, stripVisible: true, appIsActive: true)
        await mgr.setVisibility(menuVisible: false, stripVisible: false, appIsActive: false)
        await mgr.stop()
    }

    // MARK: - Auto mode health description

    func testHealthDescription_noData_returnsPending() async {
        let mgr = ClaudeUsageSourceManager()
        // Don't start — just check initial state directly
        let health = await mgr.currentHealthDescription()
        XCTAssertEqual(health, "pending")
    }

    func testCurrentSourceDescription_oauthOnlyMode() async {
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .oauthOnly, handler: { _ in }, availabilityHandler: { _ in })
        let source = await mgr.currentSourceDescription()
        // oauthOnly without successful fetch
        XCTAssertTrue(source.contains("OAuth"))
        await mgr.stop()
    }
}
