import XCTest
@testable import AgentSessions

final class SearchCoordinatorTests: XCTestCase {
    func testFTSEligibleSources_excludesSourcesWithoutFTSIndex() {
        XCTAssertEqual(
            SearchCoordinator.ftsEligibleSources(from: [.cursor, .codebuddy, .workbuddy]),
            []
        )

        XCTAssertEqual(
            SearchCoordinator.ftsEligibleSources(from: [.codex, .codebuddy, .workbuddy]),
            [.codex]
        )
    }
}
