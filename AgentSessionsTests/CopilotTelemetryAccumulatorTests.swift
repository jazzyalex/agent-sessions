import XCTest
@testable import AgentSessions

/// Copilot states its configuration changes explicitly but reports tokens ONLY in
/// an end-of-process `session.shutdown` summary — there is no per-turn usage to
/// attribute. A resumed session appends a second shutdown for the second process,
/// so shutdowns are summed rather than deduplicated.
final class CopilotTelemetryAccumulatorTests: XCTestCase {

    private func modelChange(new: String, previous: String? = nil, effort: String? = nil,
                             at ts: String = "2025-12-18T21:32:06.000Z") -> String {
        var data: [String: Any] = ["newModel": new]
        if let previous { data["previousModel"] = previous }
        if let effort { data["reasoningEffort"] = effort }
        return json(["type": "session.model_change", "timestamp": ts, "data": data])
    }

    /// The per-model shape: `modelMetrics.<id>.usage`.
    private func shutdownWithModelMetrics(_ metrics: [String: [String: Int]],
                                          at ts: String = "2025-12-18T21:32:19.000Z") -> String {
        var models: [String: Any] = [:]
        for (model, usage) in metrics {
            models[model] = ["requests": ["count": 1], "usage": [
                "inputTokens": usage["input"] ?? 0, "outputTokens": usage["output"] ?? 0,
                "cacheReadTokens": usage["cacheRead"] ?? 0, "cacheWriteTokens": usage["cacheWrite"] ?? 0
            ]]
        }
        return json(["type": "session.shutdown", "timestamp": ts,
                     "data": ["shutdownType": "routine", "modelMetrics": models]])
    }

    /// The session-total shape: `tokenDetails`, with no per-model breakdown.
    private func shutdownWithTokenDetails(currentModel: String?, input: Int, output: Int,
                                          cacheRead: Int = 0, cacheWrite: Int = 0,
                                          at ts: String = "2025-12-18T21:32:19.000Z") -> String {
        var data: [String: Any] = [
            "shutdownType": "routine",
            "tokenDetails": ["input": ["tokenCount": input], "output": ["tokenCount": output],
                             "cache_read": ["tokenCount": cacheRead],
                             "cache_write": ["tokenCount": cacheWrite]],
            "modelMetrics": ["gpt-5-mini": ["requests": 2]]  // present but carrying no usage
        ]
        if let currentModel { data["currentModel"] = currentModel }
        return json(["type": "session.shutdown", "timestamp": ts, "data": data])
    }

    private func json(_ dict: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
    }

    private func slice(_ t: SessionTelemetry, model: String?) -> TelemetryUsageSlice? {
        t.usageSlices.first { $0.model == model }
    }

    // MARK: - Configuration

    func testModelChangeGivesInitialAndCurrent() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini", previous: "auto", effort: "medium"),
            modelChange(new: "claude-haiku-4.5", effort: "medium")
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5-mini")
        XCTAssertEqual(t.initialConfiguration?.reasoningEffort, "medium")
        XCTAssertEqual(t.currentConfiguration?.model, "claude-haiku-4.5")
        XCTAssertEqual(t.configurationChanges.filter { $0.field == .model }.count, 1)
        XCTAssertEqual(t.initialConfiguration?.provenance, .providerChangeRecord)
    }

    /// `previousModel: "auto"` is a placeholder for "not yet resolved", not a model
    /// the session ever ran on. Reading it would invent a change from a fake model.
    func testPreviousModelAutoIsNotTreatedAsAConfiguration() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini", previous: "auto")
        ])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5-mini")
        XCTAssertTrue(t.configurationChanges.isEmpty)
    }

    func testReasoningEffortChangeRecorded() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini", effort: "medium"),
            modelChange(new: "gpt-5-mini", effort: "high")
        ])
        let effortChanges = t.configurationChanges.filter { $0.field == .reasoningEffort }
        XCTAssertEqual(effortChanges.count, 1)
        XCTAssertEqual(effortChanges.first?.newValue, "high")
    }

    // MARK: - Usage

    func testPerModelMetricsProduceSlices() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini"),
            shutdownWithModelMetrics(["gpt-4.1": ["input": 1000, "output": 50, "cacheRead": 800]])
        ])
        XCTAssertEqual(slice(t, model: "gpt-4.1")?.freshInputTokens, 1000)
        XCTAssertEqual(slice(t, model: "gpt-4.1")?.outputTokens, 50)
        XCTAssertEqual(slice(t, model: "gpt-4.1")?.cacheReadTokens, 800)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["session.shutdown.modelMetrics"])
        XCTAssertEqual(t.usageEvents.first?.usageFamily, "session.shutdown.modelMetrics")
        XCTAssertNil(t.usageEvents.first?.contextInputTokens,
                     "a process-lifetime summary is not a request context")
    }

    /// `tokenDetails` and `modelMetrics.usage` describe the SAME tokens. Reading
    /// both from one shutdown record would double the session.
    func testTokenDetailsUsedOnlyWhenModelMetricsCarryNoUsage() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini"),
            shutdownWithTokenDetails(currentModel: "gpt-5-mini", input: 100, output: 15, cacheRead: 5)
        ])
        XCTAssertEqual(slice(t, model: "gpt-5-mini")?.freshInputTokens, 100)
        XCTAssertEqual(slice(t, model: "gpt-5-mini")?.outputTokens, 15)
        XCTAssertEqual(t.usageSummary?.topLineTokens, 120)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["session.shutdown.tokenDetails"])
        XCTAssertEqual(t.usageEvents.first?.usageFamily, "session.shutdown.tokenDetails")
    }

    func testModelMetricsWinOverTokenDetailsInTheSameRecord() {
        let mixed = json(["type": "session.shutdown", "timestamp": "2025-12-18T21:32:19.000Z",
                          "data": ["currentModel": "gpt-5-mini",
                                   "tokenDetails": ["input": ["tokenCount": 999],
                                                    "output": ["tokenCount": 999]],
                                   "modelMetrics": ["gpt-5-mini": ["usage": ["inputTokens": 100,
                                                                            "outputTokens": 15]]]]])
        let t = CopilotTelemetryAccumulator.accumulate(lines: [modelChange(new: "gpt-5-mini"), mixed])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 115, "not 115 + 1998")
    }

    /// A `usage` object that is present but carries no recognized token keys is not
    /// a per-model breakdown — it is an empty shell. Treating it as one suppresses
    /// the `tokenDetails` fallback and silently discards the session's entire token
    /// count.
    func testEmptyUsageObjectFallsBackToTokenDetails() {
        let shell = json(["type": "session.shutdown", "timestamp": "2025-12-18T21:32:19.000Z",
                          "data": ["currentModel": "gpt-5-mini",
                                   "tokenDetails": ["input": ["tokenCount": 100],
                                                    "output": ["tokenCount": 15]],
                                   "modelMetrics": ["gpt-5-mini": ["usage": [:] as [String: Any]]]]])
        let t = CopilotTelemetryAccumulator.accumulate(lines: [modelChange(new: "gpt-5-mini"), shell])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 115)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["session.shutdown.tokenDetails"])
    }

    /// The same failure one step further in: `usage` carries the real keys but every
    /// value is zero. Gating the fallback on "did the keys parse" still reports a
    /// silent zero here; the gate has to be "did this produce any tokens".
    func testAllZeroUsageValuesFallBackToTokenDetails() {
        let zeros = json(["type": "session.shutdown", "timestamp": "2025-12-18T21:32:19.000Z",
                          "data": ["currentModel": "gpt-5-mini",
                                   "tokenDetails": ["input": ["tokenCount": 100],
                                                    "output": ["tokenCount": 15]],
                                   "modelMetrics": ["gpt-5-mini": ["usage": ["inputTokens": 0,
                                                                            "outputTokens": 0,
                                                                            "cacheReadTokens": 0,
                                                                            "cacheWriteTokens": 0]]]]])
        let t = CopilotTelemetryAccumulator.accumulate(lines: [modelChange(new: "gpt-5-mini"), zeros])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 115)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["session.shutdown.tokenDetails"])
    }

    /// A model that genuinely spent nothing must not suppress a sibling that did.
    func testZeroModelDoesNotSuppressNonZeroSibling() {
        let mixed = json(["type": "session.shutdown", "timestamp": "2025-12-18T21:32:19.000Z",
                          "data": ["currentModel": "gpt-5-mini",
                                   "tokenDetails": ["input": ["tokenCount": 999],
                                                    "output": ["tokenCount": 999]],
                                   "modelMetrics": [
                                       "gpt-5-mini": ["usage": ["inputTokens": 0, "outputTokens": 0]],
                                       "claude-haiku-4.5": ["usage": ["inputTokens": 100, "outputTokens": 15]]
                                   ]]])
        let t = CopilotTelemetryAccumulator.accumulate(lines: [modelChange(new: "gpt-5-mini"), mixed])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 115, "per-model still wins; tokenDetails not added")
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["session.shutdown.modelMetrics"])
        XCTAssertNil(slice(t, model: "gpt-5-mini"), "a model that spent nothing gets no slice")
    }

    /// A resume appends a second process's shutdown. Each reports only its own
    /// lifetime, so they sum.
    func testMultipleShutdownsSum() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini"),
            shutdownWithModelMetrics(["gpt-5-mini": ["input": 100, "output": 10]]),
            shutdownWithModelMetrics(["gpt-5-mini": ["input": 50, "output": 5]])
        ])
        XCTAssertEqual(slice(t, model: "gpt-5-mini")?.freshInputTokens, 150)
        XCTAssertEqual(slice(t, model: "gpt-5-mini")?.outputTokens, 15)
        XCTAssertEqual(t.usageEvents.count, 2)
    }

    func testAllZeroShutdownContributesNothing() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [
            modelChange(new: "gpt-5-mini"),
            shutdownWithTokenDetails(currentModel: "gpt-5-mini", input: 0, output: 0)
        ])
        XCTAssertEqual(t.usageSummary?.topLineTokens, 0)
    }

    func testNoShutdownMeansNoTokensButStillAConfiguration() {
        let t = CopilotTelemetryAccumulator.accumulate(lines: [modelChange(new: "gpt-5-mini")])
        XCTAssertEqual(t.initialConfiguration?.model, "gpt-5-mini")
        XCTAssertEqual(t.usageSummary?.hasComponentBreakdown, false,
                       "a session still running has no usage summary to price")
        XCTAssertTrue(t.usageSlices.isEmpty)
    }

    func testSourceIsCopilot() {
        XCTAssertEqual(CopilotTelemetryAccumulator.accumulate(lines: [String]()).source, .copilot)
    }

    // MARK: - Real fixtures

    func testRealFixturesParseWithoutPhantomChanges() throws {
        for name in ["small.jsonl", "large.jsonl", "schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL("agents/copilot/\(name)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let t = CopilotTelemetryAccumulator.accumulate(lines: lines)
            for change in t.configurationChanges {
                XCTAssertNotNil(change.newValue, "\(name)")
                XCTAssertNotEqual(change.newValue, "auto", "\(name): 'auto' is not a model")
            }
            if let summary = t.usageSummary {
                XCTAssertEqual(summary.topLineTokens,
                               t.usageSlices.reduce(0) { $0 + $1.topLineTokens }, "\(name)")
            }
        }
    }

    func testSchemaDriftFixtureReadsPerModelUsage() throws {
        let url = FixturePaths.stage0FixtureURL("agents/copilot/schema_drift.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let t = CopilotTelemetryAccumulator.accumulate(lines: lines)
        XCTAssertEqual(slice(t, model: "gpt-4.1")?.freshInputTokens, 1000)
        XCTAssertEqual(slice(t, model: "gpt-4.1")?.cacheReadTokens, 800)
    }
}
