import XCTest
@testable import AgentSessions

#if DEBUG
final class IndexDBBackfillStateTests: XCTestCase {
    private var db: IndexDB!
    private var cleanup: (() -> Void)!

    override func setUpWithError() throws {
        let result = try makeTestIndexDB()
        db = result.db
        cleanup = result.cleanup
    }

    override func tearDown() {
        cleanup?()
        db = nil
        cleanup = nil
    }

    func testFreshDBReturnsNoCompletedSources() async throws {
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertTrue(completed.isEmpty)
    }

    func testMarkOneSourceComplete() async throws {
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertEqual(completed, ["codex"])
    }

    func testMarkAllFiveSourcesComplete() async throws {
        for source in ["codex", "claude", "gemini", "opencode", "copilot"] {
            try await db.setAnalyticsBackfillComplete(source: source, version: 1)
        }
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertEqual(completed, Set(["codex", "claude", "gemini", "opencode", "copilot"]))
    }

    func testClearAnalyticsBackfillState() async throws {
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        try await db.setAnalyticsBackfillComplete(source: "claude", version: 1)
        try await db.clearAnalyticsBackfillState()
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertTrue(completed.isEmpty)
    }

    func testVersionMismatchInvalidatesMarkers() async throws {
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        // Query for version 2 should not find the version 1 marker
        let completed = try await db.analyticsBackfillCompleteSources(version: 2)
        XCTAssertTrue(completed.isEmpty)
        // Version 1 marker still exists
        let v1 = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertEqual(v1, ["codex"])
    }

    func testPurgeSourceClearsBackfillMarker() async throws {
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        try await db.setAnalyticsBackfillComplete(source: "claude", version: 1)
        try await db.purgeSource("codex")
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertEqual(completed, ["claude"])
    }

    func testIdempotentSetDoesNotDuplicate() async throws {
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        try await db.setAnalyticsBackfillComplete(source: "codex", version: 1)
        let completed = try await db.analyticsBackfillCompleteSources(version: 1)
        XCTAssertEqual(completed, ["codex"])
    }
}
#endif
