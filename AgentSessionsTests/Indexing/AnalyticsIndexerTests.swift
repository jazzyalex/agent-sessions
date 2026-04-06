import XCTest
@testable import AgentSessions

final class AnalyticsIndexerTests: XCTestCase {

    // MARK: - deriveSessionDayRows tests

    func testDaySplitSingleDay() throws {
        // Session entirely within one day should produce 1 row
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        let end = cal.date(bySettingHour: 11, minute: 30, second: 0, of: now)!

        let meta = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/tmp/x.jsonl",
            mtime: Int64(end.timeIntervalSince1970), size: 100,
            startTS: Int64(start.timeIntervalSince1970), endTS: Int64(end.timeIntervalSince1970),
            model: "gpt-4", cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 3,
            parentSessionID: nil, subagentType: nil, customTitle: nil
        )

        let rows = IndexDB.deriveSessionDayRows(from: [meta])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].messages, 10)
        XCTAssertEqual(rows[0].commands, 3)
        XCTAssertEqual(rows[0].durationSec, 5400, accuracy: 1.0) // 1.5 hours
        XCTAssertEqual(rows[0].source, "codex")
        XCTAssertEqual(rows[0].sessionID, "s1")
    }

    func testDaySplitCrossMidnight() throws {
        // 23:50 -> 00:10 next day should split into 2 rows
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(bySettingHour: 23, minute: 50, second: 0, of: now)!
        let end = cal.date(byAdding: .minute, value: 20, to: start)!

        let meta = SessionMetaRow(
            sessionID: "s2", source: "claude", path: "/tmp/c.jsonl",
            mtime: Int64(end.timeIntervalSince1970), size: 200,
            startTS: Int64(start.timeIntervalSince1970), endTS: Int64(end.timeIntervalSince1970),
            model: nil, cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 20, commands: 5,
            parentSessionID: nil, subagentType: nil, customTitle: nil
        )

        let rows = IndexDB.deriveSessionDayRows(from: [meta])
        XCTAssertEqual(rows.count, 2)
        let totalDuration = rows.reduce(0.0) { $0 + $1.durationSec }
        XCTAssertEqual(totalDuration, 1200, accuracy: 1.0) // 20 minutes
        let totalMessages = rows.reduce(0) { $0 + $1.messages }
        XCTAssertEqual(totalMessages, 20)
    }

    func testDaySplitZeroDuration() throws {
        // start == end should produce 1 row with 0 duration
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970)

        let meta = SessionMetaRow(
            sessionID: "s3", source: "gemini", path: "/tmp/g.jsonl",
            mtime: ts, size: 50,
            startTS: ts, endTS: ts,
            model: nil, cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 1, commands: 0,
            parentSessionID: nil, subagentType: nil, customTitle: nil
        )

        let rows = IndexDB.deriveSessionDayRows(from: [meta])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].durationSec, 0.0)
        XCTAssertEqual(rows[0].messages, 1)
    }

    func testDaySplitMultipleSessions() throws {
        // Multiple sessions should produce independent rows
        let cal = Calendar.current
        let now = Date()
        let start1 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let end1 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        let start2 = cal.date(bySettingHour: 14, minute: 0, second: 0, of: now)!
        let end2 = cal.date(bySettingHour: 15, minute: 0, second: 0, of: now)!

        let metas = [
            SessionMetaRow(
                sessionID: "a", source: "codex", path: "/tmp/a.jsonl",
                mtime: Int64(end1.timeIntervalSince1970), size: 100,
                startTS: Int64(start1.timeIntervalSince1970), endTS: Int64(end1.timeIntervalSince1970),
                model: "m1", cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
                isHousekeeping: false, messages: 5, commands: 2,
                parentSessionID: nil, subagentType: nil, customTitle: nil
            ),
            SessionMetaRow(
                sessionID: "b", source: "codex", path: "/tmp/b.jsonl",
                mtime: Int64(end2.timeIntervalSince1970), size: 100,
                startTS: Int64(start2.timeIntervalSince1970), endTS: Int64(end2.timeIntervalSince1970),
                model: "m1", cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
                isHousekeeping: false, messages: 8, commands: 4,
                parentSessionID: nil, subagentType: nil, customTitle: nil
            )
        ]

        let rows = IndexDB.deriveSessionDayRows(from: metas)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.sessionID)), Set(["a", "b"]))
    }

    func testDaySplitSumPreservation() throws {
        // 1 message spanning 3 roughly equal days must sum to exactly 1
        let cal = Calendar.current
        let base = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let start = base
        let end = cal.date(byAdding: .day, value: 2, to: cal.date(bySettingHour: 12, minute: 0, second: 0, of: base)!)!

        let meta = SessionMetaRow(
            sessionID: "s-sum", source: "codex", path: "/tmp/sum.jsonl",
            mtime: Int64(end.timeIntervalSince1970), size: 100,
            startTS: Int64(start.timeIntervalSince1970), endTS: Int64(end.timeIntervalSince1970),
            model: nil, cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 1, commands: 1,
            parentSessionID: nil, subagentType: nil, customTitle: nil
        )

        let rows = IndexDB.deriveSessionDayRows(from: [meta])
        XCTAssertEqual(rows.count, 3)
        // Sum must be exactly preserved
        XCTAssertEqual(rows.reduce(0) { $0 + $1.messages }, 1, "Message sum must equal session total")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.commands }, 1, "Command sum must equal session total")
    }

    func testDaySplitLargeCountPreservation() throws {
        // 100 messages spanning 3 days must sum to exactly 100
        let cal = Calendar.current
        let base = cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let end = cal.date(byAdding: .hour, value: 50, to: base)!

        let meta = SessionMetaRow(
            sessionID: "s-lg", source: "claude", path: "/tmp/lg.jsonl",
            mtime: Int64(end.timeIntervalSince1970), size: 500,
            startTS: Int64(base.timeIntervalSince1970), endTS: Int64(end.timeIntervalSince1970),
            model: nil, cwd: nil, repo: nil, title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 100, commands: 37,
            parentSessionID: nil, subagentType: nil, customTitle: nil
        )

        let rows = IndexDB.deriveSessionDayRows(from: [meta])
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.messages }, 100, "Message sum must equal 100")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.commands }, 37, "Command sum must equal 37")
    }
}
