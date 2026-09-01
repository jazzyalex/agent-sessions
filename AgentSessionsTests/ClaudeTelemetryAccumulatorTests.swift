import XCTest
@testable import AgentSessions

/// Claude's transcripts are adversarial for a configuration timeline: they carry
/// nested subagent records, `<synthetic>` error placeholders, and assistant records
/// that omit `effort` entirely. Every exclusion rule tested here exists because the
/// checked-in stage0 fixture triggers it.
final class ClaudeTelemetryAccumulatorTests: XCTestCase {

    // MARK: - Line builders

    private func assistant(model: String?,
                           effort: String?,
                           id: String? = nil,
                           usage: [String: Any]? = nil,
                           isSidechain: Bool = false,
                           at ts: String = "2026-08-26T10:00:00.000Z") -> String {
        var message: [String: Any] = [:]
        if let model { message["model"] = model }
        if let id { message["id"] = id }
        if let usage { message["usage"] = usage }
        var obj: [String: Any] = ["type": "assistant", "timestamp": ts,
                                  "isSidechain": isSidechain, "message": message]
        if let effort { obj["effort"] = effort }
        return json(obj)
    }

    private func usage(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                       flatWrite: Int = 0, write5m: Int? = nil, write1h: Int? = nil,
                       speed: String = "standard") -> [String: Any] {
        var u: [String: Any] = ["input_tokens": input, "output_tokens": output,
                                "cache_read_input_tokens": cacheRead,
                                "cache_creation_input_tokens": flatWrite,
                                "speed": speed]
        if write5m != nil || write1h != nil {
            u["cache_creation"] = ["ephemeral_5m_input_tokens": write5m ?? 0,
                                   "ephemeral_1h_input_tokens": write1h ?? 0]
        }
        return u
    }

    private func json(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    private func slice(_ t: SessionTelemetry, model: String?, speed: String = "standard") -> TelemetryUsageSlice? {
        t.usageSlices.first { $0.model == model && $0.speed == speed }
    }

    // MARK: - Configuration timeline

    func testFirstObservedConfigIsInitial() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5))
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "claude-opus-5")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "medium")
        XCTAssertEqual(t.initialConfiguration?.provenance, .inferredFirstObservation,
                       "Claude never records a session-start configuration")
    }

    /// `<synthetic>` is an error placeholder, not a model. Counting it produces two
    /// phantom changes per occurrence (real → synthetic → real).
    func testSyntheticModelNeverEntersTimeline() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "<synthetic>", effort: nil, id: "m2", usage: usage()),
            assistant(model: "claude-opus-5", effort: "medium", id: "m3", usage: usage(input: 10, output: 5))
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty)
        XCTAssertEqual(t.currentConfiguration?.model, "claude-opus-5")
    }

    func testSyntheticModelContributesNoTokens() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "<synthetic>", effort: nil, id: "m1", usage: usage(input: 999, output: 999))
        ])
        XCTAssertNil(slice(t, model: "<synthetic>"))
        XCTAssertEqual(t.usageSlices.count, 0)
    }

    /// Nested subagents run on their own model. Their tokens are real API spend and
    /// must count; their model must not rewrite the parent's timeline.
    func testSidechainRecordsCountTokensButNotConfig() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-haiku-4-5", effort: "low", id: "m2",
                      usage: usage(input: 100, output: 50), isSidechain: true)
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty, "a sidechain model is not a parent configuration change")
        XCTAssertEqual(t.currentConfiguration?.model, "claude-opus-5")
        XCTAssertEqual(slice(t, model: "claude-haiku-4-5")?.freshInputTokens, 100, "subagent tokens are real spend")
        XCTAssertEqual(slice(t, model: "claude-haiku-4-5")?.outputTokens, 50)
    }

    func testEffortObservedBeforeModelBackfillsWithoutChange() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: nil, effort: "medium"),
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5))
        ])
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "medium")
        XCTAssertEqual(t.initialConfiguration?.model, "claude-opus-5")
        XCTAssertTrue(t.configurationChanges.isEmpty)
    }

    /// 10,466 of 47,671 sampled assistant records carry no effort. Absence is not
    /// a change.
    func testAbsentEffortMidStreamEmitsNoChange() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "high", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-opus-5", effort: nil, id: "m2", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-opus-5", effort: "high", id: "m3", usage: usage(input: 10, output: 5))
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty)
        XCTAssertEqual(t.currentConfiguration?.reasoningEffort, "high")
    }

    func testEffortChangeRecorded() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-opus-5", effort: "high", id: "m2", usage: usage(input: 10, output: 5))
        ])
        XCTAssertEqual(t.configurationChanges.count, 1)
        XCTAssertEqual(t.configurationChanges.first?.field, .reasoningEffort)
        XCTAssertEqual(t.configurationChanges.first?.newValue, "high")
        XCTAssertEqual(t.configurationChanges.first?.provenance, .assistantRecord)
    }

    func testModelChangeRecordedOnce() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 1, output: 1)),
            assistant(model: "claude-opus-5", effort: "medium", id: "m2", usage: usage(input: 1, output: 1)),
            assistant(model: "claude-sonnet-5", effort: "medium", id: "m3", usage: usage(input: 1, output: 1))
        ])
        XCTAssertEqual(t.configurationChanges.count, 1)
    }

    // MARK: - Dedup

    func testDuplicateMessageIDCountedOnce() {
        let u = usage(input: 100, output: 50)
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: u),
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: u)
        ])
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.freshInputTokens, 100)
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.outputTokens, 50)
    }

    /// The id is consumed BEFORE any token check, matching
    /// ClaudeRunwayTokenActivityParser: a zero-usage record still claims its id.
    func testZeroTokenUsageRecordConsumesMessageID() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage()),
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 100, output: 50))
        ])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 0, "the id was already spent by the zero-token record")
    }

    func testRecordWithoutUsageNeverConsumesMessageID() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: nil),
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 100, output: 50))
        ])
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.freshInputTokens, 100)
    }

    // MARK: - Usage

    func testFiveMinuteAndOneHourWritesKeptSeparate() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1",
                      usage: usage(flatWrite: 300, write5m: 100, write1h: 200))
        ])
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.cacheWrite5mTokens, 100)
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.cacheWrite1hTokens, 200)
    }

    /// The sub-object breaks down the SAME total the flat field reports. Summing
    /// both double-charges every cache write.
    func testSubObjectReplacesFlatFieldNeverSums() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1",
                      usage: usage(flatWrite: 100, write5m: 0, write1h: 100))
        ])
        let s = slice(t, model: "claude-opus-5")
        XCTAssertEqual(s?.cacheWrite5mTokens, 0)
        XCTAssertEqual(s?.cacheWrite1hTokens, 100)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 100, "not 200")
    }

    func testLegacyUndifferentiatedWriteCountsAs5m() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(flatWrite: 100))
        ])
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.cacheWrite5mTokens, 100)
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.cacheWrite1hTokens, 0)
    }

    /// Fast mode is a whole second rate set (2x), so it cannot share a slice with
    /// standard-tier tokens of the same model.
    func testFastAndStandardAreSeparateSlices() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1",
                      usage: usage(input: 10, output: 5, speed: "standard")),
            assistant(model: "claude-opus-5", effort: "medium", id: "m2",
                      usage: usage(input: 20, output: 10, speed: "fast"))
        ])
        XCTAssertEqual(t.usageSlices.count, 2)
        XCTAssertEqual(slice(t, model: "claude-opus-5", speed: "fast")?.freshInputTokens, 20)
        XCTAssertEqual(slice(t, model: "claude-opus-5", speed: "standard")?.freshInputTokens, 10)
    }

    /// Without carry-forward this splits into a junk "unknown effort" row for what
    /// is one configuration.
    func testEffortAbsentRecordJoinsCarriedEffortSlice() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "high", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-opus-5", effort: nil, id: "m2", usage: usage(input: 10, output: 5))
        ])
        XCTAssertEqual(t.usageSlices.count, 1)
        XCTAssertEqual(t.usageSlices.first?.reasoningEffort, "high")
        XCTAssertEqual(t.usageSlices.first?.freshInputTokens, 20)
    }

    func testMixedModelsProducePerModelSlices() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5)),
            assistant(model: "claude-haiku-4-5", effort: "medium", id: "m2", usage: usage(input: 20, output: 10))
        ])
        XCTAssertEqual(t.usageSlices.count, 2)
        XCTAssertEqual(slice(t, model: "claude-haiku-4-5")?.outputTokens, 10)
    }

    func testCacheReadCounted() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1",
                      usage: usage(input: 10, output: 5, cacheRead: 500))
        ])
        XCTAssertEqual(slice(t, model: "claude-opus-5")?.cacheReadTokens, 500)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 515)
    }

    // MARK: - Summary

    /// Task 7 gates cost on this flag; leaving it false makes every Claude session
    /// silently unpriceable.
    func testUsageSummaryHasComponentBreakdownWhenUsageSeen() {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: [
            assistant(model: "claude-opus-5", effort: "medium", id: "m1", usage: usage(input: 10, output: 5))
        ])
        XCTAssertEqual(t.usageSummary?.hasComponentBreakdown, true)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["message.usage"])
        XCTAssertEqual(t.usageSummary?.usageFamilyConflict, false)
    }

    func testUsageSummaryNilOnlyWhenNoAssistantRecords() {
        let userOnly = json(["type": "user", "timestamp": "2026-08-26T10:00:00.000Z"])
        XCTAssertNil(ClaudeTelemetryAccumulator.accumulate(lines: [userOnly]).usageSummary)
        // An assistant record with no usage still means "this file has assistant
        // records", so the summary exists and reports zero.
        let noUsage = assistant(model: "claude-opus-5", effort: "medium")
        XCTAssertNotNil(ClaudeTelemetryAccumulator.accumulate(lines: [noUsage]).usageSummary)
    }

    func testSourceIsClaude() {
        XCTAssertEqual(ClaudeTelemetryAccumulator.accumulate(lines: [String]()).source, .claude)
    }
}
