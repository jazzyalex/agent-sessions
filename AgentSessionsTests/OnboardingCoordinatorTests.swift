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

    func testCheckAndPresentIfNeededPresentsFullTourOnFreshInstall() async {
        let suite = "OnboardingCoordinatorTests.present"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let result = await MainActor.run { () -> (isPresented: Bool, kind: OnboardingContent.Kind?, title: String?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { true }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.kind, coordinator.content?.screens.first?.title)
        }

        XCTAssertTrue(result.isPresented)
        XCTAssertEqual(result.kind, .fullTour)
        XCTAssertEqual(result.title, "Welcome to Agent Sessions")
    }

    func testCheckAndPresentIfNeededPresentsUpdateTourWhenNotFreshAndNotSeenForVersion() async {
        let suite = "OnboardingCoordinatorTests.seen"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let result = await MainActor.run { () -> (isPresented: Bool, kind: OnboardingContent.Kind?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { false }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.kind)
        }

        XCTAssertTrue(result.isPresented)
        XCTAssertEqual(result.kind, .updateTour)
    }

    func testSkipRecordsVersionAndDismisses() async {
        let suite = "OnboardingCoordinatorTests.skip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let result = await MainActor.run { () -> Bool in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { true }
            )
            coordinator.presentManually()
            coordinator.skip()
            return coordinator.isPresented
        }

        XCTAssertFalse(result)
        XCTAssertEqual(defaults.onboardingLastActionMajorMinor, "2.9")
        XCTAssertTrue(defaults.onboardingFullTourCompleted)
    }
}
