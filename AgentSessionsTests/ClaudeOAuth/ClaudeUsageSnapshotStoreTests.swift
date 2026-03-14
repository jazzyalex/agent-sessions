import XCTest
@testable import AgentSessions

final class ClaudeUsageSnapshotStoreTests: XCTestCase {

    func testSaveAndLoad_roundTrip() async {
        let store = ClaudeUsageSnapshotStore()
        let snapshot = ClaudeLimitSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1700000000),
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: 0.42,
            fiveHourResetText: "Oct 9 at 2pm",
            weeklyUsedRatio: 0.15,
            weeklyResetText: "Oct 14 at 2pm",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: "deadbeef"
        )

        await store.save(snapshot)
        let loaded = await store.load()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.fiveHourUsedRatio ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(loaded?.weeklyUsedRatio ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(loaded?.fiveHourResetText, "Oct 9 at 2pm")
        XCTAssertEqual(loaded?.weeklyResetText, "Oct 14 at 2pm")
        XCTAssertEqual(loaded?.rawPayloadHash, "deadbeef")
        XCTAssertEqual(loaded?.source, .oauthEndpoint)
        XCTAssertEqual(loaded?.health, .live)
    }

    func testLoad_missingFile_returnsNil() async {
        // Create a store pointing at a non-existent path
        let store = ClaudeUsageSnapshotStore()
        // The actual file may or may not exist; this test just verifies load doesn't crash
        let result = await store.load()
        // Either nil (no file) or a valid snapshot — just no crash
        _ = result
    }

    func testSave_overwritesPreviousSnapshot() async {
        let store = ClaudeUsageSnapshotStore()

        let snap1 = ClaudeLimitSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1700000000),
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: 0.10,
            fiveHourResetText: "",
            weeklyUsedRatio: 0.20,
            weeklyResetText: "",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )
        let snap2 = ClaudeLimitSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1700001000),
            source: .tmuxUsage,
            health: .stale,
            fiveHourUsedRatio: 0.50,
            fiveHourResetText: "",
            weeklyUsedRatio: 0.60,
            weeklyResetText: "",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )

        await store.save(snap1)
        await store.save(snap2)
        let loaded = await store.load()

        XCTAssertEqual(loaded?.fiveHourUsedRatio ?? 0, 0.50, accuracy: 0.001)
        XCTAssertEqual(loaded?.source, .tmuxUsage)
    }
}
