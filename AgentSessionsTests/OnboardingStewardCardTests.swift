import XCTest
@testable import AgentSessions

/// The invitation to steward one already-supported agent: its retention gate, its
/// place between the feedback and contribute cards, and the fact that it goes
/// quiet after one round per release and stops entirely after three.
///
/// This card asks a stranger for recurring work, so the failure modes that matter
/// are asking someone who does not run the agent, asking twice in one release,
/// and asking forever.
final class OnboardingStewardCardTests: XCTestCase {
    /// Frozen "now" for every coordinator below, so the aging arithmetic is exact.
    private static let referenceNow = Date(timeIntervalSince1970: 2_000_000_000)

    private static let qwen = StewardAgent(source: .qwen, stewardName: "Qwen Code")
    private static let grok = StewardAgent(source: .grok, stewardName: "Grok CLI")

    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeCoordinator(
        defaults: UserDefaults,
        version: String = "5.0",
        now: Date = OnboardingStewardCardTests.referenceNow,
        target: StewardAgent? = OnboardingStewardCardTests.qwen
    ) -> OnboardingCoordinator {
        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            now: { now }
        )
        coordinator.stewardAskTarget = target
        return coordinator
    }

    /// Past the retention bar, with the star ask already spent so it does not
    /// hold the slot.
    private func markEligible(_ defaults: UserDefaults) {
        defaults.onboardingSessionsOpenedCount = 25
        defaults.onboardingFirstLaunchDate = OnboardingStewardCardTests.referenceNow
        defaults.onboardingStarAskState = .starred
    }

    // MARK: - Needing a target

    /// The whole premise of this card is naming an agent the user runs. Without
    /// one there is nothing honest to say, however eligible they otherwise are.
    @MainActor
    func testNotShownWithoutATargetAgent() {
        let defaults = makeDefaults("Steward.noTarget")
        markEligible(defaults)
        XCTAssertFalse(makeCoordinator(defaults: defaults, target: nil).shouldShowStewardCard())
    }

    /// The index loads after launch, so the target starts nil and arrives later.
    /// The card must appear then rather than having missed its chance.
    @MainActor
    func testAppearsOnceTheIndexSuppliesATarget() {
        let defaults = makeDefaults("Steward.targetArrives")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults, target: nil)

        XCTAssertFalse(coordinator.shouldShowStewardCard())
        coordinator.stewardAskTarget = Self.qwen
        XCTAssertTrue(coordinator.shouldShowStewardCard())
    }

    // MARK: - Retention gate

    @MainActor
    func testShownAtTheSessionsThreshold() {
        let defaults = makeDefaults("Steward.sessions")
        defaults.onboardingSessionsOpenedCount = 25
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStewardCard())
    }

    @MainActor
    func testShownAtTheDaysThreshold() {
        let defaults = makeDefaults("Steward.days")
        defaults.onboardingSessionsOpenedCount = 1
        defaults.onboardingFirstLaunchDate = Self.referenceNow.addingTimeInterval(-46 * 86_400)
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStewardCard())
    }

    /// Running Qwen on day one does not make someone a candidate steward.
    @MainActor
    func testNotShownToANewUser() {
        let defaults = makeDefaults("Steward.newUser")
        defaults.onboardingSessionsOpenedCount = 3
        defaults.onboardingFirstLaunchDate = Self.referenceNow
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStewardCard())
    }

    @MainActor
    func testNeverShownDuringAFreshInstallLaunch() {
        let defaults = makeDefaults("Steward.freshInstall")
        markEligible(defaults)
        let coordinator = OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { "5.0" },
            isFreshInstallProvider: { true },
            whatsNewAvailableProvider: { _ in false },
            now: { Self.referenceNow }
        )
        coordinator.stewardAskTarget = Self.qwen
        coordinator.checkAndPresentIfNeeded()
        XCTAssertFalse(coordinator.shouldShowStewardCard())
    }

    @MainActor
    func testThresholdsArePinned() {
        XCTAssertEqual(OnboardingCoordinator.stewardAskSessionsThreshold, 25)
        XCTAssertEqual(OnboardingCoordinator.stewardAskDaysThreshold, 45)
        XCTAssertEqual(OnboardingCoordinator.stewardAskMaxImpressionsPerRound, 3)
        XCTAssertEqual(OnboardingCoordinator.stewardAskMaxRounds, 3)
        XCTAssertEqual(OnboardingCoordinator.stewardAskPriorityAfterDays, 14)
    }

    // MARK: - Slot priority

    @MainActor
    func testWhatsNewWinsTheSlot() {
        let defaults = makeDefaults("Steward.whatsNew")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.whatsNewMajorMinor = "5.0"
        XCTAssertFalse(coordinator.shouldShowStewardCard())
    }

    @MainActor
    func testAnotherCardConsumingTheAskHidesIt() {
        let defaults = makeDefaults("Steward.askConsumed")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldShowStewardCard())
        coordinator.suppressFeedbackCardThisLaunch()
        XCTAssertFalse(coordinator.shouldShowStewardCard())
    }

    /// The targeted ask beats the generic one whenever it has a target: same
    /// invitation, aimed at someone we can see already has the sessions.
    @MainActor
    func testStewardCardOutranksTheContributeCard() {
        let defaults = makeDefaults("Steward.beatsContribute")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldShowStewardCard())
        XCTAssertFalse(coordinator.shouldShowContributeCard())
    }

    /// ...but it is a separate ask, not a replacement. Spending the steward ask
    /// leaves the contribute ask untouched for a later launch.
    @MainActor
    func testSpendingTheStewardAskLeavesTheContributeAskIntact() {
        let defaults = makeDefaults("Steward.contributeSurvives")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.dismissStewardAskForever()
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)

        // Not on this launch — one ask per launch — but on the next one.
        XCTAssertFalse(coordinator.shouldShowContributeCard())
        let nextLaunch = makeCoordinator(defaults: defaults)
        XCTAssertTrue(nextLaunch.shouldShowContributeCard())
    }

    /// A user with no stewardless agent must see exactly what they saw before
    /// this card existed.
    @MainActor
    func testOtherCardsAreUnaffectedWithoutATarget() {
        let defaults = makeDefaults("Steward.noRegression")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults, target: nil)

        XCTAssertFalse(coordinator.shouldShowStewardCard())
        XCTAssertTrue(coordinator.shouldShowFeedbackCard())
        coordinator.suppressFeedbackCardThisLaunch()

        let nextLaunch = makeCoordinator(defaults: defaults, target: nil)
        defaults.onboardingFeedbackAskState = .completed
        XCTAssertTrue(nextLaunch.shouldShowContributeCard())
    }

    @MainActor
    func testStarCardStillOutranksTheStewardCard() {
        let defaults = makeDefaults("Steward.starWins")
        defaults.onboardingSessionsOpenedCount = 25
        defaults.onboardingFirstLaunchDate = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.shouldShowStarCard(), "the star ask is due and renders first")

        coordinator.dismissStarAskForever()
        XCTAssertFalse(coordinator.shouldShowStewardCard(), "one ask per launch")
        XCTAssertTrue(makeCoordinator(defaults: defaults).shouldShowStewardCard())
    }

    /// Feedback is above this in the chain until the aging rule fires.
    @MainActor
    func testFeedbackWinsTheSlotBeforeAging() {
        let defaults = makeDefaults("Steward.bothDue")
        markEligible(defaults)
        defaults.onboardingStewardAskDueSince = Self.referenceNow

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.stewardAskOutranksFeedbackCard())
        XCTAssertTrue(coordinator.shouldShowFeedbackCard())
    }

    /// The feedback card's ✕ is soft and returns every launch, so without aging a
    /// user who never answers it would hold this off forever.
    @MainActor
    func testStewardTakesTheSlotAfterWaitingTwoWeeks() {
        let defaults = makeDefaults("Steward.aged")
        markEligible(defaults)
        defaults.onboardingStewardAskDueSince = Self.referenceNow.addingTimeInterval(-15 * 86_400)

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.stewardAskOutranksFeedbackCard())
        XCTAssertFalse(coordinator.shouldShowFeedbackCard(), "the aged steward ask takes the slot")
        XCTAssertTrue(coordinator.shouldShowStewardCard())
    }

    /// Both bottom asks aged past feedback at once: the targeted one goes first
    /// and the generic one waits, rather than both claiming to outrank feedback
    /// and the chain rendering the wrong card.
    @MainActor
    func testStewardGoesFirstWhenBothAgedAsksAreDue() {
        let defaults = makeDefaults("Steward.bothAged")
        markEligible(defaults)
        let aged = Self.referenceNow.addingTimeInterval(-15 * 86_400)
        defaults.onboardingStewardAskDueSince = aged
        defaults.onboardingContributeAskDueSince = aged

        let coordinator = makeCoordinator(defaults: defaults)
        XCTAssertFalse(coordinator.shouldShowFeedbackCard())
        XCTAssertTrue(coordinator.shouldShowStewardCard())
        XCTAssertFalse(coordinator.shouldShowContributeCard())
        XCTAssertFalse(coordinator.contributeAskOutranksFeedbackCard(), "the steward ask holds the slot")
    }

    /// The due-since stamp is what the aging rule measures, and it is taken on
    /// retention alone — the target is not known this early in launch.
    @MainActor
    func testDueSinceIsStampedOnLaunchWithoutATarget() {
        let defaults = makeDefaults("Steward.dueSince")
        markEligible(defaults)
        let coordinator = makeCoordinator(defaults: defaults, target: nil)

        coordinator.checkAndPresentIfNeeded()
        XCTAssertEqual(defaults.onboardingStewardAskDueSince, Self.referenceNow)
    }

    // MARK: - Exits

    @MainActor
    func testOpeningTheSignupFormIsTerminal() {
        let defaults = makeDefaults("Steward.signedUp")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.recordStewardSignupOpened()
        XCTAssertEqual(defaults.onboardingStewardAskState, .signedUp)

        // Not this launch, not the next, and not after a release bump.
        XCTAssertFalse(coordinator.shouldShowStewardCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStewardCard())
        XCTAssertFalse(makeCoordinator(defaults: defaults, version: "5.1").shouldShowStewardCard())
    }

    @MainActor
    func testDismissIsTerminalAcrossReleases() {
        let defaults = makeDefaults("Steward.dismissed")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.dismissStewardAskForever()
        XCTAssertEqual(defaults.onboardingStewardAskState, .dismissedForever)
        XCTAssertFalse(makeCoordinator(defaults: defaults, version: "9.9").shouldShowStewardCard())
    }

    /// A ✕ after a signup must not downgrade the terminal state — a signed-up
    /// steward tidying the card away is still a steward.
    @MainActor
    func testDismissAfterSignupKeepsTheSignedUpState() {
        let defaults = makeDefaults("Steward.dismissAfterSignup")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.recordStewardSignupOpened()
        coordinator.dismissStewardAskForever()
        XCTAssertEqual(defaults.onboardingStewardAskState, .signedUp)
    }

    /// "What's involved" is interest, not a yes: it ends the release's round and
    /// leaves the ask alive for the next one.
    @MainActor
    func testReadingTheGuideEndsTheRoundButNotTheAsk() {
        let defaults = makeDefaults("Steward.guide")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.recordStewardGuideOpened()
        XCTAssertEqual(defaults.onboardingStewardAskState, .askedThisRelease)
        XCTAssertEqual(defaults.onboardingStewardAskAskedAtMajorMinor, "5.0")

        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStewardCard(), "same release")
        XCTAssertTrue(makeCoordinator(defaults: defaults, version: "5.1").shouldShowStewardCard())
    }

    // MARK: - One round per release

    /// Silence is the only soft no on this card, so it has to work: three
    /// unanswered launches end the round.
    @MainActor
    func testThreeUnansweredLaunchesEndTheRound() {
        let defaults = makeDefaults("Steward.impressions")
        markEligible(defaults)

        for _ in 0..<3 {
            let launch = makeCoordinator(defaults: defaults)
            XCTAssertTrue(launch.shouldShowStewardCard())
            launch.noteStewardCardShown()
        }

        XCTAssertEqual(defaults.onboardingStewardAskState, .askedThisRelease)
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStewardCard())
    }

    /// The card re-renders many times per launch; only the first counts.
    @MainActor
    func testImpressionsAreCountedOncePerLaunch() {
        let defaults = makeDefaults("Steward.oneImpression")
        markEligible(defaults)

        let coordinator = makeCoordinator(defaults: defaults)
        for _ in 0..<10 { coordinator.noteStewardCardShown() }
        XCTAssertEqual(defaults.onboardingStewardAskImpressions, 1)
        XCTAssertEqual(defaults.onboardingStewardAskState, .notAsked)
    }

    /// A release bump re-arms the ask with a fresh budget of launches.
    @MainActor
    func testANewReleaseReArmsTheAskWithAFreshBudget() {
        let defaults = makeDefaults("Steward.reArm")
        markEligible(defaults)

        for _ in 0..<3 {
            makeCoordinator(defaults: defaults).noteStewardCardShown()
        }
        XCTAssertFalse(makeCoordinator(defaults: defaults).shouldShowStewardCard())

        let afterBump = makeCoordinator(defaults: defaults, version: "5.1")
        XCTAssertTrue(afterBump.shouldShowStewardCard())
        XCTAssertEqual(defaults.onboardingStewardAskImpressions, 0)
    }

    /// The lifetime cap. Someone who has ignored this across three releases is
    /// not going to sign up, and a fourth ask is nagging.
    @MainActor
    func testThreeIgnoredReleasesStopTheAskForGood() {
        let defaults = makeDefaults("Steward.lifetimeCap")
        markEligible(defaults)

        for (round, version) in ["5.0", "5.1", "5.2"].enumerated() {
            for _ in 0..<3 {
                let launch = makeCoordinator(defaults: defaults, version: version)
                XCTAssertTrue(launch.shouldShowStewardCard(), "round \(round) should still be asked")
                launch.noteStewardCardShown()
            }
        }

        XCTAssertEqual(defaults.onboardingStewardAskRoundsSpent, 3)
        XCTAssertEqual(defaults.onboardingStewardAskState, .dismissedForever)
        XCTAssertFalse(makeCoordinator(defaults: defaults, version: "5.3").shouldShowStewardCard())
    }

    /// A card that only reached the slot because this one's round just ended was
    /// never really seen, so it must not be charged an impression.
    ///
    /// Ending a round writes only to `UserDefaults`, so the steward card stays on
    /// screen — but any later rebuild in the same launch re-evaluates the chain,
    /// finds the steward ask spent, and renders the contribute card into a
    /// session the user is already looking at something else in.
    @MainActor
    func testEndingTheRoundDoesNotChargeTheNextCardAnImpression() {
        let defaults = makeDefaults("Steward.noStolenImpression")
        markEligible(defaults)
        // Two launches of this round already spent; this one ends it.
        defaults.onboardingStewardAskImpressions = 2

        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.noteStewardCardShown()
        XCTAssertEqual(defaults.onboardingStewardAskState, .askedThisRelease)

        // The contribute card is what the freed slot falls through to.
        coordinator.noteContributeCardShown()
        XCTAssertEqual(defaults.onboardingContributeAskImpressions, 0)
        XCTAssertEqual(defaults.onboardingContributeAskState, .notAsked)

        // Next launch it is charged normally.
        let nextLaunch = makeCoordinator(defaults: defaults)
        nextLaunch.noteContributeCardShown()
        XCTAssertEqual(defaults.onboardingContributeAskImpressions, 1)
    }

    // MARK: - Copy

    /// The headline qualifies the reader before it asks them for anything, so
    /// someone who does not run this agent can stop at the first two words.
    @MainActor
    func testTitleAsksWhetherTheyUseTheAgent() {
        XCTAssertEqual(String(localized: StewardCard.titleText(for: Self.qwen)), "Use Qwen Code?")
        XCTAssertEqual(String(localized: StewardCard.titleText(for: Self.grok)), "Use Grok CLI?")
    }

    /// Qwen keeps its own reason: it is the one agent that cannot be checked here
    /// at all, and softening that into the generic plea loses the whole point.
    @MainActor
    func testQwenCopyNamesTheReasonItCannotBeChecked() {
        let body = String(localized: StewardCard.bodyText(for: Self.qwen))

        XCTAssertTrue(body.hasPrefix("Looking for a steward"), body)
        XCTAssertTrue(body.contains("free tier ended"), body)
        XCTAssertTrue(body.contains("nothing shared"), body)
    }

    @MainActor
    func testGenericCopyLeadsWithTheAsk() {
        let body = String(localized: StewardCard.bodyText(for: Self.grok))

        XCTAssertTrue(body.hasPrefix("Looking for a steward"), body)
        XCTAssertTrue(body.contains("nothing shared"), body)
    }

    // MARK: - Narrow-pane layout

    /// The session list can be dragged to 320pt. At that width the actions and
    /// the icon take more than the whole card, so a single-row layout squeezes
    /// the text column below the width of one long word and SwiftUI breaks it
    /// mid-word. Both wrapping cards must switch layouts before that.
    @MainActor
    func testCardsWrapTheirActionsInANarrowPane() {
        let listPaneMinimumWidth: CGFloat = 320
        XCTAssertGreaterThan(
            WrappingSlotCard.minimumWideWidth,
            listPaneMinimumWidth,
            "the list's narrowest pane must select the wrapped layout"
        )
        // And the common case is not dragged into it.
        XCTAssertLessThan(WrappingSlotCard.minimumWideWidth, 900)
    }

    /// Zero means "not measured yet", not "infinitely narrow" — treating it as
    /// compact would flip every card's layout on the first frame of every launch.
    @MainActor
    func testUnmeasuredWidthUsesTheWideLayout() {
        let card = WrappingSlotCard(
            palette: OnboardingPalette(colorScheme: .light),
            iconName: "checkmark.seal",
            iconTint: .blue,
            title: "Use Qwen Code?",
            message: "Looking for a steward.",
            actions: [SlotCardAction(id: "become-steward", title: "Become the steward", isProminent: true, perform: {})],
            dismissHelp: "Don't ask again",
            onDismiss: {},
            paneWidth: 0
        )
        XCTAssertFalse(card.prefersCompactLayout)

        var measured = card
        measured.paneWidth = 340
        XCTAssertTrue(measured.prefersCompactLayout)
    }

    /// No month or version in shipped copy: STEWARDS.md is one click away behind
    /// "What's involved" and can be corrected without cutting a release.
    @MainActor
    func testCopyQuotesNoDateOrVersion() {
        for agent in StewardAskEligibility.stewardlessAgents {
            let copy = String(localized: StewardCard.titleText(for: agent)) + " " + String(localized: StewardCard.bodyText(for: agent))
            XCTAssertNil(
                copy.range(of: #"\b(20\d\d|\d+\.\d+)\b"#, options: .regularExpression),
                "\(agent.stewardName) copy pins a date or version: \(copy)"
            )
        }
    }
}
