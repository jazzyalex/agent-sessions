import XCTest
@testable import AgentSessions

/// The footer's fallback-source tag ("via claude.ai" / "via CLI probe") used to render
/// as a second stacked line under the meter, which grew the fixed 26pt strip and broke
/// the footer layout. The layout itself isn't unit-testable, but the mapping is — and
/// the original bug's hidden half was that BOTH fallback sources trip it, not just the
/// web path that happened to get reported.
final class FooterSourceTagTests: XCTestCase {

    func testWebSourcesAreTaggedViaClaudeAI() {
        XCTAssertEqual(CockpitFooterView.fallbackSourceTag(for: .webEndpoint), "via claude.ai")
        XCTAssertEqual(CockpitFooterView.fallbackSourceTag(for: .cachedWeb), "via claude.ai")
    }

    func testProbeSourceIsTaggedViaCLIProbe() {
        XCTAssertEqual(CockpitFooterView.fallbackSourceTag(for: .tmuxUsage), "via CLI probe")
    }

    /// The common signed-in case carries no tag at all — an unlabelled meter is the
    /// signal that the provider's usual source served the reading.
    func testUnknownAndNilSourcesAreUntagged() {
        XCTAssertNil(CockpitFooterView.fallbackSourceTag(for: nil))
    }
}
