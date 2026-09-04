import XCTest
@testable import AgentSessions

/// Codex records the effective model and effort for every turn in `turn_context`,
/// and cumulative token counters in `token_count`. The hard parts are therefore
/// deltas (counters are cumulative, and reset mid-file on resume) and carry-forward
/// (a context line that omits a field is not a change to nil).
final class CodexTelemetryAccumulatorTests: XCTestCase {

    // MARK: - Line builders

    private func context(_ model: String?, _ effort: String?, at ts: String = "2026-08-26T10:00:00.000Z") -> String {
        var payload: [String: Any] = [:]
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        return json(["timestamp": ts, "type": "turn_context", "payload": payload])
    }

    /// A cumulative `token_count` record, the shape that carries `total_token_usage`.
    private func tokenCount(input: Int, cached: Int = 0, cacheWrite: Int = 0,
                            output: Int, reasoning: Int = 0, total: Int? = nil,
                            at ts: String = "2026-08-26T10:00:01.000Z") -> String {
        let usage: [String: Any] = [
            "input_tokens": input, "cached_input_tokens": cached,
            "cache_write_input_tokens": cacheWrite, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": total ?? (input + output)
        ]
        return json(["timestamp": ts, "type": "event_msg",
                     "payload": ["type": "token_count",
                                 "info": ["total_token_usage": usage, "last_token_usage": usage]]])
    }

    private func turnCompleted(input: Int, cached: Int = 0, output: Int,
                               at ts: String = "2026-08-26T10:00:02.000Z") -> String {
        json(["timestamp": ts, "type": "event_msg",
              "payload": ["type": "turn.completed",
                          "usage": ["input_tokens": input, "cached_input_tokens": cached,
                                    "output_tokens": output, "total_tokens": input + output]]])
    }

    private func json(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    private func slice(_ t: SessionTelemetry, model: String?) -> TelemetryUsageSlice? {
        t.usageSlices.first { $0.model == model }
    }

    // MARK: - Configuration timeline

    func testInitialConfigAndSingleChange() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("gpt-5.6-codex", "medium"),
            context("gpt-5.6-sol", "medium")
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "medium")
        XCTAssertEqual(t.currentConfiguration?.model, "gpt-5.6-sol")
        XCTAssertEqual(t.configurationChanges.count, 1)
        XCTAssertEqual(t.configurationChanges.first?.field, .model)
        XCTAssertEqual(t.configurationChanges.first?.oldValue, "gpt-5.6-codex")
        XCTAssertEqual(t.configurationChanges.first?.newValue, "gpt-5.6-sol")
    }

    func testRepeatedIdenticalContextNoChange() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("gpt-5.6-codex", "medium"),
            context("gpt-5.6-codex", "medium"),
            context("gpt-5.6-codex", "medium")
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty)
    }

    /// Carry-forward: a context line that omits effort is not a change to nil.
    func testTurnContextMissingEffortDoesNotEmitNilChange() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("gpt-5.6-codex", "medium"),
            context("gpt-5.6-codex", nil)
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty)
        XCTAssertEqual(t.currentConfiguration?.reasoningEffort, "medium")
    }

    func testTurnContextEmptyModelIsNotAnObservation() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("", "high"),
            context("gpt-5.6-codex", "high")
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertTrue(t.configurationChanges.isEmpty, "empty string is absence, not a value")
    }

    /// Symmetric backfill: whichever field is seen first, the other fills in from
    /// its own first sighting without counting as a change.
    func testEffortObservedBeforeModelBackfillsWithoutChange() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context(nil, "xhigh"),
            context("gpt-5.6-codex", "xhigh")
        ])
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "xhigh")
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertTrue(t.configurationChanges.isEmpty)
    }

    func testAnchorLineAndObservedAtRecordedOnInitialConfig() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            "",
            "not json at all",
            context("gpt-5.6-codex", "medium", at: "2026-08-26T10:00:00.000Z")
        ])
        XCTAssertEqual(t.initialConfiguration?.anchorLine, 2, "raw line index, blank lines counted")
        XCTAssertEqual(t.initialConfiguration?.observedAt,
                       ISO8601DateFormatter.telemetryTestParse("2026-08-26T10:00:00.000Z"))
        XCTAssertEqual(t.initialConfiguration?.provenance, .effectiveTurnContext)
    }

    /// Old rollouts write the fields at the top level with no `payload` wrapper.
    func testPayloadlessLineReadsTopLevelFields() {
        let line = json(["timestamp": "2026-08-26T10:00:00.000Z", "type": "turn_context",
                         "model": "gpt-5.6-codex", "effort": "low"])
        let t = CodexTelemetryAccumulator.accumulate(lines: [line])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "low")
    }

    // MARK: - Usage

    func testCumulativeDeltasAttributedPerModel() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, output: 10, total: 110),
            context("model-b", "medium"),
            tokenCount(input: 250, output: 40, total: 290)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 100)
        XCTAssertEqual(slice(t, model: "model-a")?.outputTokens, 10)
        XCTAssertEqual(slice(t, model: "model-b")?.freshInputTokens, 150)
        XCTAssertEqual(slice(t, model: "model-b")?.outputTokens, 30)
    }

    /// A resume rewinds the cumulative counters. Delta arithmetic across that
    /// boundary would go negative; the accumulator starts a new epoch instead.
    func testCumulativeResetStartsNewEpoch() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, output: 10, total: 110),
            tokenCount(input: 50, output: 5, total: 55)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 150)
        XCTAssertEqual(slice(t, model: "model-a")?.outputTokens, 15)
        XCTAssertEqual(t.usageSummary?.recordedTotalTokens, 165, "each epoch's final total, summed")
    }

    func testTokenCountWithNullInfoContributesNothing() {
        let nullInfo = json(["timestamp": "2026-08-26T10:00:01.000Z", "type": "event_msg",
                             "payload": ["type": "token_count", "info": NSNull()]])
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"), nullInfo
        ])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 0)
        XCTAssertTrue(t.usageSlices.allSatisfy(\.isEmpty))
    }

    func testUsageBeforeAnyTurnContextLandsInNilModelSlice() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            tokenCount(input: 100, output: 10, total: 110)
        ])
        XCTAssertEqual(slice(t, model: nil)?.freshInputTokens, 100)
    }

    func testFreshInputClampedWhenCachedExceedsInputDelta() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, cached: 10, output: 0, total: 100),
            tokenCount(input: 110, cached: 60, output: 0, total: 110)
        ])
        // Δinput 10 − Δcached 50 is negative; fresh clamps at 0 rather than
        // subtracting tokens that were already counted.
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 90)
        XCTAssertEqual(slice(t, model: "model-a")?.cacheReadTokens, 60)
    }

    func testReasoningSubsetNotAddedToTopLine() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, output: 40, reasoning: 30, total: 140)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.reasoningOutputTokens, 30)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 140, "100 fresh + 40 output; reasoning is inside output")
    }

    func testCodexSlicesAlwaysStandardSpeed() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, output: 10, total: 110)
        ])
        XCTAssertTrue(t.usageSlices.allSatisfy { $0.speed == "standard" })
    }

    func testCacheWriteTokensCounted() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, cacheWrite: 25, output: 10, total: 110)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.cacheWrite5mTokens, 25)
        XCTAssertEqual(slice(t, model: "model-a")?.cacheWrite1hTokens, 0, "Codex has no TTL split")
    }

    // MARK: - Usage families

    func testTurnCompletedFamilySummed() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            turnCompleted(input: 100, output: 10),
            turnCompleted(input: 50, output: 5)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 150, "per-turn records sum, never delta")
        XCTAssertEqual(slice(t, model: "model-a")?.outputTokens, 15)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["turn.completed"])
    }

    func testBothFamiliesNeverDoubleCounted() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            tokenCount(input: 100, output: 10, total: 110),
            turnCompleted(input: 100, output: 10)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 100, "cumulative family wins outright")
        XCTAssertEqual(slice(t, model: "model-a")?.outputTokens, 10)
        XCTAssertTrue(t.usageSummary?.usageFamilyConflict == true)
        XCTAssertEqual(t.usageSummary?.usageFamilies.sorted(), ["token_count", "turn.completed"])
        XCTAssertEqual(t.usageEvents.count, 1, "losing-family request evidence must not survive")
        XCTAssertEqual(t.usageEvents.first?.usageFamily, "token_count")
    }

    func testCumulativeRecordsEmitRequestLevelEventsWithContext() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("gpt-5.6-sol", "xhigh"),
            tokenCount(input: 200_000, cached: 50_000, output: 10),
            tokenCount(input: 500_001, cached: 100_000, output: 20)
        ])
        XCTAssertEqual(t.usageEvents.count, 2)
        XCTAssertEqual(t.usageEvents[0].contextInputTokens, 200_000)
        XCTAssertEqual(t.usageEvents[1].contextInputTokens, 300_001)
        XCTAssertEqual(t.usageEvents[1].freshInputTokens, 250_001)
        XCTAssertEqual(t.usageEvents[1].cacheReadTokens, 50_000)
        XCTAssertEqual(t.usageEvents[1].reasoningEffort, "xhigh")
        XCTAssertEqual(t.usageEvents[1].ownership, .session)
    }

    func testMalformedCumulativeMarkerDoesNotSuppressValidTurnUsage() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            turnCompleted(input: 100, cached: 20, output: 10)
        ])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 110)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["token_count", "turn.completed"])
        XCTAssertFalse(t.usageSummary?.usageFamilyConflict == true,
                       "a malformed marker is not a second positive usage source")
        XCTAssertEqual(t.usageEvents.first?.usageFamily, "turn.completed")
    }

    /// Same two records as the test above, in the other order. The authority rule
    /// is "cumulative wins if it appears ANYWHERE in the file", so the result must
    /// be identical — a streaming flag that only looks backward gets this wrong and
    /// counts the same turn twice.
    func testBothFamiliesNeverDoubleCountedWhenTurnCompletedComesFirst() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [
            context("model-a", "medium"),
            turnCompleted(input: 100, output: 10),
            tokenCount(input: 100, output: 10, total: 110)
        ])
        XCTAssertEqual(slice(t, model: "model-a")?.freshInputTokens, 100)
        XCTAssertEqual(slice(t, model: "model-a")?.outputTokens, 10)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 110)
        XCTAssertTrue(t.usageSummary?.usageFamilyConflict == true)
    }

    /// Order must not change the answer for any interleaving.
    func testFamilyAuthorityIsOrderIndependent() {
        let ctx = context("model-a", "medium")
        let tc = tokenCount(input: 100, output: 10, total: 110)
        let turn = turnCompleted(input: 100, output: 10)
        let aFirst = CodexTelemetryAccumulator.accumulate(lines: [ctx, tc, turn])
        let bFirst = CodexTelemetryAccumulator.accumulate(lines: [ctx, turn, tc])
        XCTAssertEqual(aFirst.usageSlices, bFirst.usageSlices)
        XCTAssertEqual(aFirst.usageSummary?.topLineTokens, bFirst.usageSummary?.topLineTokens)
    }

    func testLegacyTotalOnly() {
        let legacy = json(["timestamp": "2026-08-26T10:00:01.000Z", "type": "event_msg",
                           "payload": ["type": "token_count",
                                       "info": ["total_token_usage": ["total_tokens": 4_242]]]])
        let t = CodexTelemetryAccumulator.accumulate(lines: [context("model-a", "medium"), legacy])
        XCTAssertEqual(t.usageSummary?.hasComponentBreakdown, false)
        XCTAssertEqual(t.usageSummary?.recordedTotalTokens, 4_242)
        XCTAssertTrue(t.usageSlices.allSatisfy(\.isEmpty))
    }

    func testEmptyTranscriptProducesEmptyTelemetry() {
        let t = CodexTelemetryAccumulator.accumulate(lines: [String]())
        XCTAssertNil(t.initialConfiguration)
        XCTAssertNil(t.usageSummary)
        XCTAssertTrue(t.usageSlices.isEmpty)
        XCTAssertTrue(t.usageEvents.isEmpty)
        XCTAssertEqual(t.source, .codex)
    }
}

extension ISO8601DateFormatter {
    /// Test helper mirroring `ClaudeRunwayLog.date`'s fractional-seconds parsing.
    static func telemetryTestParse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
