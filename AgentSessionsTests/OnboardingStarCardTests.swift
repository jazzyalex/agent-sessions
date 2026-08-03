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

    // MARK: - Impressions (silence is an answer)

    /// `shouldShowStarCard()` is a pure render-time query, so nothing about being
    /// seen used to advance the state. A user who never touched the card got it
    /// on every eligible launch forever.
    @MainActor
    func testThreeIgnoredLaunchesEndTheRoundLikeMaybeLater() {
        let defaults = makeDefaults("Star.ignoredRound")
        markRetained(defaults)

        for launch in 1...OnboardingCoordinator.starAskMaxImpressionsPerRound {
            let coordinator = makeCoordinator(defaults: defaults)
            XCTAssertTrue(coordinator.shouldShowStarCard(), "launch \(launch) should still show it")
            coordinator.noteStarCardShown()
        }

        XCTAssertEqual(defaults.onboardingStarAskState, .snoozed)
        XCTAssertEqual(
            defaults.onboardingStarAskSnoozedUntil,
            Self.referenceNow.addingTimeInterval(OnboardingCoordinator.starAskSnoozeInterval)
        )
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStarCard())
    }

    /// The retry round is bounded too, so the whole ask terminates without the
    /// user ever answering it.
    @MainActor
    func testIgnoringTheRetryRoundSilencesItForever() {
        let defaults = makeDefaults("Star.ignoredTwice")
        markRetained(defaults)

        for _ in 1...OnboardingCoordinator.starAskMaxImpressionsPerRound {
            makeCoordinator(defaults: defaults).noteStarCardShown()
        }
        XCTAssertEqual(defaults.onboardingStarAskState, .snoozed)

        let afterSnooze = Self.referenceNow.addingTimeInterval(OnboardingCoordinator.starAskSnoozeInterval + 60)
        for _ in 1...OnboardingCoordinator.starAskMaxImpressionsPerRound {
            let coordinator = makeCoordinator(defaults: defaults, now: afterSnooze)
            XCTAssertTrue(coordinator.shouldShowStarCard())
            coordinator.noteStarCardShown()
        }

        XCTAssertEqual(defaults.onboardingStarAskState, .dismissedForever)
        let muchLater = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(365 * 86_400))
        XCTAssertFalse(muchLater.shouldShowStarCard())
    }

    /// The retry round gets its own budget rather than inheriting a spent one.
    @MainActor
    func testEndingTheFirstRoundResetsTheImpressionBudget() {
        let defaults = makeDefaults("Star.budgetReset")
        markRetained(defaults)
        for _ in 1...OnboardingCoordinator.starAskMaxImpressionsPerRound {
            makeCoordinator(defaults: defaults).noteStarCardShown()
        }
        XCTAssertEqual(defaults.onboardingStarAskImpressions, 0)
    }

    /// An impression is one launch that showed the card, not one render.
    /// `.onAppear` fires again every time the list rebuilds.
    @MainActor
    func testRepeatedRendersInOneLaunchCountOnce() {
        let defaults = makeDefaults("Star.oneImpressionPerLaunch")
        markRetained(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        for _ in 0..<10 { coordinator.noteStarCardShown() }

        XCTAssertEqual(defaults.onboardingStarAskImpressions, 1)
        XCTAssertEqual(defaults.onboardingStarAskState, .notAsked)
        XCTAssertTrue(coordinator.shouldShowStarCard(), "one launch's renders must not spend the round")
    }

    /// The point of bounding the round: the card below it eventually gets the slot.
    @MainActor
    func testFeedbackCardIsUnblockedOnceTheStarAskSpendsItself() {
        let defaults = makeDefaults("Star.unblocksFeedback")
        markRetained(defaults)

        for _ in 1...OnboardingCoordinator.starAskMaxImpressionsPerRound {
            let coordinator = makeCoordinator(defaults: defaults)
            XCTAssertTrue(coordinator.shouldShowStarCard())
            coordinator.noteStarCardShown()
        }

        let nextLaunch = makeCoordinator(defaults: defaults)
        XCTAssertFalse(nextLaunch.shouldShowStarCard())
        XCTAssertTrue(nextLaunch.shouldShowFeedbackCard(), "feedback must not be starved by an ignored star card")
    }

    // MARK: - Aging past the Quota Meter card

    @MainActor
    private func showsQuotaMeter(_ coordinator: OnboardingCoordinator) -> Bool {
        coordinator.shouldShowQuotaMeterCard(hasCodexOrClaudeSessions: true, isQuotaMeterActive: false)
    }

    /// Fresh, the Quota Meter card still wins: activation before extraction.
    @MainActor
    func testQuotaMeterKeepsPriorityBeforeTheStarAskAges() {
        let defaults = makeDefaults("Star.quotaFirst")
        markRetained(defaults)
        defaults.onboardingStarAskDueSince = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(showsQuotaMeter(coordinator))
        XCTAssertFalse(coordinator.starAskOutranksQuotaMeterCard())
    }

    /// The Quota Meter card only leaves the slot when the user acts on it, so a
    /// user who ignores it would otherwise hold the star ask off forever.
    @MainActor
    func testStarAskTakesTheSlotAfterWaitingTwoWeeks() {
        let defaults = makeDefaults("Star.agedPastQuota")
        markRetained(defaults)
        defaults.onboardingStarAskDueSince =
            Self.referenceNow.addingTimeInterval(-(OnboardingCoordinator.starAskPriorityAfterDays + 1) * 86_400)

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.starAskOutranksQuotaMeterCard())
        XCTAssertFalse(showsQuotaMeter(coordinator), "the aged star ask takes the slot")
        XCTAssertTrue(coordinator.shouldShowStarCard())
    }

    /// Aging must not hand the slot over when the star ask is not actually due —
    /// otherwise it would suppress the Quota Meter card for nothing.
    @MainActor
    func testAgingDoesNotSuppressQuotaMeterOnceTheStarAskIsResolved() {
        let defaults = makeDefaults("Star.agedButResolved")
        markRetained(defaults)
        defaults.onboardingStarAskDueSince =
            Self.referenceNow.addingTimeInterval(-365 * 86_400)
        defaults.onboardingStarAskState = .starred

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.starAskOutranksQuotaMeterCard())
        XCTAssertTrue(showsQuotaMeter(coordinator), "a spent star ask must give the slot back")
    }

    /// The stamp is written once, on the first launch the ask qualifies, because
    /// the card may never render while another card holds the slot.
    @MainActor
    func testDueSinceIsStampedOnceAtLaunchCheck() {
        let defaults = makeDefaults("Star.dueSinceStamp")
        markRetained(defaults)

        makeCoordinator(defaults: defaults).checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingStarAskDueSince, Self.referenceNow)

        let later = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(86_400))
        later.checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingStarAskDueSince, Self.referenceNow, "the stamp must not move")
    }

    @MainActor
    func testDueSinceIsNotStampedBeforeTheAskQualifies() {
        let defaults = makeDefaults("Star.dueSinceNotYet")
        defaults.onboardingSessionsOpenedCount = 2
        defaults.onboardingFirstLaunchDate = Self.referenceNow

        makeCoordinator(defaults: defaults).checkAndPresentIfNeeded()
        XCTAssertNil(defaults.onboardingStarAskDueSince)
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
