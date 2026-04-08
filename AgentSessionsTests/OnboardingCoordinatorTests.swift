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
        XCTAssertTrue(
            ["Welcome to Agent Sessions", "Sessions Found"].contains(result.title ?? ""),
            "Unexpected first screen title: \(result.title ?? "nil")"
        )
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

    func testCheckAndPresentIfNeededSkipsUpdateTourWhenUpgradingFromTwoEleven() async {
        let suite = "OnboardingCoordinatorTests.skip211"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.onboardingLastActionMajorMinor = "2.11"

        let result = await MainActor.run { () -> (isPresented: Bool, kind: OnboardingContent.Kind?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.12" },
                isFreshInstallProvider: { false }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.kind)
        }

        XCTAssertFalse(result.isPresented)
        XCTAssertNil(result.kind)
        XCTAssertEqual(defaults.onboardingLastSeenAppMajorMinor, "2.12")
    }

    func testCheckAndPresentIfNeededStillShowsUpdateTourWhenUpgradingFromOlderVersions() async {
        let suite = "OnboardingCoordinatorTests.oldUpgrade"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.onboardingLastActionMajorMinor = "2.10"
        defaults.onboardingLastSeenAppMajorMinor = "2.10"

        let result = await MainActor.run { () -> (isPresented: Bool, kind: OnboardingContent.Kind?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.12" },
                isFreshInstallProvider: { false }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.kind)
        }

        XCTAssertTrue(result.isPresented)
        XCTAssertEqual(result.kind, .updateTour)
        XCTAssertEqual(defaults.onboardingLastSeenAppMajorMinor, "2.12")
    }

    func testFullTourScreenSequence() {
        let fullTour = OnboardingContent.fullTour(for: "3.0")
        let titles = fullTour.screens.map(\.title)

        XCTAssertEqual(titles.count, 5)
        XCTAssertEqual(titles[0], "Sessions Found")
        XCTAssertEqual(titles[1], "Connect Your Agents")
        XCTAssertEqual(titles[2], "Agent Cockpit (Beta)")
        XCTAssertEqual(titles[3], "Analytics & Usage")
        XCTAssertEqual(titles[4], "Feedback & Community Support")
    }

    func testReleaseThreeUpdateCatalogHasThreeScreenTour() {
        let updateTour = OnboardingContent.updateTour(for: "3.0")

        XCTAssertEqual(updateTour?.kind, .updateTour)
        // Droid was introduced in 3.0, so newProviderScreens appends a "New Agent Support" slide.
        XCTAssertEqual(updateTour?.screens.count, 3)
        XCTAssertEqual(updateTour?.screens.first?.title, "Agent Cockpit (Beta)")
        XCTAssertEqual(updateTour?.screens[1].title, "Feedback & Community Support")
        XCTAssertEqual(updateTour?.screens.last?.title, "New Agent Support")
    }

    func testCheckAndPresentIfNeededForReleaseThreeShowsThreeScreenUpdateTour() async {
        let suite = "OnboardingCoordinatorTests.release3Update"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.onboardingLastActionMajorMinor = "2.12"
        defaults.onboardingLastSeenAppMajorMinor = "2.12"

        let result = await MainActor.run { () -> (isPresented: Bool, kind: OnboardingContent.Kind?, screens: Int) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "3.0" },
                isFreshInstallProvider: { false }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.isPresented, coordinator.content?.kind, coordinator.content?.screens.count ?? 0)
        }

        XCTAssertTrue(result.isPresented)
        XCTAssertEqual(result.kind, .updateTour)
        // Droid was introduced in 3.0, so newProviderScreens appends a "New Agent Support" slide.
        XCTAssertEqual(result.screens, 3)
    }

    func testFallbackUpdateTourLeadsWithCockpit() {
        let fallback = OnboardingContent.fallbackUpdateTour(for: "9.9")

        XCTAssertEqual(fallback.kind, .updateTour)
        XCTAssertEqual(fallback.screens.count, 2)
        XCTAssertEqual(fallback.screens.first?.title, "Agent Cockpit (Beta)")
        XCTAssertEqual(fallback.screens.last?.title, "Feedback & Community Support")
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
