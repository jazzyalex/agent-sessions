import XCTest
@testable import AgentSessions

/// Pi is the cleanest of the four supported providers: it emits explicit
/// `model_change` and `thinking_level_change` events, and every assistant message
/// carries its own complete usage block.
final class PiTelemetryAccumulatorTests: XCTestCase {

    private func modelChange(_ modelId: String, provider: String = "pi-fixture",
                             at ts: String = "2026-05-12T01:02:27.667Z") -> String {
        json(["type": "model_change", "timestamp": ts, "provider": provider, "modelId": modelId])
    }

    private func thinkingChange(_ level: String, at ts: String = "2026-05-12T01:02:27.667Z") -> String {
        json(["type": "thinking_level_change", "timestamp": ts, "thinkingLevel": level])
    }

    private func assistantMessage(model: String?,
                                  input: Int = 0, output: Int = 0,
                                  cacheRead: Int = 0, cacheWrite: Int = 0,
                                  total: Int? = nil,
                                  at ts: String = "2026-05-12T01:02:27.762Z") -> String {
        var message: [String: Any] = ["role": "assistant", "provider": "pi-fixture"]
        if let model { message["model"] = model }
        message["usage"] = ["input": input, "output": output,
                            "cacheRead": cacheRead, "cacheWrite": cacheWrite,
                            "totalTokens": total ?? (input + output),
                            "cost": ["input": 0, "output": 0, "total": 0]]
        return json(["type": "message", "timestamp": ts, "message": message])
    }

    private func userMessage(at ts: String = "2026-05-12T01:02:27.673Z") -> String {
        json(["type": "message", "timestamp": ts,
              "message": ["role": "user", "content": [["type": "text", "text": "hi"]]]])
    }

    private func json(_ dict: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
    }

    private func slice(_ t: SessionTelemetry, model: String?) -> TelemetryUsageSlice? {
        t.usageSlices.first { $0.model == model }
    }

    // MARK: - Configuration

    func testModelAndThinkingLevelBecomeInitialConfiguration() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"),
            thinkingChange("off"),
            assistantMessage(model: "pi-model-a", input: 12, output: 7)
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "pi-model-a")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "off")
        XCTAssertEqual(t.source, .pi)
    }

    func testModelChangeRecorded() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"),
            assistantMessage(model: "pi-model-a", input: 1, output: 1),
            modelChange("pi-model-b"),
            assistantMessage(model: "pi-model-b", input: 1, output: 1)
        ])
        XCTAssertEqual(t.configurationChanges.filter { $0.field == .model }.count, 1)
        XCTAssertEqual(t.currentConfiguration?.model, "pi-model-b")
    }

    func testThinkingLevelChangeRecordedAsEffort() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), thinkingChange("off"), thinkingChange("high")
        ])
        let effortChanges = t.configurationChanges.filter { $0.field == .reasoningEffort }
        XCTAssertEqual(effortChanges.count, 1)
        XCTAssertEqual(effortChanges.first?.newValue, "high")
    }

    func testRepeatedIdenticalChangesEmitNothing() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), modelChange("pi-model-a"), thinkingChange("off"), thinkingChange("off")
        ])
        XCTAssertTrue(t.configurationChanges.isEmpty)
    }

    // MARK: - Usage

    func testAssistantUsageSummed() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), thinkingChange("off"),
            assistantMessage(model: "pi-model-a", input: 12, output: 7),
            assistantMessage(model: "pi-model-a", input: 12, output: 7)
        ])
        XCTAssertEqual(slice(t, model: "pi-model-a")?.freshInputTokens, 24)
        XCTAssertEqual(slice(t, model: "pi-model-a")?.outputTokens, 14)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 38)
        XCTAssertEqual(t.usageEvents.count, 2)
        XCTAssertEqual(t.usageEvents.first?.contextInputTokens, 12)
        XCTAssertTrue(t.usageEvents.allSatisfy { $0.ownership == .session })
    }

    func testCacheReadAndWriteCounted() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"),
            assistantMessage(model: "pi-model-a", input: 10, output: 5, cacheRead: 100, cacheWrite: 20)
        ])
        let s = slice(t, model: "pi-model-a")
        XCTAssertEqual(s?.cacheReadTokens, 100)
        // Pi reports one undifferentiated cache-write number, like Codex.
        XCTAssertEqual(s?.cacheWrite5mTokens, 20)
        XCTAssertEqual(s?.cacheWrite1hTokens, 0)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 135)
    }

    /// Pins the input convention, verified 2026-08-31 against real `~/.pi` sessions:
    /// `totalTokens == input + output + cacheRead`, so `input` is FRESH and cache
    /// reads are additional. Numbers are taken from an observed record. Under the
    /// Codex convention (input already including cache reads) this total would be
    /// 1959, so this test fails loudly if anyone "corrects" it that way.
    func testInputIsFreshAndCacheReadIsAdditional() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("gpt-5.4-mini"),
            assistantMessage(model: "gpt-5.4-mini", input: 1201, output: 758,
                             cacheRead: 1024, cacheWrite: 0, total: 2983)
        ])
        let s = slice(t, model: "gpt-5.4-mini")
        XCTAssertEqual(s?.freshInputTokens, 1201)
        XCTAssertEqual(s?.cacheReadTokens, 1024)
        XCTAssertEqual(s?.outputTokens, 758)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 2983,
                       "must equal Pi's own totalTokens for the same record")
        XCTAssertEqual(t.usageEvents.first?.contextInputTokens, 2225)
    }

    func testUserMessagesContributeNothing() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), userMessage(),
            assistantMessage(model: "pi-model-a", input: 10, output: 5)
        ])
        XCTAssertEqual(t.usageSlices.count, 1)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 15)
    }

    func testEffortCarriesForwardOntoSlices() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), thinkingChange("high"),
            assistantMessage(model: "pi-model-a", input: 10, output: 5)
        ])
        XCTAssertEqual(t.usageSlices.first?.reasoningEffort, "high")
    }

    func testMessageModelWinsOverCarriedModelForItsOwnTokens() {
        // A message that names its own model is attributed to that model, even if
        // no model_change announced it.
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"),
            assistantMessage(model: "pi-model-b", input: 10, output: 5)
        ])
        XCTAssertEqual(slice(t, model: "pi-model-b")?.freshInputTokens, 10)
    }

    func testSummaryNilWhenNoRecordsAtAll() {
        XCTAssertNil(PiTelemetryAccumulator.accumulate(lines: [String]()).usageSummary)
    }

    func testPiSlicesAlwaysStandardSpeed() {
        let t = PiTelemetryAccumulator.accumulate(lines: [
            modelChange("pi-model-a"), assistantMessage(model: "pi-model-a", input: 1, output: 1)
        ])
        XCTAssertTrue(t.usageSlices.allSatisfy { $0.speed == "standard" })
    }

    // MARK: - Real fixture

    func testRealFixtureParses() throws {
        let url = FixturePaths.stage0FixtureURL("agents/pi/small.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let t = PiTelemetryAccumulator.accumulate(lines: lines)
        XCTAssertEqual(t.initialConfiguration?.model, "pi-fixture-model")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "off")
        // Two assistant messages, 12 in / 7 out each.
        XCTAssertEqual(t.usageSummary?.topLineTokens, 38)
        XCTAssertEqual(t.usageSummary?.hasComponentBreakdown, true)
        for change in t.configurationChanges {
            XCTAssertNotNil(change.newValue)
        }
    }
}
