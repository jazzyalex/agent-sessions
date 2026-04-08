import XCTest
@testable import AgentSessions

final class NewProviderDiscoverabilityTests: XCTestCase {

    // MARK: - SessionSource Metadata

    func testVersionIntroducedIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.versionIntroduced.isEmpty, "\(source) missing versionIntroduced")
        }
    }

    func testFeatureDescriptionIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.featureDescription.isEmpty, "\(source) missing featureDescription")
        }
    }

    func testCursorVersionIntroduced() {
        XCTAssertEqual(SessionSource.cursor.versionIntroduced, "3.2")
    }

    func testOriginalProvidersHaveEarlyVersions() {
        XCTAssertEqual(SessionSource.codex.versionIntroduced, "1.0")
        XCTAssertEqual(SessionSource.claude.versionIntroduced, "1.0")
    }
}
