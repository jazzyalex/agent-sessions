import XCTest
@testable import AgentSessions

final class OnboardingCoordinatorTests: XCTestCase {
    func testMajorMinorParsing() {
        XCTAssertEqual(OnboardingContent.majorMinor(from: "2.9"), "2.9")
        XCTAssertEqual(OnboardingContent.majorMinor(from: "2.9.0"), "2.9")
        XCTAssertEqual(OnboardingContent.majorMinor(from: "v2.9.1"), "2.9")
        XCTAssertNil(OnboardingContent.majorMinor(from: "2"))
        XCTAssertNil(OnboardingContent.majorMinor(from: "invalid"))
    }

    func testCheckAndPresentIfNeededPresentsWhenNotSeen() async {
        let suite = "OnboardingCoordinatorTests.present"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let result = await MainActor.run { () -> (isPresented: Bool, majorMinor: String?) in
            let coordinator = OnboardingCoordinator(defaults: defaults, currentMajorMinorProvider: { "2.9" })
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.versionMajorMinor)
        }

        XCTAssertTrue(result.isPresented)
        XCTAssertEqual(result.majorMinor, "2.9")
    }

    func testCheckAndPresentIfNeededDoesNotPresentWhenAlreadySeen() async {
        let suite = "OnboardingCoordinatorTests.seen"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.onboardingLastActionMajorMinor = "2.9"

        let result = await MainActor.run { () -> (isPresented: Bool, hasContent: Bool) in
            let coordinator = OnboardingCoordinator(defaults: defaults, currentMajorMinorProvider: { "2.9" })
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content != nil)
        }

        XCTAssertFalse(result.isPresented)
        XCTAssertFalse(result.hasContent)
    }

    func testSkipRecordsVersionAndDismisses() async {
        let suite = "OnboardingCoordinatorTests.skip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let result = await MainActor.run { () -> Bool in
            let coordinator = OnboardingCoordinator(defaults: defaults, currentMajorMinorProvider: { "2.9" })
            coordinator.presentManually()
            coordinator.skip()
            return coordinator.isPresented
        }

        XCTAssertFalse(result)
        XCTAssertEqual(defaults.onboardingLastActionMajorMinor, "2.9")
    }
}
