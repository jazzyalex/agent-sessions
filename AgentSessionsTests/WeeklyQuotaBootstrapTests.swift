import XCTest
@testable import AgentSessions

/// The bootstrap is what makes `Wk` show a number seconds after launch instead of
/// waiting hours for a 1pp quota tick. These tests pin the parts that failed in
/// practice: the anchor/account filter, both window slots, and completing at all.
final class WeeklyQuotaBootstrapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wkboot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let anchor = Date(timeIntervalSince1970: 1_788_651_434)

    /// One turn: `last_token_usage` is the turn's OWN usage, and `rate_limits`
    /// rides on the same line, which is what makes a transcript a quota trace.
    private func turn(output: Int, resetsAt: Date, at: Date, slot: String = "primary") -> String {
        let other = slot == "primary" ? "secondary" : "primary"
        return """
        {"timestamp":"\(ISO8601DateFormatter().string(from: at))","type":"token_count","payload":{"info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\(output),"total_tokens":\(output)}},"rate_limits":{"\(slot)":{"used_percent":5.0,"window_minutes":10080,"resets_at":\(resetsAt.timeIntervalSince1970)},"\(other)":null}}}
        """
    }

    private func modelLine(_ slug: String, at: Date) -> String {
        """
        {"timestamp":"\(ISO8601DateFormatter().string(from: at))","type":"turn_context","payload":{"model":"\(slug)"}}
        """
    }

    private func write(_ lines: [String], name: String) throws {
        try lines.joined(separator: "\n").write(
            to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func scan(usedPercentPoints: Double = 5) -> WeeklyQuotaBootstrapResult? {
        CodexWeeklyQuotaBootstrapScanner.scan(
            root: root, resetsAt: anchor, windowMinutes: 10080,
            usedPercentPoints: usedPercentPoints,
            priceTable: RunwayPriceTable.makeForTesting(),
            now: anchor.addingTimeInterval(-3600))
    }

    /// The Claude scan feeds the same calibration the runway `$` view is weighted by,
    /// so it must price a 1-hour cache write at 2× input exactly as the runway does —
    /// otherwise the weekly denominator and the `$/h` numerator describe different
    /// money for the same tokens.
    func testClaudeScanPricesOneHourCacheWritesAtDoubleInput() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([claudeUsageLine(id: "m1", at: at, oneHourCacheWrite: 1_000_000)], name: "c.jsonl")

        let result = ClaudeWeeklyQuotaBootstrapScanner.scan(
            root: root, resetsAt: anchor, windowMinutes: 10080, usedPercentPoints: 5,
            priceTable: RunwayPriceTable.makeForTesting(),
            now: anchor.addingTimeInterval(-3600))

        // 1M cache-creation tokens, all 1-hour, at claude-opus-5's $10/MTok 1-hour
        // rate — not the $6.25 five-minute rate the flat column used to charge.
        XCTAssertEqual(result?.dollars ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(result?.unpricedVolumeShare ?? 1, 0, accuracy: 0.0001)
    }

    /// Real records carry the flat total AND the sub-object that breaks it down, so
    /// the scan must not bill the same tokens through both.
    func testClaudeScanDoesNotDoubleCountFlatAndSplitCacheCreation() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([claudeUsageLine(id: "m1", at: at, oneHourCacheWrite: 1_000_000,
                                   flatCacheCreation: 1_000_000)], name: "c.jsonl")

        let result = ClaudeWeeklyQuotaBootstrapScanner.scan(
            root: root, resetsAt: anchor, windowMinutes: 10080, usedPercentPoints: 5,
            priceTable: RunwayPriceTable.makeForTesting(),
            now: anchor.addingTimeInterval(-3600))

        XCTAssertEqual(result?.dollars ?? 0, 10.0, accuracy: 0.001,
                       "the sub-object replaces the flat total rather than adding to it")
    }

    private func claudeUsageLine(id: String,
                                 at: Date,
                                 oneHourCacheWrite: Int,
                                 flatCacheCreation: Int? = nil,
                                 model: String = "claude-opus-5") -> String {
        let flat = flatCacheCreation.map { "\"cache_creation_input_tokens\":\($0)," } ?? ""
        return "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: at))\","
            + "\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{"
            + "\"input_tokens\":0,\"output_tokens\":0,\"cache_read_input_tokens\":0,\(flat)"
            + "\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,"
            + "\"ephemeral_1h_input_tokens\":\(oneHourCacheWrite)}}}}"
    }

    func testPricesTurnsInsideTheWindow() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([modelLine("gpt-5.6", at: at), turn(output: 1_000_000, resetsAt: anchor, at: at)],
                  name: "a.jsonl")
        let result = scan()
        // 1M output tokens of gpt-5.6 at $20/MTok.
        XCTAssertEqual(result?.dollars ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(result?.unpricedVolumeShare ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(result?.percentPointsPerDollar ?? 0, 5.0 / 20.0, accuracy: 0.0001)
    }

    /// The account filter. Two accounts share one machine, so their sessions
    /// interleave in one directory; another anchor's dollars in the denominator
    /// would bias the calibration low.
    func testExcludesTurnsFromAnotherAnchor() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        let foreign = anchor.addingTimeInterval(-3 * 24 * 3600)
        try write([modelLine("gpt-5.6", at: at), turn(output: 1_000_000, resetsAt: anchor, at: at)],
                  name: "mine.jsonl")
        try write([modelLine("gpt-5.6", at: at), turn(output: 9_000_000, resetsAt: foreign, at: at)],
                  name: "theirs.jsonl")
        XCTAssertEqual(scan()?.dollars ?? 0, 20.0, accuracy: 0.001,
                       "another account's activity must stay out of the denominator")
    }

    /// Weekly is `primary` on an account with no 5h window and `secondary` on one
    /// that has it (Plus has the 5h window, Pro-lite does not). Reading only
    /// `primary` silently never calibrates for Plus users.
    func testFindsWeeklyWindowInEitherSlot() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([modelLine("gpt-5.6", at: at),
                   turn(output: 1_000_000, resetsAt: anchor, at: at, slot: "secondary")],
                  name: "plus.jsonl")
        XCTAssertEqual(scan()?.dollars ?? 0, 20.0, accuracy: 0.001,
                       "weekly in the secondary slot must still be found")
    }

    /// Provider `resets_at` drifts by a few seconds between samples; the tolerance
    /// must absorb that or a real window fragments into two anchors.
    func testToleratesSmallAnchorDrift() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([modelLine("gpt-5.6", at: at),
                   turn(output: 1_000_000, resetsAt: anchor.addingTimeInterval(-7), at: at)],
                  name: "drift.jsonl")
        XCTAssertEqual(scan()?.dollars ?? 0, 20.0, accuracy: 0.001)
    }

    func testReportsUnpricedShareRatherThanVoiding() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([modelLine("gpt-5.6", at: at), turn(output: 1_000_000, resetsAt: anchor, at: at),
                   modelLine("mystery-model-xyz", at: at), turn(output: 1_000_000, resetsAt: anchor, at: at)],
                  name: "mixed.jsonl")
        let result = scan()
        XCTAssertEqual(result?.dollars ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(result?.unpricedVolumeShare ?? 0, 0.5, accuracy: 0.01)
    }

    func testRejectsWindowWithTooLittleConsumption() throws {
        let at = anchor.addingTimeInterval(-2 * 3600)
        try write([modelLine("gpt-5.6", at: at), turn(output: 1_000_000, resetsAt: anchor, at: at)],
                  name: "a.jsonl")
        XCTAssertNil(scan(usedPercentPoints: 0.5))
    }

    func testIgnoresTurnsBeforeTheWindowOpened() throws {
        let before = anchor.addingTimeInterval(-8 * 24 * 3600)
        try write([modelLine("gpt-5.6", at: before), turn(output: 1_000_000, resetsAt: anchor, at: before)],
                  name: "old.jsonl")
        XCTAssertNil(scan(), "activity predating the window must not be counted")
    }
}
