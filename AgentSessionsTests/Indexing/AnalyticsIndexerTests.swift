import XCTest
@testable import AgentSessions

final class AnalyticsIndexerTests: XCTestCase {
    func testDaySplitSimple() async throws {
        // 23:50 -> 00:10 next day should split into 2 rows
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(bySettingHour: 23, minute: 50, second: 0, of: now)!
        let end = cal.date(byAdding: .minute, value: 20, to: start)!

        let session = Session(id: "s1", source: .codex, startTime: start, endTime: end, model: nil, filePath: "/tmp/x.jsonl", eventCount: 0, events: [])
        let rows = await AnalyticsIndexer.splitIntoDays(session: session, start: start, end: end)
        XCTAssertEqual(rows.count, 2)
        let total = rows.reduce(0.0) { $0 + $1.durationSec }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(total, 3600) // should be 20 minutes
    }
}

