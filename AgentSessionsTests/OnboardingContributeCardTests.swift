import XCTest
@testable import AgentSessions

/// The one-time "contribute an agent source" invitation: its retention gate, its
/// place at the bottom of the top-slot chain, and the fact that every exit is
/// terminal within two rounds. This card asks for real work, so showing it to a
/// newcomer — or again after a no — is the failure mode that matters.
final class OnboardingContributeCardTests: XCTestCase {
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
        version: String = "5.0",
        now: Date = OnboardingContributeCardTests.referenceNow
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            now: { now }
        )
    }

    /// Past the retention bar on the sessions leg, and with the star ask already
    /// spent so it does not hold the slot.
    private func markEligible(_ defaults: UserDefaults) {
        defaults.onboardingSessionsOpenedCount = OnboardingCoordinator.contributeAskSessionsThreshold
        defaults.onboardingFirstLaunchDate = OnboardingContributeCardTests.referenceNow
        defaults.onboardingStarAskState = .starred
    }

    // MARK: - Retention gate

    /// The sessions leg: 60 opened sessions.
    @MainActor
    func testShownAtTheSessionsThreshold() {
        let defaults = makeDefaults("Contribute.sessions")
        defaults.onboardingSessionsOpenedCount = 60
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    /// The time leg: 45 days installed, however little was opened.
    @MainActor
    func testShownAtTheDaysThreshold() {
        let defaults = makeDefaults("Contribute.days")
        defaults.onboardingSessionsOpenedCount = 1
        defaults.onboardingFirstLaunchDate = Self.referenceNow.addingTimeInterval(-46 * 86_400)
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    @MainActor
    func testNotShownJustBelowEitherThreshold() {
        let defaults = makeDefaults("Contribute.belowBars")
        defaults.onboardingSessionsOpenedCount = 59
        defaults.onboardingFirstLaunchDate = Self.referenceNow.addingTimeInterval(-44 * 86_400)
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    @MainActor
    func testNotShownToANewUser() {
        let defaults = makeDefaults("Contribute.newUser")
        defaults.onboardingSessionsOpenedCount = 3
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    /// Pinned literally rather than read back off the coordinator.
    @MainActor
    func testThresholdsArePinned() {
        XCTAssertEqual(OnboardingCoordinator.contributeAskSessionsThreshold, 60)
        XCTAssertEqual(OnboardingCoordinator.contributeAskDaysThreshold, 45)
        XCTAssertEqual(OnboardingCoordinator.contributeAskMaxImpressionsPerRound, 3)
    }

    // MARK: - Slot priority

    @MainActor
    func testWhatsNewWinsTheSlot() {
        let defaults = makeDefaults("Contribute.whatsNew")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.whatsNewMajorMinor = "5.0"
        XCTAssertFalse(coordinator.shouldShowContributeCard())
    }

    @MainActor
    func testNeverShownDuringAFreshInstallLaunch() {
        let defaults = makeDefaults("Contribute.freshInstall")
        markEligible(defaults)
        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { "5.0" },
            isFreshInstallProvider: { true },
            whatsNewAvailableProvider: { _ in false },
            now: { Self.referenceNow }
        )
        coordinator.checkAndPresentIfNeeded()
        XCTAssertFalse(coordinator.shouldShowContributeCard())
    }

    /// One ask per launch: another card resolving must not hand this one the slot
    /// on the same render.
    @MainActor
    func testAnotherCardConsumingTheAskHidesIt() {
        let defaults = makeDefaults("Contribute.askConsumed")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldShowContributeCard())
        coordinator.suppressFeedbackCardThisLaunch()
        XCTAssertFalse(coordinator.shouldShowContributeCard())
    }

    /// The star ask outranks this unconditionally — no aging, no outranking the
    /// other way — because it always spends itself within two rounds.
    @MainActor
    func testStarCardStillOutranksTheContributeCard() {
        let defaults = makeDefaults("Contribute.starWins")
        defaults.onboardingSessionsOpenedCount = OnboardingCoordinator.contributeAskSessionsThreshold
        defaults.onboardingFirstLaunchDate = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.shouldShowStarCard(), "the star ask is due and renders first")

        // The chain renders the first true branch, so resolving the star card is
        // what eventually frees the slot — and it does so only on a later launch.
        coordinator.dismissStarAskForever()
        XCTAssertFalse(coordinator.shouldShowContributeCard(), "one ask per launch")
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    /// Both asks due on the same launch, before the contribute ask has aged:
    /// feedback is above contribute in the chain, so it takes the slot, and the
    /// contribute card must not also render. Once feedback is permanently
    /// deferred for the release, the slot falls through on the next launch.
    @MainActor
    func testFeedbackWinsTheSlotWhenBothAreDueBeforeAging() {
        let defaults = makeDefaults("Contribute.bothDue")
        markEligible(defaults)
        // Just became due — the aging rule must not have fired yet.
        defaults.onboardingContributeAskDueSince = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.shouldShowFeedbackCard(), "the feedback bar is long past")
        XCTAssertTrue(coordinator.shouldShowContributeCard(), "and so is this one")

        // The view renders the first true branch, and resolving it spends the
        // launch's single ask — so contribute cannot appear on this launch.
        coordinator.suppressFeedbackCardThisLaunch()
        XCTAssertFalse(coordinator.shouldShowContributeCard())

        // "Not now" spends feedback's release round, so the next launch advances.
        let nextLaunch = makeCoordinator(defaults: defaults)
        XCTAssertFalse(nextLaunch.shouldShowFeedbackCard())
        XCTAssertTrue(nextLaunch.shouldShowContributeCard())
    }

    /// Users who never become eligible must see exactly the behaviour they saw
    /// before this card existed.
    @MainActor
    func testFeedbackCardIsUnaffectedWhenContributeIsIneligible() {
        let defaults = makeDefaults("Contribute.feedbackUnchanged")
        defaults.onboardingSessionsOpenedCount = 10
        defaults.onboardingFirstLaunchDate = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.shouldShowFeedbackCard())
        XCTAssertFalse(coordinator.shouldShowContributeCard())
        XCTAssertFalse(coordinator.shouldShowStarCard())
    }

    // MARK: - Aging past the feedback card

    /// Aging remains a deterministic priority rule even though feedback silence
    /// is now capped independently.
    @MainActor
    func testContributeTakesTheSlotAfterWaitingTwoWeeks() {
        let defaults = makeDefaults("Contribute.agedPastFeedback")
        markEligible(defaults)
        defaults.onboardingContributeAskDueSince = Self.referenceNow.addingTimeInterval(-15 * 86_400)

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.contributeAskOutranksFeedbackCard())
        XCTAssertFalse(coordinator.shouldShowFeedbackCard(), "the aged contribute ask takes the slot")
        XCTAssertTrue(coordinator.shouldShowContributeCard())
    }

    @MainActor
    func testPriorityWaitIsTwoWeeks() {
        XCTAssertEqual(OnboardingCoordinator.contributeAskPriorityAfterDays, 14)
    }

    /// One day short of the wait, feedback still goes first.
    @MainActor
    func testFeedbackKeepsPriorityJustBeforeTheWaitElapses() {
        let defaults = makeDefaults("Contribute.notYetAged")
        markEligible(defaults)
        defaults.onboardingContributeAskDueSince = Self.referenceNow.addingTimeInterval(-13 * 86_400)

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.contributeAskOutranksFeedbackCard())
        XCTAssertTrue(coordinator.shouldShowFeedbackCard())
    }

    /// Aging must not suppress the feedback card for nothing: a contribute ask
    /// the user already answered gives the slot straight back.
    @MainActor
    func testAgingDoesNotSuppressFeedbackOnceContributeIsResolved() {
        let defaults = makeDefaults("Contribute.agedButResolved")
        markEligible(defaults)
        defaults.onboardingContributeAskDueSince = Self.referenceNow.addingTimeInterval(-365 * 86_400)
        defaults.onboardingContributeAskState = .dismissedForever

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.contributeAskOutranksFeedbackCard())
        XCTAssertTrue(coordinator.shouldShowFeedbackCard(), "a spent contribute ask must give the slot back")
    }

    /// Aging buys priority over feedback and nothing else: What's New, the Quota
    /// Meter card, and the star ask all still come first.
    @MainActor
    func testAgingNeverOutranksWhatsNewQuotaMeterOrStar() {
        let defaults = makeDefaults("Contribute.agedButOutranked")
        defaults.onboardingSessionsOpenedCount = 25
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        defaults.onboardingContributeAskDueSince = Self.referenceNow.addingTimeInterval(-365 * 86_400)

        // Star ask still open: it renders first, and the aged contribute card
        // cannot displace it.
        let withStar = makeCoordinator(defaults: defaults)
        XCTAssertTrue(withStar.shouldShowStarCard(), "the star ask still holds the slot above contribute")

        // Quota Meter card still open: it also renders first.
        XCTAssertTrue(
            withStar.shouldShowQuotaMeterCard(hasCodexOrClaudeSessions: true, isQuotaMeterActive: false),
            "the Quota Meter card is unaffected by contribute aging"
        )

        // What's New takes the slot from everything.
        let withWhatsNew = makeCoordinator(defaults: defaults)
        withWhatsNew.whatsNewMajorMinor = "5.0"
        XCTAssertFalse(withWhatsNew.shouldShowContributeCard())
        XCTAssertFalse(withWhatsNew.contributeAskOutranksFeedbackCard())
    }

    /// Stamped once, on the first launch the ask qualifies — the card may never
    /// render while another card holds the slot.
    @MainActor
    func testDueSinceIsStampedOnceAtLaunchCheck() {
        let defaults = makeDefaults("Contribute.dueSinceStamp")
        markEligible(defaults)

        makeCoordinator(defaults: defaults).checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingContributeAskDueSince, Self.referenceNow)

        let later = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(86_400))
        later.checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingContributeAskDueSince, Self.referenceNow, "the stamp must not move")
    }

    @MainActor
    func testDueSinceIsNotStampedBeforeTheAskQualifies() {
        let defaults = makeDefaults("Contribute.dueSinceNotYet")
        defaults.onboardingSessionsOpenedCount = 2
        defaults.onboardingFirstLaunchDate = Self.referenceNow

        makeCoordinator(defaults: defaults).checkAndPresentIfNeeded()
        XCTAssertNil(defaults.onboardingContributeAskDueSince)
    }

    // MARK: - Lifecycle

    @MainActor
    func testDefaultStateIsNotAsked() {
        let defaults = makeDefaults("Contribute.defaultState")
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)
        XCTAssertNil(defaults.onboardingContributeAskSnoozedUntil)
        XCTAssertEqual(defaults.onboardingContributeAskImpressions, 0)
    }

    /// Garbage in the store must not resurrect a dismissed ask or crash the read.
    @MainActor
    func testGarbageStateFallsBackToNotAsked() {
        let defaults = makeDefaults("Contribute.garbage")
        defaults.set("banana", forKey: "OnboardingContributeAskState")
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)
    }

    /// Opening a contribution page is terminal.
    @MainActor
    func testOpeningIsTerminal() {
        let defaults = makeDefaults("Contribute.opened")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.recordContributeOpened()

        XCTAssertEqual(defaults.onboardingContributeAskState, .opened)
        XCTAssertFalse(coordinator.shouldShowContributeCard())
        let muchLater = makeCoordinator(
            defaults: defaults,
            version: "9.0",
            now: Self.referenceNow.addingTimeInterval(365 * 86_400)
        )
        XCTAssertFalse(muchLater.shouldShowContributeCard())
    }

    @MainActor
    func testMaybeLaterRecordsAFourteenDaySnooze() {
        let defaults = makeDefaults("Contribute.snooze")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.snoozeContributeAsk()

        XCTAssertEqual(defaults.onboardingContributeAskState, .snoozed)
        XCTAssertEqual(
            defaults.onboardingContributeAskSnoozedUntil,
            Self.referenceNow.addingTimeInterval(14 * 86_400)
        )
        XCTAssertEqual(OnboardingCoordinator.contributeAskSnoozeInterval, 14 * 86_400)
    }

    @MainActor
    func testSnoozeSurvivesRelaunchUntilItExpires() {
        let defaults = makeDefaults("Contribute.snoozeHolds")
        markEligible(defaults)
        makeCoordinator(defaults: defaults).snoozeContributeAsk()

        let nextDay = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(86_400))
        XCTAssertFalse(nextDay.shouldShowContributeCard())

        let afterTwoWeeks = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(14 * 86_400 + 60)
        )
        XCTAssertTrue(afterTwoWeeks.shouldShowContributeCard(), "the one promised retry is owed")
    }

    /// The ✕ is an explicit no, and it persists across relaunch.
    @MainActor
    func testDismissIsPermanentAndSurvivesRelaunch() {
        let defaults = makeDefaults("Contribute.dismissForever")
        markEligible(defaults)
        makeCoordinator(defaults: defaults).dismissContributeAskForever()

        XCTAssertEqual(defaults.onboardingContributeAskState, .dismissedForever)
        let muchLater = makeCoordinator(
            defaults: defaults,
            now: Self.referenceNow.addingTimeInterval(365 * 86_400)
        )
        XCTAssertFalse(muchLater.shouldShowContributeCard())
    }

    @MainActor
    func testDismissDoesNotOverwriteAnOpen() {
        let defaults = makeDefaults("Contribute.dismissAfterOpen")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.recordContributeOpened()
        coordinator.dismissContributeAskForever()

        XCTAssertEqual(defaults.onboardingContributeAskState, .opened)
    }

    /// The launch-scoped suppression must not leak into UserDefaults.
    @MainActor
    func testLaunchSuppressionIsNotPersisted() {
        let defaults = makeDefaults("Contribute.launchGate")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.contributeCardSuppressedThisLaunch = true

        XCTAssertFalse(coordinator.shouldShowContributeCard())
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    // MARK: - Impressions (silence is an answer)

    @MainActor
    func testThreeIgnoredLaunchesEndTheRoundLikeMaybeLater() {
        let defaults = makeDefaults("Contribute.ignoredRound")
        markEligible(defaults)

        for launch in 1...3 {
            let coordinator = makeCoordinator(defaults: defaults)
            XCTAssertTrue(coordinator.shouldShowContributeCard(), "launch \(launch) should still show it")
            coordinator.noteContributeCardShown()
        }

        XCTAssertEqual(defaults.onboardingContributeAskState, .snoozed)
        XCTAssertEqual(
            defaults.onboardingContributeAskSnoozedUntil,
            Self.referenceNow.addingTimeInterval(14 * 86_400)
        )
        XCTAssertEqual(defaults.onboardingContributeAskImpressions, 0, "the retry gets its own budget")
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowContributeCard())
    }

    @MainActor
    func testThirdImpressionThenMaybeLaterDoesNotSpendTheRetryRound() {
        let defaults = makeDefaults("Contribute.thirdImpressionThenSnooze")
        markEligible(defaults)
        defaults.onboardingContributeAskImpressions =
            OnboardingCoordinator.contributeAskMaxImpressionsPerRound - 1
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.noteContributeCardShown()
        let snoozedUntil = defaults.onboardingContributeAskSnoozedUntil
        coordinator.snoozeContributeAsk()

        XCTAssertEqual(defaults.onboardingContributeAskState, .snoozed)
        XCTAssertEqual(defaults.onboardingContributeAskSnoozedUntil, snoozedUntil)
    }

    /// One invitation, not a campaign: the second round-out is permanent.
    @MainActor
    func testIgnoringTheRetryRoundSilencesItForever() {
        let defaults = makeDefaults("Contribute.ignoredTwice")
        markEligible(defaults)

        for _ in 1...3 {
            makeCoordinator(defaults: defaults).noteContributeCardShown()
        }
        XCTAssertEqual(defaults.onboardingContributeAskState, .snoozed)

        let afterSnooze = Self.referenceNow.addingTimeInterval(14 * 86_400 + 60)
        for _ in 1...3 {
            let coordinator = makeCoordinator(defaults: defaults, now: afterSnooze)
            XCTAssertTrue(coordinator.shouldShowContributeCard())
            coordinator.noteContributeCardShown()
        }

        XCTAssertEqual(defaults.onboardingContributeAskState, .dismissedForever)
        let muchLater = makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(365 * 86_400))
        XCTAssertFalse(muchLater.shouldShowContributeCard())
    }

    /// An impression is one launch that showed the card, not one render.
    @MainActor
    func testRepeatedRendersInOneLaunchCountOnce() {
        let defaults = makeDefaults("Contribute.oneImpressionPerLaunch")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        for _ in 0..<10 { coordinator.noteContributeCardShown() }

        XCTAssertEqual(defaults.onboardingContributeAskImpressions, 1)
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)
        XCTAssertTrue(coordinator.shouldShowContributeCard())
    }

    // MARK: - Destinations and copy

    /// The primary CTA lands on the repository's structured proposal form.
    func testPrimaryDestinationIsTheIssueTemplate() {
        XCTAssertEqual(
            OnboardingCoordinator.contributeAgentSourceURL.absoluteString,
            "https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml"
        )
    }

    func testSecondaryDestinationIsTheContributingGuide() {
        XCTAssertEqual(
            OnboardingCoordinator.contributeGuideURL.absoluteString,
            "https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md"
        )
    }

    /// Both destinations must stay on the canonical public repository — nothing
    /// in either URL may carry anything about the user.
    func testDestinationsStayOnThePublicRepository() {
        for url in [OnboardingCoordinator.contributeAgentSourceURL, OnboardingCoordinator.contributeGuideURL] {
            XCTAssertEqual(url.host, "github.com")
            XCTAssertTrue(url.path.hasPrefix("/jazzyalex/agent-sessions"), "unexpected path: \(url.path)")
        }
    }

    /// The privacy line is frozen: this card is the only place the app invites a
    /// user to hand session material to a public issue tracker, and the warning
    /// travels with the invitation or not at all.
    func testFrozenPrivacySentenceIsPresentInTheCardBody() {
        XCTAssertTrue(
            String(localized: ContributeCard.bodyText).hasSuffix("Never share real transcripts, keys, or private paths."),
            "the privacy warning must remain the last thing the card says"
        )
    }

    /// The whole copy, pinned literally.
    @MainActor
    func testCardCopyIsFrozen() {
        XCTAssertEqual(String(localized: ContributeCard.titleText), "Help add another agent")
        XCTAssertEqual(
            String(localized: ContributeCard.bodyText),
            "Agent Sessions adds new agents from user contributions — a pull request, your coding agent "
                + "working from our brief, or a sanitized sample. Never share real transcripts, keys, or "
                + "private paths."
        )
    }

    /// A hard-coded source count would go stale every release, so the copy must
    /// carry no count at all — neither a numeral nor a spelled-out one. Written
    /// as a blanket ban rather than a list of today's likely numbers, so "a dozen
    /// agents" fails too.
    @MainActor
    func testCopyStatesNoSourceCount() {
        let copy = String(localized: ContributeCard.titleText) + " " + String(localized: ContributeCard.bodyText)

        XCTAssertNil(
            copy.rangeOfCharacter(from: .decimalDigits),
            "copy must contain no digits: \(copy)"
        )

        let countWords = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
            "eighteen", "nineteen", "twenty", "dozen", "handful", "several", "dozens"
        ]
        // Word-boundary matching, so "one" does not fire on "someone".
        let words = copy.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for word in countWords {
            XCTAssertFalse(words.contains(word), "copy must not pin a source count, found \"\(word)\"")
        }
    }
}

/// The translation invitation is shown only to established users whose first
/// preferred macOS language is not covered by the shipped catalogs.
final class OnboardingLanguageCardTests: XCTestCase {
    private static let referenceNow = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeCoordinator(
        defaults: UserDefaults,
        language: String = "fr-FR",
        now: Date = OnboardingLanguageCardTests.referenceNow
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { "5.2" },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            preferredLanguagesProvider: { [language] },
            shippedLocalizationsProvider: { ["en", "zh-Hans"] },
            now: { now }
        )
    }

    private func markEligible(_ defaults: UserDefaults) {
        defaults.onboardingSessionsOpenedCount = OnboardingCoordinator.languageAskSessionsThreshold
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        defaults.onboardingStarAskState = .starred
    }

    @MainActor
    func testTargetsOnlyUnsupportedPreferredLanguages() {
        let defaults = makeDefaults("Language.targeting")
        markEligible(defaults)

        XCTAssertTrue(makeCoordinator(defaults: defaults, language: "fr-FR").shouldShowLanguageCard())
        XCTAssertTrue(makeCoordinator(defaults: defaults, language: "zh-Hant").shouldShowLanguageCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, language: "en-GB").shouldShowLanguageCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, language: "zh-Hans").shouldShowLanguageCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, language: "zh_CN").shouldShowLanguageCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, language: "zh-Hans-TW").shouldShowLanguageCard())
        XCTAssertTrue(makeCoordinator(defaults: defaults, language: "zh-Hant-CN").shouldShowLanguageCard())
    }

    @MainActor
    func testNewlyShippedLocaleAutomaticallyRetiresItsAsk() {
        let defaults = makeDefaults("Language.bundleDriven")
        markEligible(defaults)
        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { "5.2" },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            preferredLanguagesProvider: { ["fr-CA"] },
            shippedLocalizationsProvider: { ["Base", "en", "fr"] },
            now: { Self.referenceNow }
        )
        XCTAssertFalse(coordinator.shouldShowLanguageCard())
    }

    @MainActor
    func testRequiresEstablishedUse() {
        let defaults = makeDefaults("Language.retention")
        defaults.onboardingSessionsOpenedCount = 39
        defaults.onboardingFirstLaunchDate = Self.referenceNow.addingTimeInterval(-44 * 86_400)
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowLanguageCard())

        defaults.onboardingSessionsOpenedCount = 40
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowLanguageCard())
        XCTAssertEqual(OnboardingCoordinator.languageAskSessionsThreshold, 40)
        XCTAssertEqual(OnboardingCoordinator.languageAskDaysThreshold, 45)
    }

    @MainActor
    func testFeedbackWinsUntilLanguageAskHasWaitedTwoWeeks() {
        let defaults = makeDefaults("Language.priority")
        markEligible(defaults)
        defaults.onboardingLanguageAskDueSince = Self.referenceNow

        let fresh = makeCoordinator(defaults: defaults)
        XCTAssertTrue(fresh.shouldShowFeedbackCard())
        XCTAssertTrue(fresh.shouldShowLanguageCard())

        defaults.onboardingLanguageAskDueSince = Self.referenceNow.addingTimeInterval(-15 * 86_400)
        let aged = makeCoordinator(defaults: defaults)
        XCTAssertTrue(aged.languageAskOutranksFeedbackCard())
        XCTAssertFalse(aged.shouldShowFeedbackCard())
        XCTAssertTrue(aged.shouldShowLanguageCard())
        XCTAssertEqual(OnboardingCoordinator.languageAskPriorityAfterDays, 14)
    }

    @MainActor
    func testLaunchCheckStampsDueDateOnlyForAnUnsupportedLanguage() {
        let defaults = makeDefaults("Language.dueStamp")
        markEligible(defaults)
        makeCoordinator(defaults: defaults).checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingLanguageAskDueSince, Self.referenceNow)

        let supported = makeDefaults("Language.noDueStamp")
        markEligible(supported)
        makeCoordinator(defaults: supported, language: "en-US").checkAndPresentIfNeeded()
        XCTAssertNil(supported.onboardingLanguageAskDueSince)
    }

    @MainActor
    func testChangingTargetLanguageStartsAFreshPriorityClock() {
        let defaults = makeDefaults("Language.targetClock")
        markEligible(defaults)
        makeCoordinator(defaults: defaults, language: "fr-FR").checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingLanguageAskTargetIdentifier, "fr-fr")

        let later = Self.referenceNow.addingTimeInterval(20 * 86_400)
        makeCoordinator(defaults: defaults, language: "de-DE", now: later).checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingLanguageAskTargetIdentifier, "de-de")
        XCTAssertEqual(defaults.onboardingLanguageAskDueSince, later)
    }

    @MainActor
    func testOpeningAndDismissalAreTerminal() {
        let opened = makeDefaults("Language.opened")
        markEligible(opened)
        makeCoordinator(defaults: opened).recordLanguageContributionOpened()
        XCTAssertEqual(opened.onboardingLanguageAskState, .opened)
        XCTAssertFalse(makeCoordinator(defaults: opened).shouldShowLanguageCard())

        let dismissed = makeDefaults("Language.dismissed")
        markEligible(dismissed)
        makeCoordinator(defaults: dismissed).dismissLanguageAskForever()
        XCTAssertEqual(dismissed.onboardingLanguageAskState, .dismissedForever)
        XCTAssertFalse(makeCoordinator(defaults: dismissed).shouldShowLanguageCard())
    }

    @MainActor
    func testMaybeLaterAllowsOneDelayedRetry() {
        let defaults = makeDefaults("Language.snooze")
        markEligible(defaults)
        makeCoordinator(defaults: defaults).snoozeLanguageAsk()

        XCTAssertEqual(defaults.onboardingLanguageAskState, .snoozed)
        XCTAssertEqual(
            defaults.onboardingLanguageAskSnoozedUntil,
            Self.referenceNow.addingTimeInterval(14 * 86_400)
        )
        XCTAssertFalse(
            makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(86_400))
                .shouldShowLanguageCard()
        )
        XCTAssertTrue(
            makeCoordinator(defaults: defaults, now: Self.referenceNow.addingTimeInterval(15 * 86_400))
                .shouldShowLanguageCard()
        )
    }

    @MainActor
    func testThreeIgnoredLaunchesSpendEachRound() {
        let defaults = makeDefaults("Language.impressions")
        markEligible(defaults)

        for _ in 0..<3 { makeCoordinator(defaults: defaults).noteLanguageCardShown() }
        XCTAssertEqual(defaults.onboardingLanguageAskState, .snoozed)
        XCTAssertEqual(defaults.onboardingLanguageAskImpressions, 0)

        let afterSnooze = Self.referenceNow.addingTimeInterval(15 * 86_400)
        for _ in 0..<3 { makeCoordinator(defaults: defaults, now: afterSnooze).noteLanguageCardShown() }
        XCTAssertEqual(defaults.onboardingLanguageAskState, .dismissedForever)
    }

    @MainActor
    func testLanguageThirdImpressionThenMaybeLaterDoesNotSpendTheRetryRound() {
        let defaults = makeDefaults("Language.thirdImpressionThenSnooze")
        markEligible(defaults)
        defaults.onboardingLanguageAskImpressions =
            OnboardingCoordinator.languageAskMaxImpressionsPerRound - 1
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.noteLanguageCardShown()
        let snoozedUntil = defaults.onboardingLanguageAskSnoozedUntil
        coordinator.snoozeLanguageAsk()

        XCTAssertEqual(defaults.onboardingLanguageAskState, .snoozed)
        XCTAssertEqual(defaults.onboardingLanguageAskSnoozedUntil, snoozedUntil)
    }

    func testDestinationsStayInsideThePublicRepository() {
        XCTAssertEqual(
            OnboardingCoordinator.languageContributionURL.absoluteString,
            "https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md#translate-agent-sessions"
        )
        XCTAssertEqual(
            OnboardingCoordinator.localizationGuideURL.absoluteString,
            "https://github.com/jazzyalex/agent-sessions/blob/main/docs/localization.md"
        )
    }

    @MainActor
    func testCardCopyIsFrozen() {
        XCTAssertEqual(String(localized: LanguageContributeCard.titleText), "Speak another language?")
        XCTAssertEqual(
            String(localized: LanguageContributeCard.bodyText),
            "Agent Sessions is now available in English and Simplified Chinese. Help bring it to your "
                + "language—no Swift required."
        )
    }
}
