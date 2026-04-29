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

        XCTAssertEqual(titles.count, 6)
        XCTAssertEqual(titles[0], "Sessions Found")
        XCTAssertEqual(titles[1], "Connect Your Agents")
        XCTAssertEqual(titles[2], "Agent Cockpit (Beta)")
        XCTAssertEqual(titles[3], "Power Tips")
        XCTAssertEqual(titles[4], "Analytics & Usage")
        XCTAssertEqual(titles[5], "Feedback & Community Support")
    }

    func testFullTourUsesPrimaryPowerTips() {
        let fullTour = OnboardingContent.fullTour(for: "3.0")
        let powerTips = fullTour.screens.first { $0.title == "Power Tips" }

        XCTAssertEqual(powerTips?.bullets.count, 2)
        XCTAssertTrue(powerTips?.bullets.first?.hasPrefix("Hide the Dock icon:") == true)
        XCTAssertTrue(powerTips?.bullets.last?.hasPrefix("Use Agent Cockpit:") == true)
    }

    func testReleaseThreeUpdateCatalogStartsWithPowerTips() {
        let updateTour = OnboardingContent.updateTour(for: "3.0")

        XCTAssertEqual(updateTour?.kind, .updateTour)
        // Droid was introduced in 3.0, so newProviderScreens appends a "New Agent Support" slide.
        XCTAssertEqual(updateTour?.screens.count, 4)
        XCTAssertEqual(updateTour?.screens.first?.title, "Power Tips")
        XCTAssertEqual(updateTour?.screens.first?.body, "Two quick tips from Agent Sessions.")
        XCTAssertEqual(updateTour?.screens.first?.bullets.count, 2)
        XCTAssertEqual(updateTour?.screens[1].title, "Agent Cockpit (Beta)")
        XCTAssertEqual(updateTour?.screens[2].title, "Feedback & Community Support")
        XCTAssertEqual(updateTour?.screens.last?.title, "New Agent Support")
    }

    func testCheckAndPresentIfNeededForReleaseThreeShowsFourScreenUpdateTour() async {
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
        XCTAssertEqual(result.screens, 4)
    }

    func testFallbackUpdateTourStartsWithPowerTips() {
        let fallback = OnboardingContent.fallbackUpdateTour(for: "9.9")

        XCTAssertEqual(fallback.kind, .updateTour)
        XCTAssertEqual(fallback.screens.count, 3)
        XCTAssertEqual(fallback.screens.first?.title, "Power Tips")
        XCTAssertEqual(fallback.screens.first?.body, "Two quick tips from Agent Sessions.")
        XCTAssertEqual(fallback.screens.first?.bullets.count, 2)
        XCTAssertEqual(fallback.screens[1].title, "Agent Cockpit (Beta)")
        XCTAssertEqual(fallback.screens.last?.title, "Feedback & Community Support")
    }

    func testPowerTipsTourContainsAllTipSlides() {
        let tour = OnboardingContent.powerTipsTour(for: "3.0")

        XCTAssertEqual(tour.kind, .powerTips)
        XCTAssertEqual(tour.screens.count, 13)
        XCTAssertEqual(tour.screens.first?.title, "Power Tips")
        XCTAssertEqual(tour.screens.last?.title, "Quick Navigation")
        XCTAssertTrue(tour.screens.allSatisfy { $0.bullets.count == 2 })
    }

    func testPowerTipsDismissDoesNotRecordOnboardingCompletion() async {
        let suite = "OnboardingCoordinatorTests.powerTips"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        await MainActor.run {
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "3.0" },
                isFreshInstallProvider: { false }
            )
            coordinator.presentPowerTips()
            coordinator.complete()
        }

        XCTAssertNil(defaults.onboardingLastActionMajorMinor)
        XCTAssertFalse(defaults.onboardingFullTourCompleted)
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
