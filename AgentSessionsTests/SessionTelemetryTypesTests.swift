import XCTest
@testable import AgentSessions

final class SessionTelemetryTypesTests: XCTestCase {

    // Reasoning tokens are a SUBSET of output in both providers' logs. Adding
    // them as a separate term double-counts every thinking token — the same rule
    // CodexRunwayModel.dollarsPerHour enforces for the live runway.
    func testTopLineExcludesReasoningSubset() {
        var slice = TelemetryUsageSlice(model: "claude-opus-5", reasoningEffort: "high", speed: "standard")
        slice.freshInputTokens = 10
        slice.cacheReadTokens = 20
        slice.cacheWrite5mTokens = 5
        slice.cacheWrite1hTokens = 5
        slice.outputTokens = 40
        slice.reasoningOutputTokens = 30
        XCTAssertEqual(slice.topLineTokens, 80)
    }

    func testEmptySliceIsEmptyEvenWithReasoningTokens() {
        var slice = TelemetryUsageSlice(model: "m", reasoningEffort: nil, speed: "standard")
        slice.reasoningOutputTokens = 100
        XCTAssertTrue(slice.isEmpty)
        XCTAssertEqual(slice.topLineTokens, 0)
    }

    // Speed is part of a slice's identity, not a display detail: Anthropic fast
    // mode is a whole second rate set, so a fast slice and a standard slice of the
    // same model must never merge.
    func testSpeedParticipatesInEquality() {
        let standard = TelemetryUsageSlice(model: "claude-opus-5", reasoningEffort: nil, speed: "standard")
        let fast = TelemetryUsageSlice(model: "claude-opus-5", reasoningEffort: nil, speed: "fast")
        XCTAssertNotEqual(standard, fast)
    }

    func testTelemetryRoundTripsThroughCodable() throws {
        let cfg = SessionConfiguration(model: "gpt-5.6-codex",
                                       reasoningEffort: "medium",
                                       observedAt: Date(timeIntervalSince1970: 1_000),
                                       anchorLine: 3,
                                       provenance: .effectiveTurnContext)
        let change = ConfigurationChange(field: .model,
                                         oldValue: "gpt-5.6-codex",
                                         newValue: "gpt-5.6-sol",
                                         observedAt: Date(timeIntervalSince1970: 2_000),
                                         anchorLine: 9,
                                         provenance: .effectiveTurnContext)
        var slice = TelemetryUsageSlice(model: "gpt-5.6-sol", reasoningEffort: "medium", speed: "standard")
        slice.freshInputTokens = 12_757
        slice.cacheReadTokens = 3_584
        slice.outputTokens = 81
        slice.reasoningOutputTokens = 63
        let summary = TelemetryUsageSummary(topLineTokens: slice.topLineTokens,
                                            hasComponentBreakdown: true,
                                            recordedTotalTokens: 16_422,
                                            usageFamilies: ["token_count"],
                                            usageFamilyConflict: false)
        let cost = TelemetryCostEstimate(apiEquivalentUSD: 1.25,
                                         unpricedModels: [],
                                         missingPriceComponents: [],
                                         priceTableUpdated: "2026-08-30")
        let telemetry = SessionTelemetry(source: .codex,
                                         initialConfiguration: cfg,
                                         currentConfiguration: cfg,
                                         configurationChanges: [change],
                                         usageSlices: [slice],
                                         usageSummary: summary,
                                         costEstimate: cost,
                                         parserVersion: SessionTelemetry.parserVersion)
        let data = try JSONEncoder().encode(telemetry)
        let decoded = try JSONDecoder().decode(SessionTelemetry.self, from: data)
        XCTAssertEqual(decoded, telemetry)
    }

    // An unavailable dollar result must carry a reason. nil USD with both arrays
    // empty is reserved for "nothing to price", never for a pricing failure.
    func testUnavailableCostCarriesReason() {
        let cost = TelemetryCostEstimate(apiEquivalentUSD: nil,
                                         unpricedModels: ["mystery-model-9"],
                                         missingPriceComponents: [],
                                         priceTableUpdated: "2026-08-30")
        XCTAssertNil(cost.apiEquivalentUSD)
        XCTAssertFalse(cost.unpricedModels.isEmpty)
    }
}
