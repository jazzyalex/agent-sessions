import XCTest
@testable import AgentSessions

final class PriceManifestV2Tests: XCTestCase {
    private func rate(_ input: Double) -> RunwayModelPrice {
        RunwayModelPrice(standard: RunwayRateSet(inputPerMTok: input, cachedInputPerMTok: input / 10,
                                                 outputPerMTok: input * 5, cacheWritePerMTok: nil,
                                                 cacheWrite1hPerMTok: nil),
                         fast: nil, longContext: nil, inferenceGeoUSMultiplier: nil)
    }

    private func snapshot(_ models: [String: RunwayModelPrice],
                          aliases: [String: String] = [:]) -> RunwayPriceSnapshot {
        RunwayPriceSnapshot(models: models, aliases: aliases, updatedDate: "2026-10-13",
                            revision: 1, manifestFingerprint: "test")
    }

    // MARK: - Strict matching

    func testVendorKeyDoesNotPriceAnExtendedSlug() {
        let s = snapshot(["kimi-k2.7-code": rate(1), "glm-4.7": rate(2)])
        XCTAssertNotNil(s.price(forModel: "kimi-k2.7-code"))
        XCTAssertNil(s.price(forModel: "kimi-k2.7-code-v2"),
                     "a variant must not inherit the base model's rate")
        XCTAssertNil(s.price(forModel: "glm-4.70"))
        XCTAssertNil(s.price(forModel: "glm-4.7-preview"))
    }

    func testVendorKeyAcceptsDatedSnapshots() {
        let s = snapshot(["glm-4.7": rate(2)])
        XCTAssertEqual(s.price(forModel: "glm-4.7-20260901")?.inputPerMTok, 2)
        XCTAssertEqual(s.price(forModel: "glm-4.7-2026-09-01")?.inputPerMTok, 2)
        XCTAssertNil(s.price(forModel: "glm-4.7-2026090"))
    }

    func testCodexAutoReviewIsExactOrDatedOnly() {
        let s = RunwayPriceTable.makeForTesting().snapshot()
        XCTAssertNotNil(s.price(forModel: "codex-auto-review"))
        XCTAssertNil(s.price(forModel: "codex-auto-review-v2"))
    }

    func testTableAndSnapshotAgreeOnEveryLookup() {
        let table = RunwayPriceTable.makeForTesting()
        let s = table.snapshot()
        for slug in ["claude-opus-5", "claude-sonnet-5-20260101", "claude-sonnet-5-preview",
                     "gpt-5.5", "gpt-5.5-2026-01-01", "gpt-5.5-turbo", "codex-auto-review",
                     "kimi-k2.7-code-v2", ""] {
            XCTAssertEqual(table.price(forModel: slug), s.price(forModel: slug), slug)
        }
    }

    // MARK: - Resolved lookup

    func testResolvedPricePrefersTheRawSlug() {
        let s = snapshot(["gpt-5.5": rate(5)])
        let hit = s.resolvedPrice(forModel: "gpt-5.5")
        XCTAssertEqual(hit?.price.inputPerMTok, 5)
        XCTAssertEqual(hit?.viaFreeRoute, false)
    }

    func testResolvedPriceUsesResolverAndReportsFreeRoute() {
        let s = snapshot(["minimax-m2.5": rate(3), "gemini-3.5-flash": rate(4)],
                         aliases: ["gemini 3.5 flash": "gemini-3.5-flash"])
        XCTAssertEqual(s.resolvedPrice(forModel: "minimax-m2.5-free")?.price.inputPerMTok, 3)
        XCTAssertEqual(s.resolvedPrice(forModel: "minimax-m2.5-free")?.viaFreeRoute, true)
        XCTAssertEqual(s.resolvedPrice(forModel: "Gemini 3.5 Flash (Medium)")?.price.inputPerMTok, 4)
        XCTAssertNil(s.resolvedPrice(forModel: "big-pickle"))
        XCTAssertNil(s.resolvedPrice(forModel: nil))
    }
}
