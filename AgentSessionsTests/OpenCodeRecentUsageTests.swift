import XCTest
import SQLite3
@testable import AgentSessions

/// Completion time and the recent-usage window used by the Quota Meter's
/// OpenCode session rates. Row shapes mirror a real OpenCode 2.1.x database.
final class OpenCodeRecentUsageTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-OpenCodeRecent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("opencode.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Task 1: completion time

    func testCompletedAtFromV2AssistantTime() throws {
        try createV2Tables()
        try insertV2Session("ses_a", created: 1_000_000)
        try insertV2Row("ses_a", id: "msg_a", type: "assistant", seq: 1, created: 1_001_000, updated: 1_009_000,
                        data: assistant(created: 1_001_000, completed: 1_008_000))

        let event = try XCTUnwrap(events(for: "ses_a").first)
        XCTAssertEqual(event.completedAt, date(1_008_000))
        XCTAssertEqual(event.observedAt, date(1_001_000), "observedAt stays the request start")
    }

    func testCompactionWithoutTimeCompletedUsesRowUpdate() throws {
        try createV2Tables()
        try insertV2Session("ses_c", created: 1_000_000)
        try insertV2Row("ses_c", id: "msg_c", type: "compaction", seq: 1, created: 1_001_000, updated: 1_004_500,
                        data: #"{"time":{"created":1001000},"status":"completed","reason":"auto","model":{"id":"m","providerID":"p"},"tokens":{"input":20,"output":4,"reasoning":0,"cache":{"read":0,"write":0}}}"#)

        let event = try XCTUnwrap(events(for: "ses_c").first)
        XCTAssertEqual(event.completedAt, date(1_004_500))
    }

    func testV1PartTimeEndThenRowUpdate() throws {
        try createV1Tables()
        try insertV1Session("ses_v1", created: 1_000_000)
        try exec("""
        INSERT INTO message VALUES ('m1', 'ses_v1', 1001000, 1001000, '{"role":"assistant","time":{"created":1001000,"completed":1003000},"modelID":"m"}');
        INSERT INTO part VALUES ('p1', 'm1', 'ses_v1', 1003000, 1003000, '{"type":"step-finish","time":{"end":1002900},"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO message VALUES ('m2', 'ses_v1', 1005000, 1005000, '{"role":"assistant","time":{"created":1005000,"completed":1007000},"modelID":"m"}');
        INSERT INTO part VALUES ('p2', 'm2', 'ses_v1', 1007000, 1007100, '{"type":"step-finish","reason":"stop","tokens":{"input":2,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """)

        let byID = Dictionary(uniqueKeysWithValues: try events(for: "ses_v1").map { ($0.recordID, $0) })
        XCTAssertEqual(byID["p1"]?.completedAt, date(1_002_900), "part.time.end wins when present")
        XCTAssertEqual(byID["p2"]?.completedAt, date(1_007_100), "else the part row's time_updated")
    }

    func testV1FullLoadObservedAtUnchanged() throws {
        try createV1Tables()
        try insertV1Session("ses_v1", created: 1_000_000)
        try exec("""
        INSERT INTO message VALUES ('m1', 'ses_v1', 1001000, 1001000, '{"role":"assistant","time":{"created":1001000},"modelID":"m"}');
        INSERT INTO part VALUES ('p1', 'm1', 'ses_v1', 1003000, 1003000, '{"type":"step-finish","tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """)

        let event = try XCTUnwrap(events(for: "ses_v1").first)
        XCTAssertEqual(event.observedAt, date(1_003_000),
                       "Session Info keeps the v1 part timestamp; the rate path derives the start separately")
    }

    func testCompletedAtSurvivesPricing() throws {
        try createV2Tables()
        try insertV2Session("ses_a", created: 1_000_000)
        try insertV2Row("ses_a", id: "msg_a", type: "assistant", seq: 1, created: 1_001_000, updated: 1_009_000,
                        data: assistant(created: 1_001_000, completed: 1_008_000, model: "gpt-5"))
        let raw = try events(for: "ses_a")

        let priced = TelemetryCostCalculator.price(events: raw, fallbackSlices: [],
                                                   snapshot: RunwayPriceTable.makeForTesting().snapshot())

        XCTAssertEqual(priced.events.first?.completedAt, date(1_008_000))
        XCTAssertNotNil(priced.events.first?.apiEquivalentUSD)
    }

    func testObservedAtStaysRequestStart() throws {
        try createV2Tables()
        try insertV2Session("ses_a", created: 1_000_000)
        try insertV2Row("ses_a", id: "msg_a", type: "assistant", seq: 1, created: 1_001_000, updated: 1_900_000,
                        data: assistant(created: 1_001_000, completed: 1_800_000))

        let event = try XCTUnwrap(events(for: "ses_a").first)
        XCTAssertEqual(event.observedAt, date(1_001_000))
        XCTAssertEqual(event.completedAt, date(1_800_000))
    }

    func testDecodesEventWithoutCompletedAt() throws {
        let json = #"{"anchorLine":0,"usageFamily":"f","ownership":"session","speed":"standard","freshInputTokens":1,"cacheReadTokens":0,"cacheWrite5mTokens":0,"cacheWrite1hTokens":0,"outputTokens":1,"reasoningOutputTokens":0}"#
        let event = try JSONDecoder().decode(TelemetryUsageEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.completedAt)
    }

    // MARK: - Task 2: window eligibility and request classification

    /// Fixed "now" for window tests: 100 000 s after the epoch, in milliseconds.
    private let nowMillis: Int64 = 100_000_000
    private var now: Date { date(nowMillis) }
    private func ago(minutes: Double) -> Int64 { nowMillis - Int64(minutes * 60_000) }

    func testInFlightOnlyWindowIsNoUsage() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 1), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"model":{"id":"m","providerID":"p"},"content":[]}"#)
        XCTAssertEqual(try window("ses"), .noCompletedUsage)
    }

    func testUserOnlyWindowIsNoUsage() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "u", type: "user", seq: 1, created: ago(minutes: 1), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"text":"hi"}"#)
        XCTAssertEqual(try window("ses"), .noCompletedUsage)
    }

    func testDecodedRowWithoutCompletionIsInFlight() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a1", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 2),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 2)))
        try insertV2Row("ses", id: "a2", type: "assistant", seq: 2, created: ago(minutes: 1), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"model":{"id":"m","providerID":"p"},"content":[]}"#)
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.map(\.recordID), ["a1-step-finish"], "the in-flight row is ignored, not an error")
    }

    func testCompletedTokenlessCompactionIsNoUsage() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "c", type: "compaction", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"status":"completed","reason":"manual","summary":"s"}"#)
        XCTAssertEqual(try window("ses"), .noCompletedUsage,
                       "matches Session Info: a completed compaction without tokens used none")
    }

    func testInFlightCompactionIgnored() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "c", type: "compaction", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"status":"running","model":{"id":"m","providerID":"p"},"tokens":{"input":5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        XCTAssertEqual(try window("ses"), .noCompletedUsage)
    }

    func testCompletedCompactionWithTokensIncluded() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "c", type: "compaction", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1},"status":"completed","model":{"id":"m","providerID":"p"},"tokens":{"input":20,"output":4,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.first?.freshInputTokens, 20)
        XCTAssertEqual(events.first?.completedAt, date(ago(minutes: 1)), "row update time stands in for completion")
    }

    func testCompletedAssistantMissingTokensIsUnavailable() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1,"completed":\#(ago(minutes: 1))},"model":{"id":"m","providerID":"p"},"content":[]}"#)
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testFailedRequestWithoutTokensIsNoUsage() throws {
        // OpenCode 2.1.4 stores a refused request (provider.free-limit 429) as a
        // completed assistant row with an error, no tokens and no content.
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a1", type: "assistant", seq: 1, created: ago(minutes: 4), updated: ago(minutes: 3),
                        data: completedAssistant(created: ago(minutes: 4), completed: ago(minutes: 3)))
        try insertV2Row("ses", id: "a2", type: "assistant", seq: 2, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1,"completed":\#(ago(minutes: 1))},"model":{"id":"m","providerID":"p"},"content":[],"finish":"error","error":{"type":"provider.free-limit","status":429,"retryAfterMs":1000}}"#)
        guard case .usage(let events) = try window("ses") else { return XCTFail("a refused request must not blank the window") }
        XCTAssertEqual(events.map(\.recordID), ["a1-step-finish"])
    }

    func testFailedRequestWithPartialContentButNoTokensIsUnavailable() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: #"{"time":{"created":1,"completed":\#(ago(minutes: 1))},"model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"half"}],"finish":"error","error":{"type":"provider.error"}}"#)
        XCTAssertEqual(try window("ses"), .unavailable, "a request that streamed content has unknown usage")
    }

    func testAssistantWithTokensButNoCompletionCountsAtRowUpdate() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 2),
                        data: #"{"time":{"created":1},"model":{"id":"m","providerID":"p"},"content":[],"error":{"name":"x"},"tokens":{"input":7,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.first?.completedAt, date(ago(minutes: 2)))
    }

    func testMalformedComponentsAreUnavailable() throws {
        let badTokens = [
            #"{"input":-1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}"#,
            #"{"input":1.5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}"#,
            #"{"input":"12","output":1,"reasoning":0,"cache":{"read":0,"write":0}}"#,
            #"{"input":1,"output":1,"reasoning":0,"cache":{"read":0}}"#,
            #"{"input":9223372036854775807,"output":9223372036854775807,"reasoning":0,"cache":{"read":0,"write":0}}"#,
        ]
        for (index, tokens) in badTokens.enumerated() {
            let id = "ses\(index)"
            try vendorV2Session(id)
            try insertV2Row(id, id: "a\(index)", type: "assistant", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                            data: #"{"time":{"created":1,"completed":\#(ago(minutes: 1))},"model":{"id":"m","providerID":"p"},"content":[],"tokens":\#(tokens)}"#)
            XCTAssertEqual(try window(id), .unavailable, tokens)
        }
    }

    func testUndecodableV2AssistantIsUnavailable() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: "{not json")
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testUndecodableV2CompactionIsUnavailable() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "c", type: "compaction", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: "[1,2")
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testUndecodableV1PartIsUnavailable() throws {
        try vendorV1Session("ses")
        try insertV1Message("ses", id: "m", created: ago(minutes: 3), updated: ago(minutes: 1))
        try insertV1Part("ses", id: "p", message: "m", created: ago(minutes: 1), updated: ago(minutes: 1), data: "{oops")
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testUndecodableV1MessageIsUnavailable() throws {
        try vendorV1Session("ses")
        try exec("""
        INSERT INTO message VALUES ('m', 'ses', \(ago(minutes: 3)), \(ago(minutes: 1)), '{oops');
        """)
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testMalformedCompletionTimestampIsUnavailable() throws {
        for (index, value) in [#""abc""#, "-5", "1.5", "1e20", "true"].enumerated() {
            let v2 = "v2_\(index)"
            try vendorV2Session(v2)
            try insertV2Row(v2, id: "a\(index)", type: "assistant", seq: 1, created: ago(minutes: 2), updated: ago(minutes: 1),
                            data: #"{"time":{"created":1,"completed":\#(value)},"model":{"id":"m","providerID":"p"},"content":[],"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
            XCTAssertEqual(try window(v2), .unavailable, "v2 time.completed \(value)")
        }
        try vendorV1Session("v1")
        try insertV1Message("v1", id: "m", created: ago(minutes: 3), updated: ago(minutes: 1))
        try insertV1Part("v1", id: "p", message: "m", created: ago(minutes: 1), updated: ago(minutes: 1),
                         data: #"{"type":"step-finish","time":{"end":"later"},"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        XCTAssertEqual(try window("v1"), .unavailable, "v1 time.end")
    }

    func testOldMalformedRowOutsideWindowIsIgnored() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "bad", type: "assistant", seq: 1, created: ago(minutes: 50), updated: ago(minutes: 45),
                        data: "{broken")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 2, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1)))
        guard case .usage(let events) = try window("ses") else { return XCTFail("an old broken row must not poison a new burst") }
        XCTAssertEqual(events.count, 1)
    }

    func testRecentMalformedRowPoisonsWindow() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "bad", type: "assistant", seq: 1, created: ago(minutes: 50), updated: ago(minutes: 5),
                        data: "{broken")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 2, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1)))
        XCTAssertEqual(try window("ses"), .unavailable)
    }

    func testCompletionOlderThanThirtyMinutesExcluded() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 40), updated: ago(minutes: 35),
                        data: completedAssistant(created: ago(minutes: 40), completed: ago(minutes: 35)))
        XCTAssertEqual(try window("ses"), .noCompletedUsage)
    }

    func testRequestStartedOverTwoHoursAgoExcluded() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 125), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 125), completed: ago(minutes: 1)))
        XCTAssertEqual(try window("ses"), .noCompletedUsage, "product rule: older starts are not shown")
    }

    func testV1PartOfOldMessageExcluded() throws {
        try vendorV1Session("ses")
        try insertV1Message("ses", id: "m", created: ago(minutes: 130), updated: ago(minutes: 1))
        try insertV1Part("ses", id: "p", message: "m", created: ago(minutes: 1), updated: ago(minutes: 1),
                         data: v1StepFinish())
        XCTAssertEqual(try window("ses"), .noCompletedUsage, "eligibility follows the owning message's start")
    }

    func testV1LongRequestStartedInsideCutoffIncluded() throws {
        try vendorV1Session("ses")
        try insertV1Message("ses", id: "m", created: ago(minutes: 90), updated: ago(minutes: 1))
        try insertV1Part("ses", id: "p", message: "m", created: ago(minutes: 1), updated: ago(minutes: 1),
                         data: v1StepFinish())
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.first?.completedAt, date(ago(minutes: 1)))
    }

    func testV1ObservedAtIsRequestStart() throws {
        try vendorV1Session("ses")
        try insertV1Message("ses", id: "m", created: ago(minutes: 4), updated: ago(minutes: 1))
        try insertV1Part("ses", id: "p", message: "m", created: ago(minutes: 1), updated: ago(minutes: 1),
                         data: v1StepFinish())
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.first?.observedAt, date(ago(minutes: 4)), "the owning message start, not the part time")
    }

    func testStoreSelectionMatchesFullLoad() throws {
        try createVendorSchema()
        // v1 only.
        try insertV1SessionRow("only_v1", updated: ago(minutes: 10))
        try insertV1Message("only_v1", id: "m1", created: ago(minutes: 3), updated: ago(minutes: 1))
        try insertV1Part("only_v1", id: "p1", message: "m1", created: ago(minutes: 1), updated: ago(minutes: 1), data: v1StepFinish(input: 11))
        // Equal-time migrated copy: v1 stays authoritative.
        try insertV1SessionRow("equal", updated: ago(minutes: 10))
        try insertV1Message("equal", id: "m2", created: ago(minutes: 3), updated: ago(minutes: 1))
        try insertV1Part("equal", id: "p2", message: "m2", created: ago(minutes: 1), updated: ago(minutes: 1), data: v1StepFinish(input: 22))
        try insertV2SessionRow("equal", updated: ago(minutes: 10))
        try insertV2Row("equal", id: "x2", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1), input: 99))
        // Newer v2 continuation: v2 wins.
        try insertV1SessionRow("newer", updated: ago(minutes: 10))
        try insertV1Message("newer", id: "m3", created: ago(minutes: 3), updated: ago(minutes: 1))
        try insertV1Part("newer", id: "p3", message: "m3", created: ago(minutes: 1), updated: ago(minutes: 1), data: v1StepFinish(input: 33))
        try insertV2SessionRow("newer", updated: ago(minutes: 5))
        try insertV2Row("newer", id: "x3", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1), input: 77))

        for (id, expected) in [("only_v1", 11), ("equal", 22), ("newer", 77)] {
            guard case .usage(let windowEvents) = try window(id) else { return XCTFail("expected usage for \(id)") }
            XCTAssertEqual(windowEvents.map(\.freshInputTokens), [expected], id)
            XCTAssertEqual(try events(for: id).map(\.freshInputTokens), [expected], "full load agrees for \(id)")
        }
    }

    func testForkClonedRowsExcluded() throws {
        try createVendorSchema()
        try insertV2SessionRow("fork", updated: ago(minutes: 1), created: ago(minutes: 10), parent: "root")
        try insertV2Row("fork", id: "cloned", type: "assistant", seq: 1, created: ago(minutes: 20), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 20), completed: ago(minutes: 1)))
        try insertV2Row("fork", id: "own", type: "assistant", seq: 2, created: ago(minutes: 5), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 5), completed: ago(minutes: 1)))
        guard case .usage(let events) = try window("fork") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.map(\.recordID), ["own-step-finish"], "rows before the fork's creation are inherited")
    }

    func testWindowParityWithFullLoad() throws {
        try vendorV2Session("ses", created: ago(minutes: 200))
        try insertV2Row("ses", id: "old", type: "assistant", seq: 1, created: ago(minutes: 150), updated: ago(minutes: 149),
                        data: completedAssistant(created: ago(minutes: 150), completed: ago(minutes: 149), input: 1))
        for index in 0..<4 {
            let start = ago(minutes: Double(25 - index * 5))
            try insertV2Row("ses", id: "a\(index)", type: "assistant", seq: index + 2, created: start, updated: start + 30_000,
                            data: completedAssistant(created: start, completed: start + 30_000, input: 10 + index, model: "m\(index % 2)"))
        }
        guard case .usage(let windowEvents) = try window("ses") else { return XCTFail("expected usage") }
        let since = date(ago(minutes: 120))
        let full = try events(for: "ses").filter { ($0.observedAt ?? .distantPast) >= since }
        XCTAssertEqual(windowEvents.map(ParityTuple.init), full.map(ParityTuple.init))
    }

    func testAnchorLinesAreDenseInWindow() throws {
        try vendorV2Session("ses")
        for index in 0..<3 {
            let start = ago(minutes: Double(10 - index * 3))
            try insertV2Row("ses", id: "a\(index)", type: "assistant", seq: index + 1, created: start, updated: start + 20_000,
                            data: completedAssistant(created: start, completed: start + 20_000))
        }
        guard case .usage(let events) = try window("ses") else { return XCTFail("expected usage") }
        XCTAssertEqual(events.map(\.anchorLine), [0, 1, 2])
    }

    // MARK: - Task 3: batch read in one transaction

    func testOneDatabaseOpenPerCall() throws {
        try createVendorSchema()
        for index in 0..<8 { try insertV2SessionRow("s\(index)", updated: ago(minutes: 1)) }
        let before = OpenCodeSqliteReader.databaseOpenCountForTesting
        let results = try XCTUnwrap(OpenCodeSqliteReader.recentUsage(
            databaseURL: dbURL,
            requests: (0..<8).map { OpenCodeRecentUsageRequest(sessionID: "s\($0)", previousTail: nil, forceReload: false) },
            now: now))
        XCTAssertEqual(OpenCodeSqliteReader.databaseOpenCountForTesting - before, 1)
        XCTAssertEqual(results.count, 8)
    }

    func testUnchangedTailSkipsRead() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1)))
        let first = try batch("ses", previousTail: nil)
        guard case .loaded(let tail, .usage) = first else { return XCTFail("expected a first load, got \(first)") }
        XCTAssertEqual(try batch("ses", previousTail: tail), .unchanged(tail: tail))
    }

    func testForceReloadRereads() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1)))
        guard case .loaded(let tail, _) = try batch("ses", previousTail: nil) else { return XCTFail("expected load") }
        guard case .loaded(let again, .usage) = try batch("ses", previousTail: tail, forceReload: true) else {
            return XCTFail("forceReload must re-read")
        }
        XCTAssertEqual(again, tail)
    }

    func testInPlaceEditCaughtByForceReload() throws {
        try vendorV2Session("ses")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1), input: 10))
        try insertV2Row("ses", id: "b", type: "assistant", seq: 2, created: ago(minutes: 2), updated: ago(minutes: 1),
                        data: completedAssistant(created: ago(minutes: 2), completed: ago(minutes: 1), input: 20))
        guard case .loaded(let tail, _) = try batch("ses", previousTail: nil) else { return XCTFail("expected load") }
        // An older row is rewritten without touching the tail row or the session row.
        try exec("UPDATE session_message SET data = \(sql(completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 1), input: 99))) WHERE id = 'a';")
        XCTAssertEqual(try batch("ses", previousTail: tail), .unchanged(tail: tail), "the tail cannot see it")
        guard case .loaded(_, .usage(let events)) = try batch("ses", previousTail: tail, forceReload: true) else {
            return XCTFail("the periodic reload must")
        }
        XCTAssertEqual(events.map(\.freshInputTokens), [99, 20])
    }

    func testQueryPlansUseIndexes() throws {
        try createVendorSchema()
        let plans = [
            (OpenCodeSqliteReader.recentV2WindowSQL, "session_message_session_time_created_id_idx"),
            (OpenCodeSqliteReader.recentV2TailSQL, "session_message_session_seq_idx"),
            (OpenCodeSqliteReader.recentV1MessageSQL, "message_session_time_created_id_idx"),
            (OpenCodeSqliteReader.recentV1PartSQL, "part_message_id_id_idx"),
            (OpenCodeSqliteReader.recentV1TailSQL, "message_session_time_created_id_idx"),
        ]
        for (statement, index) in plans {
            let plan = try queryPlan(statement)
            XCTAssertTrue(plan.contains(index), "\(statement)\n\(plan)")
            XCTAssertFalse(plan.contains("SCAN session_message"), plan)
            XCTAssertFalse(plan.contains("SCAN message"), plan)
            XCTAssertFalse(plan.contains("SCAN part"), plan)
        }
    }

    func testConsistentUnderConcurrentWALWriter() throws {
        try vendorV2Session("ses")
        try exec("PRAGMA journal_mode=WAL;")
        try insertV2Row("ses", id: "a", type: "assistant", seq: 1, created: ago(minutes: 3), updated: ago(minutes: 2),
                        data: completedAssistant(created: ago(minutes: 3), completed: ago(minutes: 2), input: 10))
        let writer = try openWriter()
        defer { sqlite3_close(writer) }
        let late = completedAssistant(created: ago(minutes: 1), completed: ago(minutes: 0.5), input: 50)
        OpenCodeSqliteReader.recentUsageAfterTailHookForTesting = {
            sqlite3_exec(writer, "INSERT INTO session_message VALUES ('b', 'ses', 'assistant', 2, \(self.ago(minutes: 1)), \(self.ago(minutes: 0.5)), \(self.sql(late)));", nil, nil, nil)
        }
        defer { OpenCodeSqliteReader.recentUsageAfterTailHookForTesting = nil }

        guard case .loaded(let tail, .usage(let events)) = try batch("ses", previousTail: nil) else {
            return XCTFail("expected load")
        }
        XCTAssertEqual(events.map(\.freshInputTokens), [10], "rows and tail come from one snapshot")
        OpenCodeSqliteReader.recentUsageAfterTailHookForTesting = nil
        guard case .loaded(let newTail, .usage(let next)) = try batch("ses", previousTail: tail) else {
            return XCTFail("the writer's row changes the tail")
        }
        XCTAssertNotEqual(newTail, tail)
        XCTAssertEqual(next.map(\.freshInputTokens), [10, 50])
    }

    private func batch(_ sessionID: String, previousTail: String?, forceReload: Bool = false) throws -> OpenCodeRecentUsageResult {
        let results = try XCTUnwrap(OpenCodeSqliteReader.recentUsage(
            databaseURL: dbURL,
            requests: [OpenCodeRecentUsageRequest(sessionID: sessionID, previousTail: previousTail, forceReload: forceReload)],
            now: now))
        return try XCTUnwrap(results[sessionID])
    }

    private func queryPlan(_ statement: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "plan", code: 1) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + statement, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "plan", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            lines.append(sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "")
        }
        return lines.joined(separator: "\n")
    }

    private func openWriter() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw NSError(domain: "writer", code: 1) }
        return db
    }

    private struct ParityTuple: Equatable {
        let recordID: String?, model: String?, fresh: Int, cacheRead: Int, cacheWrite5m: Int, output: Int, reasoning: Int
        let completedAt: Date?
        init(_ event: TelemetryUsageEvent) {
            recordID = event.recordID; model = event.model; fresh = event.freshInputTokens
            cacheRead = event.cacheReadTokens; cacheWrite5m = event.cacheWrite5mTokens
            output = event.outputTokens; reasoning = event.reasoningOutputTokens; completedAt = event.completedAt
        }
    }

    private func window(_ sessionID: String) throws -> OpenCodeRecentWindow {
        try XCTUnwrap(OpenCodeSqliteReader.recentWindow(databaseURL: dbURL, sessionID: sessionID, now: now))
    }

    private func completedAssistant(created: Int64, completed: Int64, input: Int = 100, model: String = "m") -> String {
        #"{"time":{"created":\#(created),"completed":\#(completed)},"agent":"build","model":{"id":"\#(model)","providerID":"p"},"content":[],"finish":"stop","tokens":{"input":\#(input),"output":5,"reasoning":2,"cache":{"read":10,"write":0}}}"#
    }

    private func v1StepFinish(input: Int = 3) -> String {
        #"{"type":"step-finish","reason":"stop","tokens":{"input":\#(input),"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}"#
    }

    private func vendorV2Session(_ id: String, created: Int64? = nil) throws {
        if !vendorSchemaCreated { try createVendorSchema() }
        try insertV2SessionRow(id, updated: ago(minutes: 1), created: created ?? ago(minutes: 180))
    }

    private func vendorV1Session(_ id: String) throws {
        if !vendorSchemaCreated { try createVendorSchema() }
        try insertV1SessionRow(id, updated: ago(minutes: 1))
    }

    private func insertV1SessionRow(_ id: String, updated: Int64) throws {
        try exec("""
        INSERT INTO session (id, project_id, slug, directory, title, version, time_created, time_updated)
        VALUES (\(sql(id)), 'proj', 's', '/tmp/repo', 't', '1.19.3', \(ago(minutes: 180)), \(updated));
        """)
    }

    private func insertV2SessionRow(_ id: String, updated: Int64, created: Int64? = nil, parent: String? = nil) throws {
        try exec("""
        INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated)
        VALUES (\(sql(id)), 'proj', \(parent.map(sql) ?? "NULL"), 's', '/tmp/repo', 't', '2.1.4', \(created ?? ago(minutes: 180)), \(updated));
        """)
    }

    private func insertV1Message(_ session: String, id: String, created: Int64, updated: Int64) throws {
        try exec("""
        INSERT INTO message VALUES (\(sql(id)), \(sql(session)), \(created), \(updated),
            '{"role":"assistant","time":{"created":\(created)},"modelID":"m","providerID":"p"}');
        """)
    }

    private func insertV1Part(_ session: String, id: String, message: String, created: Int64, updated: Int64,
                              data: String) throws {
        try exec("""
        INSERT INTO part VALUES (\(sql(id)), \(sql(message)), \(sql(session)), \(created), \(updated), \(sql(data)));
        """)
    }

    private var vendorSchemaCreated = false

    private func createVendorSchema() throws {
        try exec(OpenCodeVendorSchemaFixture.ddl)
        vendorSchemaCreated = true
    }

    // MARK: - Fixture

    private func events(for sessionID: String) throws -> [TelemetryUsageEvent] {
        let session = Session(id: sessionID, source: .opencode, startTime: nil, endTime: nil, model: nil,
                              filePath: dbURL.path, eventCount: 0, events: [])
        let scan = try XCTUnwrap(OpenCodeSqliteReader.loadTelemetry(for: session))
        return scan.result.telemetry.usageEvents
    }

    private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    private func assistant(created: Int64, completed: Int64?, model: String = "m") -> String {
        let completedField = completed.map { #","completed":\#($0)"# } ?? ""
        return #"{"time":{"created":\#(created)\#(completedField)},"agent":"build","model":{"id":"\#(model)","providerID":"p"},"content":[],"finish":"stop","tokens":{"input":100,"output":5,"reasoning":2,"cache":{"read":10,"write":0}}}"#
    }

    private func createV1Tables() throws {
        try exec("""
        CREATE TABLE session (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL,
            directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER, model TEXT
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        """)
    }

    private func createV2Tables() throws {
        try exec("""
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT,
            fork_session_id TEXT, fork_boundary TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL,
            path TEXT, title TEXT, version TEXT NOT NULL, agent TEXT, model TEXT,
            cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
            time_archived INTEGER, time_suspended INTEGER
        );
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
        """)
    }

    private func insertV1Session(_ id: String, created: Int64) throws {
        try exec("""
        INSERT INTO session VALUES (\(sql(id)), 'proj', NULL, 's', '/tmp/repo', 't', '1.19.3', \(created), \(created), NULL, NULL);
        """)
    }

    private func insertV2Session(_ id: String, created: Int64, parent: String? = nil) throws {
        try exec("""
        INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated)
        VALUES (\(sql(id)), 'proj', \(parent.map(sql) ?? "NULL"), 's', '/tmp/repo', 't', '2.1.2', \(created), \(created));
        """)
    }

    private func insertV2Row(_ session: String, id: String, type: String, seq: Int, created: Int64, updated: Int64,
                             data: String) throws {
        try exec("""
        INSERT INTO session_message VALUES (\(sql(id)), \(sql(session)), \(sql(type)), \(seq), \(created), \(updated), \(sql(data)));
        """)
    }

    private func sql(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func exec(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "OpenCodeRecentFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, statement, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenCodeRecentFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// Schema-only DDL of the five OpenCode tables, exactly as OpenCode v2.1.4 created
/// them. Captured read-only on 2026-10-26 with
/// `SELECT sql || ';' FROM sqlite_master WHERE sql IS NOT NULL AND tbl_name IN
/// ('session','message','part','session_v2','session_message') ORDER BY tbl_name, type DESC, name;`.
/// SHA-256 of the captured text: 6723b6208058c22f75f61678b7bf5771b9d0816246de9d94aef9e613bea61e41.
/// No row data. Unlike `OpenCodeV2StoreTests.createV2Tables()`, it includes the vendor
/// indexes the recent-usage queries depend on.
enum OpenCodeVendorSchemaFixture {
    static let ddl = """
    CREATE TABLE `message` (
    \t`id` text PRIMARY KEY,
    \t`session_id` text NOT NULL,
    \t`time_created` integer NOT NULL,
    \t`time_updated` integer NOT NULL,
    \t`data` text NOT NULL,
    \tCONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
    );
    CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);
    CREATE TABLE `part` (
    \t`id` text PRIMARY KEY,
    \t`message_id` text NOT NULL,
    \t`session_id` text NOT NULL,
    \t`time_created` integer NOT NULL,
    \t`time_updated` integer NOT NULL,
    \t`data` text NOT NULL,
    \tCONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
    );
    CREATE INDEX `part_message_id_id_idx` ON `part` (`message_id`,`id`);
    CREATE INDEX `part_session_idx` ON `part` (`session_id`);
    CREATE TABLE `session` (
    \t`id` text PRIMARY KEY,
    \t`project_id` text NOT NULL,
    \t`parent_id` text,
    \t`slug` text NOT NULL,
    \t`directory` text NOT NULL,
    \t`title` text NOT NULL,
    \t`version` text NOT NULL,
    \t`share_url` text,
    \t`summary_additions` integer,
    \t`summary_deletions` integer,
    \t`summary_files` integer,
    \t`summary_diffs` text,
    \t`revert` text,
    \t`permission` text,
    \t`time_created` integer NOT NULL,
    \t`time_updated` integer NOT NULL,
    \t`time_compacting` integer,
    \t`time_archived` integer, `workspace_id` text, `path` text, `agent` text, `model` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `metadata` text,
    \tCONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
    );
    CREATE INDEX `session_parent_idx` ON `session` (`parent_id`);
    CREATE INDEX `session_project_idx` ON `session` (`project_id`);
    CREATE INDEX `session_workspace_idx` ON `session` (`workspace_id`);
    CREATE TABLE "session_message" (
              `id` text PRIMARY KEY,
              `session_id` text NOT NULL,
              `type` text NOT NULL,
              `seq` integer NOT NULL,
              `time_created` integer NOT NULL,
              `time_updated` integer NOT NULL,
              `data` text NOT NULL,
              CONSTRAINT `fk_session_message_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
            );
    CREATE UNIQUE INDEX `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);
    CREATE INDEX `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);
    CREATE INDEX `session_message_session_type_seq_idx` ON `session_message` (`session_id`,`type`,`seq`);
    CREATE INDEX `session_message_time_created_idx` ON `session_message` (`time_created`);
    CREATE TABLE `session_v2` (
              `id` text PRIMARY KEY,
              `project_id` text NOT NULL,
              `workspace_id` text,
              `parent_id` text,
              `fork_session_id` text,
              `fork_boundary` text,
              `slug` text NOT NULL,
              `directory` text NOT NULL,
              `path` text,
              `title` text,
              `version` text NOT NULL,
              `share_url` text,
              `summary_additions` integer,
              `summary_deletions` integer,
              `summary_files` integer,
              `summary_diffs` text,
              `metadata` text,
              `cost` real DEFAULT 0 NOT NULL,
              `tokens_input` integer DEFAULT 0 NOT NULL,
              `tokens_output` integer DEFAULT 0 NOT NULL,
              `tokens_reasoning` integer DEFAULT 0 NOT NULL,
              `tokens_cache_read` integer DEFAULT 0 NOT NULL,
              `tokens_cache_write` integer DEFAULT 0 NOT NULL,
              `revert` text,
              `permission` text,
              `agent` text,
              `model` text,
              `time_created` integer NOT NULL,
              `time_updated` integer NOT NULL,
              `time_compacting` integer,
              `time_archived` integer,
              `time_suspended` integer, `resume_attempts` integer DEFAULT 0 NOT NULL, `time_idle` integer, `time_viewed` integer, `idle_outcome` text,
              CONSTRAINT `fk_session_v2_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
            );
    CREATE INDEX `session_v2_parent_idx` ON `session_v2` (`parent_id`);
    CREATE INDEX `session_v2_project_idx` ON `session_v2` (`project_id`);
    CREATE INDEX `session_v2_time_suspended_idx` ON `session_v2` (`time_suspended`) WHERE "session_v2"."time_suspended" is not null;
    CREATE INDEX `session_v2_workspace_idx` ON `session_v2` (`workspace_id`);
    """
}
