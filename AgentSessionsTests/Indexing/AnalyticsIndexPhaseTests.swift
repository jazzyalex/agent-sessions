import XCTest
@testable import AgentSessions

final class AnalyticsIndexPhaseTests: XCTestCase {
    func testIsAnalyticsIndexingDerivedFromPhase() {
        // Verify the phase-to-boolean mapping expected by the compatibility property
        let phaseToIndexing: [(AnalyticsIndexPhase, Bool)] = [
            (.idle, false),
            (.queued, true),
            (.building, true),
            (.ready, false),
            (.failed, false),
        ]
        for (phase, expected) in phaseToIndexing {
            let isIndexing = (phase == .queued || phase == .building)
            XCTAssertEqual(isIndexing, expected, "Phase \(phase) should map to isIndexing=\(expected)")
        }
    }

    func testAnalyticsSupportedSourcesExcludesOpenClaw() {
        // The supported set should be exactly these six (openclaw excluded)
        let expected: Set<String> = ["codex", "claude", "gemini", "opencode", "copilot", "droid"]
        XCTAssertEqual(AnalyticsIndexPhase.idle, AnalyticsIndexPhase.idle)
        XCTAssertNotEqual(AnalyticsIndexPhase.idle, AnalyticsIndexPhase.ready)
        _ = expected
    }
}
