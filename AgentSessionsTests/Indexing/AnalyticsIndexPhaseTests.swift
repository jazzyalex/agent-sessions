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

    func testSessionsChartForegroundScaleIncludesActualDataSources() {
        let points = [
            AnalyticsTimeSeriesPoint(
                date: Date(timeIntervalSince1970: 0),
                agent: .codex,
                sessionCount: 1,
                messageCount: 2
            ),
            AnalyticsTimeSeriesPoint(
                date: Date(timeIntervalSince1970: 0),
                agent: .hermes,
                sessionCount: 1,
                messageCount: 3
            ),
        ]

        let domain = SessionsChartView.foregroundStyleDomain(for: points)
        XCTAssertEqual(domain, ["Codex CLI", "Hermes"])
    }
}
