import XCTest
@testable import AgentSessions

final class OnboardingCoordinatorTests: XCTestCase {
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Version parsing (unchanged)

    func testMajorMinorParsing() {
        XCTAssertEqual(OnboardingContent.majorMinor(from: "2.9"), "2.9")
        XCTAssertEqual(OnboardingContent.majorMinor(from: "2.9.0"), "2.9")
        XCTAssertEqual(OnboardingContent.majorMinor(from: "v2.9.1"), "2.9")
        XCTAssertNil(OnboardingContent.majorMinor(from: "2"))
        XCTAssertNil(OnboardingContent.majorMinor(from: "invalid"))
    }

    // MARK: - Fresh install → first-run setup (once)

    func testFreshInstallPresentsFirstRunSetup() async {
        let defaults = makeDefaults("Onboarding.freshSetup")

        let presentation = await MainActor.run { () -> OnboardingPresentation? in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "4.3" },
                isFreshInstallProvider: { true }
            )
            coordinator.checkAndPresentIfNeeded()
            return coordinator.presentation
        }

        XCTAssertEqual(presentation, .firstRunSetup)
    }

    func testFirstRunSetupShownOnlyOnce() async {
        let defaults = makeDefaults("Onboarding.setupOnce")
        // Simulate a prior completed first run.
        defaults.onboardingFullTourCompleted = true

        let result = await MainActor.run { () -> (OnboardingPresentation?, String?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "4.3" },
                isFreshInstallProvider: { true },
                whatsNewAvailableProvider: { _ in false }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.presentation, coordinator.whatsNewMajorMinor)
        }

        // Already completed: no setup, and fresh-install path never flags What's New.
        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
    }

    // MARK: - Version bump → What's New flag (not a sheet)

    func testVersionBumpSetsWhatsNewFlagNotSheet() async {
        let defaults = makeDefaults("Onboarding.bumpFlag")

        let result = await MainActor.run { () -> (OnboardingPresentation?, String?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in true }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.presentation, coordinator.whatsNewMajorMinor)
        }

        XCTAssertNil(result.0, "Updates must never present a modal")
        XCTAssertEqual(result.1, "2.9")
    }

    func testWhatsNewNotFlaggedWhenCatalogEmpty() async {
        let defaults = makeDefaults("Onboarding.bumpEmpty")

        let flag = await MainActor.run { () -> String? in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in false }
            )
            coordinator.checkAndPresentIfNeeded()
            return coordinator.whatsNewMajorMinor
        }

        XCTAssertNil(flag)
    }

    func testDismissedVersionNeverReFlags() async {
        let defaults = makeDefaults("Onboarding.dismissed")
        defaults.onboardingWhatsNewDismissedMajorMinor = "2.9"

        let flag = await MainActor.run { () -> String? in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in true }
            )
            coordinator.checkAndPresentIfNeeded()
            return coordinator.whatsNewMajorMinor
        }

        XCTAssertNil(flag)
    }

    func testDismissWhatsNewCardRecordsVersion() async {
        let defaults = makeDefaults("Onboarding.dismissRecords")

        await MainActor.run {
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.9" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in true }
            )
            coordinator.checkAndPresentIfNeeded()
            XCTAssertEqual(coordinator.whatsNewMajorMinor, "2.9")
            coordinator.dismissWhatsNewCard()
            XCTAssertNil(coordinator.whatsNewMajorMinor)
        }

        XCTAssertEqual(defaults.onboardingWhatsNewDismissedMajorMinor, "2.9")
    }

    // MARK: - Suppression matrix (carried over)

    func testSuppressesWhatsNewWhenUpgradingFromTwoEleven() async {
        let defaults = makeDefaults("Onboarding.skip211")
        defaults.onboardingLastActionMajorMinor = "2.11"

        let result = await MainActor.run { () -> (String?, String?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.12" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in true }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.whatsNewMajorMinor, defaults.onboardingLastSeenAppMajorMinor)
        }

        XCTAssertNil(result.0)
        XCTAssertEqual(result.1, "2.12")
    }

    func testStillFlagsWhatsNewWhenUpgradingFromOlderVersions() async {
        let defaults = makeDefaults("Onboarding.oldUpgrade")
        defaults.onboardingLastActionMajorMinor = "2.10"
        defaults.onboardingLastSeenAppMajorMinor = "2.10"

        let result = await MainActor.run { () -> (String?, String?) in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "2.12" },
                isFreshInstallProvider: { false },
                whatsNewAvailableProvider: { _ in true }
            )
            coordinator.checkAndPresentIfNeeded()
            return (coordinator.whatsNewMajorMinor, defaults.onboardingLastSeenAppMajorMinor)
        }

        XCTAssertEqual(result.0, "2.12")
        XCTAssertEqual(result.1, "2.12")
    }

    // MARK: - Modal completion recording

    func testFirstRunSkipRecordsCompletion() async {
        let defaults = makeDefaults("Onboarding.skipRecords")

        let presentation = await MainActor.run { () -> OnboardingPresentation? in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "4.3" },
                isFreshInstallProvider: { true }
            )
            coordinator.presentManually()
            coordinator.skip()
            return coordinator.presentation
        }

        XCTAssertNil(presentation)
        XCTAssertTrue(defaults.onboardingFullTourCompleted)
        XCTAssertEqual(defaults.onboardingLastActionMajorMinor, "4.3")
    }

    func testPowerTipsDismissDoesNotRecordCompletion() async {
        let defaults = makeDefaults("Onboarding.powerTips")

        await MainActor.run {
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "4.3" },
                isFreshInstallProvider: { false }
            )
            coordinator.presentPowerTips()
            coordinator.complete()
        }

        XCTAssertNil(defaults.onboardingLastActionMajorMinor)
        XCTAssertFalse(defaults.onboardingFullTourCompleted)
    }

    // MARK: - OnboardingContent catalogs (Power Tips untouched)

    func testPowerTipsTourContainsAllTipSlides() {
        let tour = OnboardingContent.powerTipsTour(for: "4.3")
        XCTAssertEqual(tour.kind, .powerTips)
        XCTAssertEqual(tour.screens.count, 16)
        XCTAssertEqual(tour.screens.first?.title, "Power Tips")
        XCTAssertEqual(tour.screens.last?.title, "Quick Navigation")
        XCTAssertTrue(tour.screens.allSatisfy { $0.bullets.count == 2 })
    }
}
