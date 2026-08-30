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

    // MARK: - What's New terminates

    /// The card sits ahead of every other ask in the top slot, so each of its
    /// honest answers has to retire it. These cover the two that previously
    /// recorded nothing: reading the notes, and ignoring the card.

    @MainActor
    private func makeWhatsNewCoordinator(
        defaults: UserDefaults,
        version: String = "2.9"
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in true }
        )
    }

    /// Reading the release notes is as complete an answer as dismissing them.
    func testOpeningFromTheCardRetiresTheVersion() async {
        let defaults = makeDefaults("WhatsNew.openRetires")

        // The feedback ask must be genuinely due, or the suppression assertion
        // below passes because feedback was never eligible and proves nothing.
        defaults.onboardingSessionsOpenedCount = 10

        await MainActor.run {
            let coordinator = makeWhatsNewCoordinator(defaults: defaults)
            coordinator.checkAndPresentIfNeeded()
            XCTAssertEqual(coordinator.whatsNewMajorMinor, "2.9")
            XCTAssertTrue(coordinator.isFeedbackAskDue())

            coordinator.openWhatsNewFromCard(version: "2.9")
            XCTAssertNil(coordinator.whatsNewMajorMinor)
            XCTAssertTrue(coordinator.isWhatsNewPanelPresented)
            XCTAssertEqual(coordinator.whatsNewPanelVersion, "2.9")

            // Acting spends the launch's ask, so the next card does not swap in
            // behind the panel that just opened.
            XCTAssertFalse(coordinator.shouldShowFeedbackCard())

            // …but only for this launch. The card is retired; the queue behind
            // it is not.
            let relaunch = makeWhatsNewCoordinator(defaults: defaults)
            relaunch.checkAndPresentIfNeeded()
            XCTAssertNil(relaunch.whatsNewMajorMinor)
            XCTAssertTrue(relaunch.shouldShowFeedbackCard())
        }

        XCTAssertEqual(defaults.onboardingWhatsNewDismissedMajorMinor, "2.9")
    }

    /// Help → What's New must not retire a card that is currently on screen.
    func testHelpMenuDoesNotRetireTheCard() async {
        let defaults = makeDefaults("WhatsNew.helpDoesNotRetire")

        await MainActor.run {
            let coordinator = makeWhatsNewCoordinator(defaults: defaults)
            coordinator.checkAndPresentIfNeeded()
            XCTAssertEqual(coordinator.whatsNewMajorMinor, "2.9")

            coordinator.presentWhatsNewFromMenu()
            XCTAssertTrue(coordinator.isWhatsNewPanelPresented)
            // The live card survives the menu route untouched.
            XCTAssertEqual(coordinator.whatsNewMajorMinor, "2.9")

            let relaunch = makeWhatsNewCoordinator(defaults: defaults)
            relaunch.checkAndPresentIfNeeded()
            XCTAssertEqual(relaunch.whatsNewMajorMinor, "2.9")
        }

        XCTAssertNil(defaults.onboardingWhatsNewDismissedMajorMinor)
        XCTAssertEqual(defaults.onboardingWhatsNewImpressions, 0)
        XCTAssertNil(defaults.onboardingWhatsNewImpressionsVersion)
    }

    /// The armed-card guard: reaching the card's open path without the card on
    /// screen presents the panel and retires nothing.
    func testOpeningWithNoArmedCardRetiresNothing() async {
        let defaults = makeDefaults("WhatsNew.openWithoutCard")
        defaults.onboardingWhatsNewDismissedMajorMinor = "2.9"

        await MainActor.run {
            let coordinator = makeWhatsNewCoordinator(defaults: defaults)
            coordinator.checkAndPresentIfNeeded()
            XCTAssertNil(coordinator.whatsNewMajorMinor)

            coordinator.openWhatsNewFromCard(version: "3.0")
            XCTAssertTrue(coordinator.isWhatsNewPanelPresented)
        }

        // Unchanged: the passed version never became the handled one.
        XCTAssertEqual(defaults.onboardingWhatsNewDismissedMajorMinor, "2.9")
    }

    /// The escape hatch stays open after the card itself is gone.
    func testHelpMenuStillWorksOnceTheCardIsRetired() async {
        let defaults = makeDefaults("WhatsNew.helpAfterRetire")
        defaults.onboardingWhatsNewDismissedMajorMinor = "2.9"
        defaults.onboardingWhatsNewImpressionsVersion = "2.9"
        defaults.onboardingWhatsNewImpressions = OnboardingCoordinator.whatsNewMaxImpressionsPerVersion

        await MainActor.run {
            let coordinator = makeWhatsNewCoordinator(defaults: defaults)
            coordinator.checkAndPresentIfNeeded()
            XCTAssertNil(coordinator.whatsNewMajorMinor)

            coordinator.presentWhatsNewFromMenu()
            XCTAssertTrue(coordinator.isWhatsNewPanelPresented)
            XCTAssertEqual(coordinator.whatsNewPanelVersion, "2.9")
        }
    }

    /// Silence is an answer. Without this the card returned every launch until
    /// the next minor, blocking the entire queue behind it.
    func testThreeIgnoredLaunchesStandTheCardDown() async {
        let defaults = makeDefaults("WhatsNew.ignoredCap")

        await MainActor.run {
            for _ in 0..<OnboardingCoordinator.whatsNewMaxImpressionsPerVersion {
                let launch = makeWhatsNewCoordinator(defaults: defaults)
                launch.checkAndPresentIfNeeded()
                XCTAssertEqual(launch.whatsNewMajorMinor, "2.9")
                launch.noteWhatsNewCardShown()
            }

            let fourth = makeWhatsNewCoordinator(defaults: defaults)
            fourth.checkAndPresentIfNeeded()
            XCTAssertNil(fourth.whatsNewMajorMinor)
        }

        XCTAssertEqual(
            defaults.onboardingWhatsNewImpressions,
            OnboardingCoordinator.whatsNewMaxImpressionsPerVersion
        )
    }

    /// `.onAppear` fires again every time the list rebuilds the card, so the
    /// budget has to be spent by launches rather than by renders.
    func testRepeatedRendersInOneLaunchCountOnce() async {
        let defaults = makeDefaults("WhatsNew.rerender")

        await MainActor.run {
            let coordinator = makeWhatsNewCoordinator(defaults: defaults)
            coordinator.checkAndPresentIfNeeded()
            coordinator.noteWhatsNewCardShown()
            coordinator.noteWhatsNewCardShown()
            coordinator.noteWhatsNewCardShown()

            // Spending the budget must not yank a card the user may be reading.
            XCTAssertEqual(coordinator.whatsNewMajorMinor, "2.9")
        }

        XCTAssertEqual(defaults.onboardingWhatsNewImpressions, 1)
    }

    /// A new release earns a fresh three launches, including when the previous
    /// version's budget was fully spent.
    func testVersionBumpRestoresTheBudget() async {
        let defaults = makeDefaults("WhatsNew.versionReset")
        defaults.onboardingWhatsNewImpressionsVersion = "2.9"
        defaults.onboardingWhatsNewImpressions = OnboardingCoordinator.whatsNewMaxImpressionsPerVersion

        await MainActor.run {
            let bumped = makeWhatsNewCoordinator(defaults: defaults, version: "3.0")
            bumped.checkAndPresentIfNeeded()
            XCTAssertEqual(bumped.whatsNewMajorMinor, "3.0")
            bumped.noteWhatsNewCardShown()
        }

        XCTAssertEqual(defaults.onboardingWhatsNewImpressionsVersion, "3.0")
        XCTAssertEqual(defaults.onboardingWhatsNewImpressions, 1)
    }

    /// Opening ends the version outright — the counter stops mattering.
    func testOpeningBeatsTheImpressionCap() async {
        let defaults = makeDefaults("WhatsNew.openBeatsCap")

        await MainActor.run {
            let first = makeWhatsNewCoordinator(defaults: defaults)
            first.checkAndPresentIfNeeded()
            first.noteWhatsNewCardShown()

            let second = makeWhatsNewCoordinator(defaults: defaults)
            second.checkAndPresentIfNeeded()
            second.noteWhatsNewCardShown()
            second.openWhatsNewFromCard(version: "2.9")

            let third = makeWhatsNewCoordinator(defaults: defaults)
            third.checkAndPresentIfNeeded()
            XCTAssertNil(third.whatsNewMajorMinor)
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
