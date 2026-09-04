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
                                         priceTableUpdated: "2026-08-30",
                                         priceTableRevision: 7)
        let event = TelemetryUsageEvent(
            recordID: "request-1", observedAt: cfg.observedAt, anchorLine: 4,
            usageFamily: "token_count", ownership: .session,
            model: "gpt-5.6-sol", reasoningEffort: "medium", speed: "standard",
            freshInputTokens: 12_757, cacheReadTokens: 3_584,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
            outputTokens: 81, reasoningOutputTokens: 63,
            contextInputTokens: 16_341, apiEquivalentUSD: 1.25,
            priceTableRevision: 7, priceTableUpdated: "2026-08-30")
        let weekly = TelemetryWeeklyQuotaEstimate(
            status: .estimated, percentPoints: 0.5, unavailableReason: nil,
            percentPointsPerAPIDollar: 0.4, accountScoped: true,
            sourceFamily: "oauth", quotaResetAt: Date(timeIntervalSince1970: 8_000),
            quotaObservedAt: Date(timeIntervalSince1970: 2_100), quotaPrecision: "exact",
            calculatedAt: Date(timeIntervalSince1970: 2_200), priceTableRevision: 7)
        let telemetry = SessionTelemetry(source: .codex,
                                         initialConfiguration: cfg,
                                         currentConfiguration: cfg,
                                         configurationChanges: [change],
                                         usageSlices: [slice],
                                         usageEvents: [event],
                                         usageSummary: summary,
                                         costEstimate: cost,
                                         weeklyQuotaEstimate: weekly,
                                         parserVersion: SessionTelemetry.parserVersion)
        let data = try JSONEncoder().encode(telemetry)
        let decoded = try JSONDecoder().decode(SessionTelemetry.self, from: data)
        XCTAssertEqual(decoded, telemetry)
    }

    func testOlderCodablePayloadDefaultsNewEvidenceFields() throws {
        let cost = TelemetryCostEstimate(apiEquivalentUSD: 1,
                                         unpricedModels: [],
                                         missingPriceComponents: [],
                                         priceTableUpdated: "2026-08-30")
        let telemetry = SessionTelemetry(source: .codex,
                                         initialConfiguration: nil,
                                         currentConfiguration: nil,
                                         configurationChanges: [],
                                         usageSlices: [],
                                         usageSummary: nil,
                                         costEstimate: cost,
                                         parserVersion: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(telemetry))
            as? [String: Any])
        object.removeValue(forKey: "usageEvents")
        object.removeValue(forKey: "weeklyQuotaEstimate")
        var encodedCost = try XCTUnwrap(object["costEstimate"] as? [String: Any])
        encodedCost.removeValue(forKey: "priceTableRevision")
        object["costEstimate"] = encodedCost

        let decoded = try JSONDecoder().decode(
            SessionTelemetry.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.usageEvents, [])
        XCTAssertNil(decoded.weeklyQuotaEstimate)
        XCTAssertEqual(decoded.costEstimate?.priceTableRevision, 0)
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
