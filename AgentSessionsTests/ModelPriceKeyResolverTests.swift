import XCTest
@testable import AgentSessions

final class ModelPriceKeyResolverTests: XCTestCase {
    private let aliases = ["gemini 3.5 flash": "gemini-3.5-flash",
                           "claude sonnet 4.6": "claude-sonnet-4-6",
                           "muse-spark-1.3": "muse-spark-1.3"]

    private func resolve(_ raw: String?) -> ResolvedPriceKey? {
        ModelPriceKeyResolver.resolve(raw, aliases: aliases)
    }

    func testEvidenceStringsResolve() {
        XCTAssertEqual(resolve("anthropic/claude-sonnet-5"),
                       ResolvedPriceKey(key: "claude-sonnet-5", viaFreeRoute: false))
        XCTAssertEqual(resolve("openai/gpt-5.5"),
                       ResolvedPriceKey(key: "gpt-5.5", viaFreeRoute: false))
        XCTAssertEqual(resolve("z-ai/glm-5.3-flash"),
                       ResolvedPriceKey(key: "glm-5.3-flash", viaFreeRoute: false))
        XCTAssertEqual(resolve("claude-haiku-4.5"),
                       ResolvedPriceKey(key: "claude-haiku-4-5", viaFreeRoute: false))
        XCTAssertEqual(resolve("Gemini 3.5 Flash (Medium)"),
                       ResolvedPriceKey(key: "gemini-3.5-flash", viaFreeRoute: false))
        XCTAssertEqual(resolve("Claude Sonnet 4.6 (Thinking)"),
                       ResolvedPriceKey(key: "claude-sonnet-4-6", viaFreeRoute: false))
    }

    func testFreeRoutesKeepTheFlagThroughAliasLookup() {
        XCTAssertEqual(resolve("muse-spark-1.3-contributor-free"),
                       ResolvedPriceKey(key: "muse-spark-1.3", viaFreeRoute: true))
        XCTAssertEqual(resolve("cline-free/deepseek-v4.1-flash"),
                       ResolvedPriceKey(key: "deepseek-v4.1-flash", viaFreeRoute: true))
        XCTAssertEqual(resolve("minimax-m2.5-free"),
                       ResolvedPriceKey(key: "minimax-m2.5", viaFreeRoute: true))
        XCTAssertEqual(resolve("poolside/laguna-s-2.1:free"),
                       ResolvedPriceKey(key: "laguna-s-2.1", viaFreeRoute: true))
    }

    func testUnrecognizedShapesPassThroughUnchanged() {
        // Unknown provider prefix is not stripped.
        XCTAssertEqual(resolve("acme/claude-sonnet-5")?.key, "acme/claude-sonnet-5")
        // Two slashes: not a single provider prefix.
        XCTAssertEqual(resolve("openrouter/anthropic/claude-sonnet-5")?.key,
                       "openrouter/anthropic/claude-sonnet-5")
        // A parenthetical that is not an effort word stays.
        XCTAssertEqual(resolve("some-model (beta)")?.key, "some-model (beta)")
        // The dot rule is Claude-only.
        XCTAssertEqual(resolve("gpt-5.5")?.key, "gpt-5.5")
        // Preview suffix is never normalized away.
        XCTAssertEqual(resolve("claude-sonnet-5-preview")?.key, "claude-sonnet-5-preview")
    }

    func testEmptyInputsReturnNil() {
        XCTAssertNil(resolve(nil))
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("   "))
        XCTAssertNil(resolve("-free"))
        XCTAssertNil(resolve("cline-free/"))
    }
}
