import XCTest
@testable import AgentSessions

/// The GitHub star card's retention gate and ask lifecycle. This one asks a
/// favour of people who already stayed, so showing it to a newcomer — or a
/// second time after they said no — is the failure mode that matters.
final class OnboardingStarCardTests: XCTestCase {
    /// Frozen "now" for every coordinator below, so snooze arithmetic is exact.
    private static let referenceNow = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeCoordinator(
        defaults: UserDefaults,
        version: String = "4.6",
        now: Date = OnboardingStarCardTests.referenceNow
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            now: { now }
        )
    }

    /// A user who has opened enough sessions to be past the retention bar.
    private func markRetained(_ defaults: UserDefaults) {
        defaults.onboardingSessionsOpenedCount = OnboardingCoordinator.starAskSessionsThreshold
        defaults.onboardingFirstLaunchDate = OnboardingStarCardTests.referenceNow
    }

    // MARK: - Retention gate

    @MainActor
    func testShownOnceEnoughSessionsHaveBeenOpened() {
        let defaults = makeDefaults("Star.retained")
        markRetained(defaults)
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    /// The whole point of the bar: someone still evaluating the app is not the
    /// audience for a favour.
    @MainActor
    func testNotShownToANewUser() {
        let defaults = makeDefaults("Star.newUser")
        defaults.onboardingSessionsOpenedCount = 3
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    /// The feedback card's bar (10 sessions) must not be enough on its own —
    /// otherwise both asks land in the same week.
    @MainActor
    func testFeedbackBarAloneDoesNotTriggerTheStarAsk() {
        let defaults = makeDefaults("Star.feedbackBarOnly")
        defaults.onboardingSessionsOpenedCount = 10
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    /// Someone who keeps the app around without opening much still counts as
    /// retained, on time rather than volume.
    @MainActor
    func testLongTimeInstallQualifiesWithoutManySessions() {
        let defaults = makeDefaults("Star.oldInstall")
        defaults.onboardingSessionsOpenedCount = 1
        let installed = Self.referenceNow.addingTimeInterval(-31 * 86_400)
        defaults.onboardingFirstLaunchDate = installed
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    @MainActor
    func testRecentInstallWithFewSessionsIsNotDue() {
        let defaults = makeDefaults("Star.recentInstall")
        defaults.onboardingSessionsOpenedCount = 1
        defaults.onboardingFirstLaunchDate = Self.referenceNow.addingTimeInterval(-29 * 86_400)
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    // MARK: - Slot priority

    @MainActor
    func testWhatsNewWinsTheSlot() {
        let defaults = makeDefaults("Star.whatsNew")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.whatsNewMajorMinor = "4.6"
        XCTAssertFalse(coordinator.shouldShowStarCard())
    }

    @MainActor
    func testNeverShownDuringAFreshInstallLaunch() {
        let defaults = makeDefaults("Star.freshInstall")
        markRetained(defaults)
        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { "4.6" },
            isFreshInstallProvider: { true },
            whatsNewAvailableProvider: { _ in false },
            now: { Self.referenceNow }
        )
        coordinator.checkAndPresentIfNeeded()
        XCTAssertFalse(coordinator.shouldShowStarCard())
    }

    /// The star ask outranks feedback: its exits are all permanent, so it clears
    /// the slot for good, while a feedback ✕ returns every launch.
    @MainActor
    func testStarOutranksFeedbackButYieldsOnceResolved() {
        let defaults = makeDefaults("Star.beatsFeedback")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldShowStarCard())
        XCTAssertTrue(coordinator.shouldShowFeedbackCard(), "Feedback is also due and would take the slot.")

        coordinator.dismissStarAskForever()

        XCTAssertFalse(coordinator.shouldShowStarCard())
        // Next launch the slot is feedback's, uncontested.
        let nextLaunch = makeCoordinator(defaults: defaults)
        XCTAssertFalse(nextLaunch.shouldShowStarCard())
        XCTAssertTrue(nextLaunch.shouldShowFeedbackCard())
    }

    /// One ask per launch: resolving the star card must not hand the slot
    /// straight to the feedback card on the same render.
    @MainActor
    func testResolvingTheStarCardDoesNotExposeFeedbackSameLaunch() {
        let defaults = makeDefaults("Star.noStackedAsk")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldShowFeedbackCard())
        coordinator.snoozeStarAsk()
        XCTAssertFalse(coordinator.shouldShowFeedbackCard())
    }

    // MARK: - Lifecycle

    @MainActor
    func testStarringSilencesItForever() {
        let defaults = makeDefaults("Star.starred")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.recordStarOpened()

        XCTAssertEqual(defaults.onboardingStarAskState, .starred)
        XCTAssertFalse(coordinator.shouldShowStarCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, version: "9.0").shouldShowStarCard())
    }

    @MainActor
    func testMaybeLaterRecordsATwoWeekSnooze() {
        let defaults = makeDefaults("Star.snooze")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.snoozeStarAsk()

        XCTAssertEqual(defaults.onboardingStarAskState, .snoozed)
        XCTAssertEqual(
            defaults.onboardingStarAskSnoozedUntil,
            Self.referenceNow.addingTimeInterval(OnboardingCoordinator.starAskSnoozeInterval)
        )
        XCTAssertFalse(coordinator.shouldShowStarCard())
    }

    /// A snooze is a clock, not a launch counter — relaunching the next day must
    /// not resurrect it.
    @MainActor
    func testSnoozeSurvivesRelaunchUntilItExpires() {
        let defaults = makeDefaults("Star.snoozeHolds")
        markRetained(defaults)
        makeCoordinator(defaults: defaults).snoozeStarAsk()

        let nextDay = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(86_400))
        XCTAssertFalse(nextDay.shouldShowStarCard())

        let afterTwoWeeks = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(OnboardingCoordinator.starAskSnoozeInterval + 60)
        )
        XCTAssertTrue(afterTwoWeeks.shouldShowStarCard(), "The one promised retry is owed once the snooze elapses.")
    }

    /// Exactly one retry: a second "Maybe later" is a no.
    @MainActor
    func testSecondMaybeLaterSilencesItForever() {
        let defaults = makeDefaults("Star.secondSnooze")
        markRetained(defaults)
        makeCoordinator(defaults: defaults).snoozeStarAsk()

        let retry = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(OnboardingCoordinator.starAskSnoozeInterval + 60)
        )
        XCTAssertTrue(retry.shouldShowStarCard())
        retry.snoozeStarAsk()

        XCTAssertEqual(defaults.onboardingStarAskState, .dismissedForever)
        let muchLater = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(365 * 86_400)
        )
        XCTAssertFalse(muchLater.shouldShowStarCard())
    }

    /// The ✕ is an explicit no, not a snooze — "Maybe later" is right beside it
    /// for anyone who only wants it gone for now.
    @MainActor
    func testDismissIsPermanentOnTheFirstAsk() {
        let defaults = makeDefaults("Star.dismissForever")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.dismissStarAskForever()

        XCTAssertEqual(defaults.onboardingStarAskState, .dismissedForever)
        let muchLater = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(365 * 86_400)
        )
        XCTAssertFalse(muchLater.shouldShowStarCard())
    }

    /// Dismissing after starring must not downgrade the record — a user who
    /// already starred should stay `starred` whatever order the callbacks land in.
    @MainActor
    func testDismissDoesNotOverwriteAStar() {
        let defaults = makeDefaults("Star.dismissAfterStar")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.recordStarOpened()
        coordinator.dismissStarAskForever()

        XCTAssertEqual(defaults.onboardingStarAskState, .starred)
    }

    // MARK: - Persistence and destination

    @MainActor
    func testDefaultStateIsNotAsked() {
        let defaults = makeDefaults("Star.defaultState")
        XCTAssertEqual(defaults.onboardingStarAskState, .notAsked)
        XCTAssertNil(defaults.onboardingStarAskSnoozedUntil)
    }

    /// The launch-scoped suppression must not leak into UserDefaults, or a single
    /// launch's silence would become permanent.
    @MainActor
    func testLaunchSuppressionIsNotPersisted() {
        let defaults = makeDefaults("Star.launchGate")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.starCardSuppressedThisLaunch = true

        XCTAssertFalse(coordinator.shouldShowStarCard())
        XCTAssertEqual(defaults.onboardingStarAskState, .notAsked)
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    /// One click, one destination, and no query string that could carry anything
    /// about the user.
    func testStarDestinationIsThePublicRepository() {
        XCTAssertEqual(
            OnboardingCoordinator.githubRepositoryURL.absoluteString,
            "https://github.com/jazzyalex/agent-sessions"
        )
    }

    func testSnoozeIntervalIsTwoWeeks() {
        XCTAssertEqual(OnboardingCoordinator.starAskSnoozeInterval, 14 * 86_400)
    }
}
