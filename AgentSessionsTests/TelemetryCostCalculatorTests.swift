import XCTest
@testable import AgentSessions

/// Pricing fails closed on purpose: a session's dollar figure exists to be compared
/// against other sessions, and a partial sum corrupts that comparison invisibly.
/// "Unavailable, because model X has no price" is honest and actionable; an
/// understated number is neither.
final class TelemetryCostCalculatorTests: XCTestCase {

    /// The bundled table, with no cached manifest overlaid, so expectations here are
    /// stable and hand-computable.
    private func table() -> RunwayPriceTable {
        RunwayPriceTable(loadBundled: true, readCache: false)
    }

    private let oneMillion = 1_000_000

    private func slice(_ model: String?, speed: String = "standard",
                       fresh: Int = 0, cacheRead: Int = 0, write5m: Int = 0,
                       write1h: Int = 0, output: Int = 0) -> TelemetryUsageSlice {
        TelemetryUsageSlice(model: model, reasoningEffort: nil, speed: speed,
                            freshInputTokens: fresh, cacheReadTokens: cacheRead,
                            cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h,
                            outputTokens: output)
    }

    // MARK: - Priced

    func testMixedModelSessionSumsPerSlice() {
        // opus-5 standard: 1M fresh @ $5 + 1M output @ $25 = $30
        // sonnet-5:        1M cache read @ $0.2 + 1M 1h write @ $4 = $4.20
        let result = TelemetryCostCalculator.estimate(slices: [
            slice("claude-opus-5", fresh: oneMillion, output: oneMillion),
            slice("claude-sonnet-5", cacheRead: oneMillion, write1h: oneMillion)
        ], priceTable: table())
        XCTAssertEqual(try XCTUnwrap(result.apiEquivalentUSD), 34.2, accuracy: 0.0001)
        XCTAssertTrue(result.unpricedModels.isEmpty)
        XCTAssertTrue(result.missingPriceComponents.isEmpty)
    }

    /// Fast mode is billed from its own rate set, not by scaling the standard one.
    func testFastTierPricedFromFastRateSet() {
        let fast = TelemetryCostCalculator.estimate(
            slices: [slice("claude-opus-5", speed: "fast", fresh: oneMillion, output: oneMillion)],
            priceTable: table())
        XCTAssertEqual(try XCTUnwrap(fast.apiEquivalentUSD), 60.0, accuracy: 0.0001)

        let standard = TelemetryCostCalculator.estimate(
            slices: [slice("claude-opus-5", fresh: oneMillion, output: oneMillion)],
            priceTable: table())
        XCTAssertEqual(try XCTUnwrap(standard.apiEquivalentUSD), 30.0, accuracy: 0.0001)
    }

    func testLongestPrefixMatchPricesDatedSlug() {
        let result = TelemetryCostCalculator.estimate(
            slices: [slice("claude-sonnet-5-20260101", output: oneMillion)],
            priceTable: table())
        XCTAssertEqual(try XCTUnwrap(result.apiEquivalentUSD), 10.0, accuracy: 0.0001)
    }

    func testPriceTableUpdatedIsStamped() {
        let t = table()
        let result = TelemetryCostCalculator.estimate(
            slices: [slice("claude-opus-5", fresh: 10)], priceTable: t)
        XCTAssertEqual(result.priceTableUpdated, t.updatedDate)
        XCTAssertFalse(result.priceTableUpdated.isEmpty)
    }

    // MARK: - Fail closed

    func testUnknownModelMakesWholeSessionUnavailable() {
        let result = TelemetryCostCalculator.estimate(slices: [
            slice("claude-opus-5", fresh: oneMillion, output: oneMillion),
            slice("mystery-model-9", fresh: oneMillion)
        ], priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD, "a partial total would understate, silently")
        XCTAssertEqual(result.unpricedModels, ["mystery-model-9"])
    }

    func testNilModelWithTokensIsUnpriced() {
        let result = TelemetryCostCalculator.estimate(
            slices: [slice(nil, fresh: oneMillion)], priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD)
        XCTAssertEqual(result.unpricedModels, ["(unknown)"])
    }

    /// A model with no fast rate set must NOT be billed at standard: silently
    /// halving a fast session is the exact failure the tier split prevents.
    func testFastRecordOnModelWithoutFastRatesIsUnavailable() {
        let result = TelemetryCostCalculator.estimate(
            slices: [slice("claude-sonnet-5", speed: "fast", fresh: oneMillion)],
            priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD)
        XCTAssertEqual(result.missingPriceComponents, ["claude-sonnet-5:fast"])
    }

    func testPositiveCacheWriteWithNoWriteRateIsUnavailable() {
        // gpt-5.5 ships cacheWritePerMTok: null.
        let result = TelemetryCostCalculator.estimate(
            slices: [slice("gpt-5.5", write5m: oneMillion)], priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD)
        XCTAssertEqual(result.missingPriceComponents, ["gpt-5.5:cacheWrite5m"])
    }

    func testPositiveOneHourWriteWithNoOneHourRateIsUnavailable() {
        let result = TelemetryCostCalculator.estimate(
            slices: [slice("gpt-5.5", write1h: oneMillion)], priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD)
        XCTAssertEqual(result.missingPriceComponents, ["gpt-5.5:cacheWrite1h"])
    }

    // MARK: - Escapes

    /// A slice that never actually ran cannot make a real session unpriceable.
    func testZeroTokenUnknownModelDoesNotPoisonResult() {
        let result = TelemetryCostCalculator.estimate(slices: [
            slice("claude-opus-5", fresh: oneMillion, output: oneMillion),
            slice("mystery-model-9")
        ], priceTable: table())
        XCTAssertEqual(try XCTUnwrap(result.apiEquivalentUSD), 30.0, accuracy: 0.0001)
        XCTAssertTrue(result.unpricedModels.isEmpty)
    }

    /// Nothing to price is not a pricing failure — nil with no reasons.
    func testNoSlicesIsUnavailableWithoutReasons() {
        let result = TelemetryCostCalculator.estimate(slices: [], priceTable: table())
        XCTAssertNil(result.apiEquivalentUSD)
        XCTAssertTrue(result.unpricedModels.isEmpty)
        XCTAssertTrue(result.missingPriceComponents.isEmpty)
    }

    func testDuplicateCausesReportedOnce() {
        let result = TelemetryCostCalculator.estimate(slices: [
            slice("mystery-model-9", fresh: 10),
            slice("mystery-model-9", output: 10)
        ], priceTable: table())
        XCTAssertEqual(result.unpricedModels, ["mystery-model-9"])
    }
}
