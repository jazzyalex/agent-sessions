import XCTest
@testable import AgentSessions

final class ClaudeUsageSnapshotStoreTests: XCTestCase {

    /// Unique temp file per test so the suite never touches the real
    /// ~/Library/Application Support/com.triada.AgentSessions/claude_usage_latest.json
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude_usage_test_\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempURL = nil
        super.tearDown()
    }

    func testSaveAndLoad_roundTrip() async {
        let store = ClaudeUsageSnapshotStore(fileURL: tempURL)
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
        // tempURL points at a path that was never written — load must return nil, not crash.
        let store = ClaudeUsageSnapshotStore(fileURL: tempURL)
        let result = await store.load()
        XCTAssertNil(result)
    }

    func testSave_overwritesPreviousSnapshot() async {
        let store = ClaudeUsageSnapshotStore(fileURL: tempURL)

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
