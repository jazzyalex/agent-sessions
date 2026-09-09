import CryptoKit
import Foundation

/// What the coordinator asks the modal onboarding window to present.
/// Updates never present a modal — they publish `whatsNewMajorMinor` instead.
enum OnboardingPresentation: Equatable {
    /// Fresh-install single setup screen (agents + Quota Meter + Start Exploring).
    case firstRunSetup
    /// Legacy multi-slide Power Tips tour (Help → Power Tips). Untouched by the rework.
    case powerTips(OnboardingContent)
}

/// The single top-slot surface selected for this launch. The view freezes this
/// value once chosen so an unrelated list rebuild cannot swap in another ask.
enum TopSlotCardSelection: Equatable {
    case whatsNew(String)
    case quotaMeter
    case star
    case feedback
    case language
    case steward(StewardAgent)
    case contribute

    var persistenceIdentifier: String {
        switch self {
        case .whatsNew: return "whats-new"
        case .quotaMeter: return "quota-meter"
        case .star: return "star"
        case .feedback: return "feedback"
        case .language: return "language"
        case .steward: return "steward"
        case .contribute: return "contribute"
        }
    }
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// The public repository the star ask points at. Held here so the card, the
    /// menu item, and the tests can never drift onto different URLs.
    ///
    /// `nonisolated` so the `nonisolated` URL builders below can read it: it is
    /// an immutable `let` of a `Sendable` type, so the enclosing `@MainActor`
    /// buys it nothing and only makes it an error to read off the main actor.
    nonisolated static let githubRepositoryURL = URL(string: "https://github.com/jazzyalex/agent-sessions")!

    /// How long "Maybe later" silences the star ask before its single retry.
    static let starAskSnoozeInterval: TimeInterval = 14 * 86_400

    /// Sessions opened before the star ask is due. Deliberately well above the
    /// feedback card's 10: this asks a favour of people who stayed, not of
    /// someone still deciding whether the app is for them.
    static let starAskSessionsThreshold = 25

    /// Days since first launch that make the star ask due on their own, for
    /// someone who keeps the app around without opening many sessions.
    static let starAskDaysThreshold: Double = 30

    /// Launches a round of the star ask may go unanswered before it spends
    /// itself. Ignoring a card is an answer; without this the ask would repeat
    /// on every eligible launch forever, which is exactly the nagging the
    /// "Maybe later" / dismiss pair exists to prevent.
    static let starAskMaxImpressionsPerRound = 3

    /// Days the star ask may wait behind the Quota Meter card before it takes
    /// the slot for itself.
    static let starAskPriorityAfterDays: Double = 14

    /// Launches a version's What's New card may go unanswered before it stands
    /// down. Same budget and same reasoning as the star ask: ignoring a card is
    /// an answer, and without this the card returns on every launch until the
    /// next minor, holding the slot against every ask queued behind it.
    static let whatsNewMaxImpressionsPerVersion = 3
    static let quotaMeterAskMaxImpressionsPerRound = 3
    static let feedbackAskMaxImpressionsPerRound = 3

    /// Minimum quiet time before the slot switches to a different campaign.
    /// Repeated launches of the same bounded round are unaffected.
    static let topSlotInterCardQuietPeriod: TimeInterval = 5 * 86_400

    /// Where "Contribute an agent" sends the user: the repository's structured
    /// proposal form. Built from `githubRepositoryURL` so the card, the menu
    /// item, and this can never drift onto different repositories.
    ///
    /// Interpolated rather than `appendingPathComponent` — the query string is
    /// part of the destination, and path appending would percent-escape the `?`.
    static let contributeAgentSourceURL = URL(
        string: "\(githubRepositoryURL.absoluteString)/issues/new?template=new-agent-source.yml"
    )!

    /// The "How it works" link: both contribution routes (implement it, or hand
    /// over sanitized format evidence) are described there.
    static let contributeGuideURL = URL(
        string: "\(githubRepositoryURL.absoluteString)/blob/main/docs/CONTRIBUTING.md"
    )!

    /// How long "Maybe later" silences the contribute ask before its single retry.
    static let contributeAskSnoozeInterval: TimeInterval = 14 * 86_400

    /// Sessions opened before the contribute ask is due. Someone who has browsed
    /// this much has an opinion about which agents are missing.
    static let contributeAskSessionsThreshold = 60

    /// Days since first launch that make the contribute ask due on their own.
    /// Higher than the star ask's 30 so the two never come due together.
    static let contributeAskDaysThreshold: Double = 45

    /// Launches a round of the contribute ask may go unanswered before it spends
    /// itself, exactly as "Maybe later" would.
    static let contributeAskMaxImpressionsPerRound = 3

    /// Days the contribute ask may wait behind the feedback card before it takes
    /// the slot for itself. Same value and same reasoning as the star ask's wait
    /// behind the Quota Meter card.
    static let contributeAskPriorityAfterDays: Double = 14

    /// The translation invitation lands on the contributor-facing workflow,
    /// not the implementation conventions alone. The fragment keeps the user
    /// at the exact job the card offered.
    static let languageContributionURL = URL(
        string: "\(githubRepositoryURL.absoluteString)/blob/main/docs/CONTRIBUTING.md#translate-agent-sessions"
    )!

    /// Detailed catalog and review rules for contributors who want to inspect
    /// the work before deciding to take it on.
    static let localizationGuideURL = URL(
        string: "\(githubRepositoryURL.absoluteString)/blob/main/docs/localization.md"
    )!

    static let languageAskSnoozeInterval: TimeInterval = 14 * 86_400
    static let languageAskSessionsThreshold = 40
    static let languageAskDaysThreshold: Double = 45
    static let languageAskMaxImpressionsPerRound = 3
    static let languageAskPriorityAfterDays: Double = 14

    /// The steward job description, linked from the card's "What's involved".
    static let stewardGuideURL = URL(
        string: "\(githubRepositoryURL.absoluteString)/blob/main/STEWARDS.md"
    )!

    /// Where "Become the steward" sends the user: the signup form with the agent
    /// field pre-filled, so the one thing we know and they would have to type is
    /// already there.
    ///
    /// The agent name is the only thing that travels in the URL. Session counts,
    /// paths, and which other agents they run stay on their Mac — the form is a
    /// public issue, and they see every field before submitting it.
    /// `nonisolated` because it builds a URL and touches no coordinator state —
    /// the enclosing type's `@MainActor` would otherwise leak onto every caller.
    nonisolated static func stewardSignupURL(for agent: StewardAgent) -> URL {
        var components = URLComponents(string: "\(githubRepositoryURL.absoluteString)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "steward-signup.yml"),
            URLQueryItem(name: "agent", value: agent.stewardName)
        ]
        // The form without a prefill still works; a nil URL would drop the ask.
        return components?.url ?? githubRepositoryURL
    }

    /// Sessions opened before the steward ask is due. Deliberately the contribute
    /// ask's bar: both ask for real, recurring work, so sharing the bar means the
    /// two come due together and the chain order — targeted ask first — decides
    /// which one is spent on this user.
    static let stewardAskSessionsThreshold = 25

    /// Days since first launch that make the steward ask due on their own.
    static let stewardAskDaysThreshold: Double = 45

    /// Launches a round of the steward ask may go unanswered before it spends
    /// itself. There is no "Maybe later" here, so silence is the only soft no.
    static let stewardAskMaxImpressionsPerRound = 3

    /// Days the steward ask may wait behind the feedback card before it takes the
    /// slot. Same value and reasoning as the contribute ask's wait.
    static let stewardAskPriorityAfterDays: Double = 14

    /// Releases the steward ask may spend before it stops for good. One round per
    /// release re-arms an ask the user simply never saw; three of them is the
    /// point where continuing to ask is nagging.
    static let stewardAskMaxRounds = 3

    /// Drives the modal onboarding window (first-run setup or Power Tips tour).
    @Published var presentation: OnboardingPresentation?

    /// Non-nil when an undismissed What's New card should appear in the session-list
    /// top slot for this major.minor. Set on a version bump, cleared on dismiss.
    @Published var whatsNewMajorMinor: String?

    /// The version the compact What's New panel renders (may be set from the card or
    /// from Help → What's New even after the card was dismissed).
    @Published var whatsNewPanelVersion: String?

    /// Presents the compact What's New panel (Esc-dismissible sheet).
    @Published var isWhatsNewPanelPresented: Bool = false

    /// Presents the standalone native feedback prompt (from the feedback card).
    @Published var isFeedbackPromptPresented: Bool = false

    /// Set after either feedback-card exit so it cannot reappear during this
    /// launch. "Not now" advances the bounded release-round lifecycle; the
    /// close button ends the ask permanently.
    @Published var feedbackCardSuppressedThisLaunch: Bool = false

    /// Presents the Quota Meter explainer sheet (from the Quota Meter card).
    @Published var isQuotaMeterPromoPresented: Bool = false

    /// Hides the Quota Meter card for the rest of this launch.
    @Published var quotaMeterCardSuppressedThisLaunch: Bool = false

    /// Hides the star card for the rest of this launch. In-memory only; the
    /// persistent decision lives in `UserDefaults.onboardingStarAskState`.
    @Published var starCardSuppressedThisLaunch: Bool = false

    /// Hides the contribute card for the rest of this launch. In-memory only;
    /// the persistent decision lives in `UserDefaults.onboardingContributeAskState`.
    @Published var contributeCardSuppressedThisLaunch: Bool = false

    /// Hides the translation card for the rest of this launch. The persistent
    /// decision lives in `UserDefaults.onboardingLanguageAskState`.
    @Published var languageCardSuppressedThisLaunch: Bool = false

    /// The stewardless agent this user actually runs, or nil when none qualifies.
    ///
    /// Assigned by the session list once the index loads, exactly as the Quota
    /// Meter card's availability is passed in: the coordinator never reads
    /// sessions itself and stays a pure state machine. Nil until then, which is
    /// also the correct answer — the card must not ask before we know.
    @Published var stewardAskTarget: StewardAgent?

    /// Hides the steward card for the rest of this launch. In-memory only; the
    /// persistent decision lives in `UserDefaults.onboardingStewardAskState`.
    @Published var stewardCardSuppressedThisLaunch: Bool = false

    /// Set once the user resolves any top-slot card. The slot shows one card at
    /// a time, but that alone only orders the queue — without this, dismissing
    /// the winner hands the slot straight to the runner-up on the same render,
    /// so a single ✕ produces a second ask. One ask per launch; the rest wait.
    /// In-memory only.
    @Published var didConsumeTopSlotAskThisLaunch: Bool = false

    private let defaults: UserDefaults
    private let currentMajorMinorProvider: () -> String?
    private let isFreshInstallProvider: () -> Bool
    private let whatsNewAvailableProvider: (String) -> Bool
    private let preferredLanguagesProvider: () -> [String]
    private let shippedLocalizationsProvider: () -> [String]
    private let now: () -> Date
    private var hasChecked: Bool = false
    /// One impression per launch, not per render: `.onAppear` fires again every
    /// time the list rebuilds the card.
    private var didCountStarImpressionThisLaunch: Bool = false
    /// Same one-impression-per-launch rule for the What's New card.
    private var didCountWhatsNewImpressionThisLaunch: Bool = false
    private var didCountQuotaMeterImpressionThisLaunch: Bool = false
    private var didCountFeedbackImpressionThisLaunch: Bool = false
    private var didRecordTopSlotCardAppearanceThisLaunch: Bool = false
    /// Same one-impression-per-launch rule for the contribute card.
    private var didCountContributeImpressionThisLaunch: Bool = false
    /// Same one-impression-per-launch rule for the translation card.
    private var didCountLanguageImpressionThisLaunch: Bool = false
    /// Same one-impression-per-launch rule for the steward card.
    private var didCountStewardImpressionThisLaunch: Bool = false
    /// Set when any card's round ended during this launch.
    ///
    /// Ending a round retires that card, which frees the slot for the next card
    /// in the chain — and a card that reaches the slot that way appeared partway
    /// through a session the user was already looking at something else in.
    /// Charging it an impression spends an ask on attention it never got.
    ///
    /// Deliberately **not** `@Published`. Publishing here would rebuild the list
    /// the moment a round ends, and since the round ends from `.onAppear`, the
    /// card that just spent it would vanish on the very launch it was shown.
    /// Ending a round otherwise writes only to `UserDefaults`, so the card stays
    /// on screen for the rest of the launch, which is the intended behaviour.
    private var didEndAnAskRoundThisLaunch: Bool = false
    /// True for the duration of a launch that showed the first-run setup — feedback
    /// must never appear in the same session as first run.
    private(set) var didPresentFreshInstallThisLaunch: Bool = false

    init(
        defaults: UserDefaults = .standard,
        currentMajorMinorProvider: @escaping () -> String? = OnboardingContent.currentMajorMinor,
        isFreshInstallProvider: @escaping () -> Bool = OnboardingCoordinator.defaultIsFreshInstall,
        whatsNewAvailableProvider: @escaping (String) -> Bool = { WhatsNewCatalog.hasContent(for: $0) },
        preferredLanguagesProvider: @escaping () -> [String] = { Locale.preferredLanguages },
        shippedLocalizationsProvider: @escaping () -> [String] = { Bundle.main.localizations },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.currentMajorMinorProvider = currentMajorMinorProvider
        self.isFreshInstallProvider = isFreshInstallProvider
        self.whatsNewAvailableProvider = whatsNewAvailableProvider
        self.preferredLanguagesProvider = preferredLanguagesProvider
        self.shippedLocalizationsProvider = shippedLocalizationsProvider
        self.now = now
    }

    // MARK: - Launch check

    func checkAndPresentIfNeeded() {
        guard !hasChecked else { return }
        hasChecked = true

        guard let majorMinor = currentMajorMinorProvider() else { return }
        if defaults.onboardingFirstLaunchDate == nil {
            defaults.onboardingFirstLaunchDate = now()
        }

        let previousMajorMinor = defaults.onboardingLastSeenAppMajorMinor ?? defaults.onboardingLastActionMajorMinor
        defaults.onboardingLastSeenAppMajorMinor = majorMinor

        // Stamped once, the first launch on which the star ask qualifies. The
        // aging rule needs to know how long it has been waiting, and the card
        // itself may never render while another card holds the slot.
        if defaults.onboardingStarAskDueSince == nil, starAskTriggerMet() {
            defaults.onboardingStarAskDueSince = now()
        }

        // Same stamp for the contribute ask, and for the same reason: it sits at
        // the bottom of the chain and may wait many launches without rendering.
        if defaults.onboardingContributeAskDueSince == nil, contributeAskTriggerMet() {
            defaults.onboardingContributeAskDueSince = now()
        }

        refreshLanguageAskTarget()
        if defaults.onboardingLanguageAskDueSince == nil, languageAskTriggerMet() {
            defaults.onboardingLanguageAskDueSince = now()
        }

        // And for the steward ask. Stamped on the retention gate alone: whether
        // a stewardless agent is on this Mac is not known until the index loads,
        // and the wait this measures has started either way.
        if defaults.onboardingStewardAskDueSince == nil, stewardAskTriggerMet() {
            defaults.onboardingStewardAskDueSince = now()
        }

        if isFreshInstallProvider(), !defaults.onboardingFullTourCompleted {
            didPresentFreshInstallThisLaunch = true
            presentation = .firstRunSetup
            return
        }

        if shouldOfferWhatsNew(current: majorMinor, previous: previousMajorMinor) {
            whatsNewMajorMinor = majorMinor
        }
    }

    private func shouldOfferWhatsNew(current: String, previous: String?) -> Bool {
        if isFreshInstallProvider() { return false }
        if shouldSuppressUpdate(currentMajorMinor: current, previousMajorMinor: previous) { return false }
        if defaults.onboardingWhatsNewDismissedMajorMinor == current { return false }
        // Legacy signal: a version already actioned via the old update tour never re-flags.
        if defaults.onboardingLastActionMajorMinor == current { return false }
        // Silence is an answer, same as every other card in the top slot.
        if whatsNewImpressionBudgetSpent(for: current) { return false }
        return whatsNewAvailableProvider(current)
    }

    /// Whether this version's card has already had its three launches.
    private func whatsNewImpressionBudgetSpent(for majorMinor: String) -> Bool {
        guard defaults.onboardingWhatsNewImpressionsVersion == majorMinor else { return false }
        return defaults.onboardingWhatsNewImpressions >= Self.whatsNewMaxImpressionsPerVersion
    }

    /// Preserves the historical 2.11 → 2.12 suppression from the old update-tour matrix.
    private func shouldSuppressUpdate(currentMajorMinor: String, previousMajorMinor: String?) -> Bool {
        currentMajorMinor == "2.12" && previousMajorMinor == "2.11"
    }

    // MARK: - Modal presentation

    /// Help → Show Onboarding re-runs the first-run setup screen.
    func presentManually() {
        presentation = .firstRunSetup
    }

    func presentPowerTips() {
        guard let majorMinor = currentMajorMinorProvider() else { return }
        presentation = .powerTips(OnboardingContent.powerTipsTour(for: majorMinor))
    }

    /// Called when the modal setup screen is dismissed (button or Esc). Records
    /// completion so first-run never re-appears; Power Tips records nothing.
    func complete() {
        recordAndDismissPresentation()
    }

    func skip() {
        recordAndDismissPresentation()
    }

    private func recordAndDismissPresentation() {
        if case .firstRunSetup = presentation {
            defaults.onboardingFullTourCompleted = true
            if let majorMinor = currentMajorMinorProvider() {
                defaults.onboardingLastActionMajorMinor = majorMinor
            }
        }
        presentation = nil
    }

    // MARK: - What's New

    func openWhatsNewPanel(version: String?) {
        whatsNewPanelVersion = version ?? currentMajorMinorProvider()
        isWhatsNewPanelPresented = true
    }

    /// The card's primary action. Reading the notes is an answer: it records the
    /// version handled exactly as the ✕ does, so the card does not return next
    /// launch and the queue behind it advances.
    ///
    /// Deliberately a separate entry point rather than a flag on
    /// `openWhatsNewPanel(version:)`, which Help → What's New also calls: a
    /// defaulted parameter is one forgotten argument away from the menu
    /// retiring a card the user never saw.
    ///
    /// Spends the launch's ask for the same reason `dismissWhatsNewCard()` and
    /// `recordQuotaMeterActivated()` do — someone who just acted should not have
    /// the next card swapped in behind the opening panel.
    func openWhatsNewFromCard(version: String) {
        // Only an armed card can retire a version, mirroring the guard in
        // `dismissWhatsNewCard()`. This is what makes the separate entry point
        // structurally safe rather than safe by convention: a future caller that
        // reaches it without the card on screen gets the panel and nothing else,
        // instead of silently retiring a card the user never saw.
        // Retire the version that is actually armed, not the one passed in: the
        // two are the same from the card, and binding the armed one keeps them
        // from ever diverging for a caller where they are not.
        if let armed = whatsNewMajorMinor {
            defaults.onboardingWhatsNewDismissedMajorMinor = armed
            didConsumeTopSlotAskThisLaunch = true
            whatsNewMajorMinor = nil
        }
        openWhatsNewPanel(version: version)
    }

    /// Records that this launch put the What's New card on screen.
    ///
    /// Mirrors `noteStarCardShown()`: the view calls it from `.onAppear` while
    /// rendering, so it must be idempotent within a launch. Spending the budget
    /// does not clear `whatsNewMajorMinor` — the card stays for the rest of this
    /// launch and stands down starting with the next one, because a card that
    /// vanishes while it is being read is worse than one that stays a launch too
    /// long.
    func noteWhatsNewCardShown() {
        guard !didCountWhatsNewImpressionThisLaunch else { return }
        guard let current = currentMajorMinorProvider() else { return }
        didCountWhatsNewImpressionThisLaunch = true

        if defaults.onboardingWhatsNewImpressionsVersion != current {
            defaults.onboardingWhatsNewImpressionsVersion = current
            defaults.onboardingWhatsNewImpressions = 0
        }
        defaults.onboardingWhatsNewImpressions += 1
    }

    /// Help → What's New — always opens the panel for the current version, even if
    /// the card was dismissed. Does not resurrect the card.
    func presentWhatsNewFromMenu() {
        openWhatsNewPanel(version: currentMajorMinorProvider())
    }

    /// User dismissed the What's New card. Records the version so it never returns.
    func dismissWhatsNewCard() {
        if let majorMinor = whatsNewMajorMinor {
            defaults.onboardingWhatsNewDismissedMajorMinor = majorMinor
        }
        didConsumeTopSlotAskThisLaunch = true
        whatsNewMajorMinor = nil
    }

    // MARK: - Feedback timing

    /// Counts a distinct session once toward retention gates. Existing installs
    /// keep their historical count; new activity is deduplicated by a local hash.
    func noteSessionOpened(id: String) {
        guard defaults.onboardingSessionsOpenedCount < Self.contributeAskSessionsThreshold else { return }
        let fingerprint = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var fingerprints = Set(defaults.onboardingOpenedSessionFingerprints)
        guard fingerprints.insert(fingerprint).inserted else { return }

        // No card has a sessions threshold above 60, so retaining more hashes
        // serves no targeting purpose.
        defaults.onboardingOpenedSessionFingerprints = fingerprints.sorted()
        defaults.onboardingSessionsOpenedCount += 1
    }

    /// True when the one-time native feedback ask should be surfaced now.
    /// Earliest of: 10 sessions opened OR 14 days since install; never on first run;
    /// respects the ask/declined/completed lifecycle.
    func isFeedbackAskDue() -> Bool {
        if didPresentFreshInstallThisLaunch { return false }

        switch defaults.onboardingFeedbackAskState {
        case .completed, .dismissedForever:
            return false
        case .notAsked:
            break
        case .declinedOnce:
            // Eligible again only after a major.minor bump since the decline.
            guard let current = currentMajorMinorProvider(),
                  defaults.onboardingFeedbackDeclinedAtMajorMinor != current else {
                return false
            }
        }

        return usageTriggerMet()
    }

    /// Whether the feedback card should occupy the session-list top slot.
    /// What's New always wins the slot, and "Not now" ends this release's round.
    func shouldShowFeedbackCard() -> Bool {
        if languageAskOutranksFeedbackCard() { return false }
        if stewardAskOutranksFeedbackCard() { return false }
        if contributeAskOutranksFeedbackCard() { return false }
        return whatsNewMajorMinor == nil
            && !didConsumeTopSlotAskThisLaunch
            && !feedbackCardSuppressedThisLaunch
            && isFeedbackAskDue()
    }

    /// Silence is the first decline. Three ignored launches end this release's
    /// round exactly as pressing "Not now" in the prompt would.
    func noteFeedbackCardShown() {
        guard !didCountFeedbackImpressionThisLaunch else { return }
        guard let current = currentMajorMinorProvider() else { return }
        didCountFeedbackImpressionThisLaunch = true

        if defaults.onboardingFeedbackAskImpressionsVersion != current {
            defaults.onboardingFeedbackAskImpressionsVersion = current
            defaults.onboardingFeedbackAskImpressions = 0
        }
        defaults.onboardingFeedbackAskImpressions += 1
        if defaults.onboardingFeedbackAskImpressions >= Self.feedbackAskMaxImpressionsPerRound {
            endFeedbackAskRound()
        }
    }

    /// "Not now" on the feedback card. Ends this release's round, then allows
    /// one final round after a major/minor bump.
    func suppressFeedbackCardThisLaunch() {
        recordFeedbackDeclined()
    }

    func dismissFeedbackAskForever() {
        feedbackCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        defaults.onboardingFeedbackAskState = .dismissedForever
        isFeedbackPromptPresented = false
    }

    // MARK: - Quota Meter activation

    /// Whether the Quota Meter card should occupy the session-list top slot.
    ///
    /// Slot order is What's New > Quota Meter > feedback: activation before
    /// extraction. Feedback waits for 10 sessions or 14 days anyway, so in
    /// practice it rarely competes.
    ///
    /// The environmental facts are passed in rather than read here — the view
    /// owns the indexers, and this stays a pure state machine.
    ///
    /// - Parameters:
    ///   - hasCodexOrClaudeSessions: the Quota Meter reports Codex and Claude
    ///     quota only, so it is noise to anyone without those sessions.
    ///   - isQuotaMeterActive: usage tracking on *and* the cockpit opened at
    ///     least once. Tracking alone is not "using it" — that is precisely the
    ///     audience that has the data flowing but has never seen the window.
    func shouldShowQuotaMeterCard(hasCodexOrClaudeSessions: Bool, isQuotaMeterActive: Bool) -> Bool {
        guard !starAskOutranksQuotaMeterCard() else { return false }
        guard whatsNewMajorMinor == nil else { return false }
        guard !didConsumeTopSlotAskThisLaunch else { return false }
        guard !quotaMeterCardSuppressedThisLaunch else { return false }
        guard !didPresentFreshInstallThisLaunch else { return false }
        guard hasCodexOrClaudeSessions, !isQuotaMeterActive else { return false }

        switch defaults.onboardingQuotaMeterAskState {
        case .activated, .dismissedForever:
            return false
        case .notAsked:
            return true
        case .dismissedOnce:
            // Eligible again only after a major.minor bump since the dismissal.
            guard let current = currentMajorMinorProvider(),
                  defaults.onboardingQuotaMeterDeclinedAtMajorMinor != current else {
                return false
            }
            return true
        }
    }

    /// Caps an ignored Quota Meter invitation to three launches per release.
    /// Its second release-round ends the campaign permanently.
    func noteQuotaMeterCardShown() {
        guard !didCountQuotaMeterImpressionThisLaunch else { return }
        guard let current = currentMajorMinorProvider() else { return }
        didCountQuotaMeterImpressionThisLaunch = true

        if defaults.onboardingQuotaMeterAskImpressionsVersion != current {
            defaults.onboardingQuotaMeterAskImpressionsVersion = current
            defaults.onboardingQuotaMeterAskImpressions = 0
        }
        defaults.onboardingQuotaMeterAskImpressions += 1
        if defaults.onboardingQuotaMeterAskImpressions >= Self.quotaMeterAskMaxImpressionsPerRound {
            endQuotaMeterAskRound()
        }
    }

    /// "Not now" ends this release's round. The close button is a separate,
    /// permanent exit.
    func suppressQuotaMeterCardThisLaunch() {
        recordQuotaMeterDeclined()
    }

    func dismissQuotaMeterAskForever() {
        quotaMeterCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        defaults.onboardingQuotaMeterAskState = .dismissedForever
        isQuotaMeterPromoPresented = false
    }

    /// The user opened the Quota Meter — never ask again. Also spends the
    /// launch's ask: someone who just acted should not be handed the feedback
    /// card the instant this one leaves the slot.
    func recordQuotaMeterActivated() {
        defaults.onboardingQuotaMeterAskState = .activated
        didConsumeTopSlotAskThisLaunch = true
        isQuotaMeterPromoPresented = false
    }

    /// Dismissed: ask once more after the next major.minor bump, then never again.
    func recordQuotaMeterDeclined() {
        quotaMeterCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endQuotaMeterAskRound()
        isQuotaMeterPromoPresented = false
    }

    /// Advances at most once in a launch. The third impression ends the round
    /// while leaving the card readable; a later "Not now" on that same rendered
    /// card consumes the slot without accidentally spending the next round too.
    private func endQuotaMeterAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingQuotaMeterAskState {
        case .notAsked:
            defaults.onboardingQuotaMeterAskState = .dismissedOnce
            defaults.onboardingQuotaMeterDeclinedAtMajorMinor = currentMajorMinorProvider()
        case .dismissedOnce:
            defaults.onboardingQuotaMeterAskState = .dismissedForever
        case .activated, .dismissedForever:
            return
        }
        didEndAnAskRoundThisLaunch = true
    }

    /// Records that the cockpit has been seen, retiring the card's audience test.
    func noteCockpitOpened() {
        guard !defaults.onboardingCockpitEverOpened else { return }
        defaults.onboardingCockpitEverOpened = true
    }

    var hasEverOpenedCockpit: Bool { defaults.onboardingCockpitEverOpened }

    // MARK: - GitHub star ask

    /// Whether the star card should occupy the session-list top slot.
    ///
    /// Slot order is What's New > Quota Meter > star > feedback. The star sits
    /// above feedback because it terminates: every path out of it — starred,
    /// dismissed, or a second "Maybe later" — is permanent, so it can occupy the
    /// slot at most twice. Feedback has its own bounded release-round lifecycle;
    /// the star still goes first because its higher retention bar asks the more
    /// established audience. Its
    /// higher retention bar also means feedback (10 sessions or 14 days) has
    /// normally had its turn long before this comes due.
    ///
    /// Never fires on a fresh-install launch, and never asks again once the user
    /// has opened the repository.
    func shouldShowStarCard() -> Bool {
        guard whatsNewMajorMinor == nil else { return false }
        guard !didConsumeTopSlotAskThisLaunch else { return false }
        guard !starCardSuppressedThisLaunch else { return false }
        guard !didPresentFreshInstallThisLaunch else { return false }

        switch defaults.onboardingStarAskState {
        case .starred, .dismissedForever:
            return false
        case .notAsked:
            break
        case .snoozed:
            // One retry, and only once the snooze has actually elapsed. A missing
            // date would mean a snooze that never expires, so treat it as due.
            if let until = defaults.onboardingStarAskSnoozedUntil, now() < until {
                return false
            }
        }

        return starAskTriggerMet()
    }

    /// The user opened the repository — never ask again.
    func recordStarOpened() {
        defaults.onboardingStarAskState = .starred
        starCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
    }

    /// "Maybe later" — silent for two weeks, then exactly one retry. A second
    /// "Maybe later" is a no.
    func snoozeStarAsk() {
        starCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endStarAskRound()
    }

    /// Records that this launch put the star card on screen.
    ///
    /// `shouldShowStarCard()` is a pure query the view runs while rendering, so
    /// nothing about being *seen* advances the state — a user who quits without
    /// touching the card would get it again on every eligible launch, forever,
    /// and the feedback card behind it would never surface. Three unanswered
    /// launches end the round exactly as "Maybe later" would.
    func noteStarCardShown() {
        guard !didCountStarImpressionThisLaunch else { return }
        guard !didEndAnAskRoundThisLaunch else { return }
        didCountStarImpressionThisLaunch = true

        let seen = defaults.onboardingStarAskImpressions + 1
        defaults.onboardingStarAskImpressions = seen
        guard seen >= Self.starAskMaxImpressionsPerRound else { return }
        endStarAskRound()
    }

    /// The one transition both "Maybe later" and silence take: first round buys
    /// two weeks and a retry, second round is a no.
    private func endStarAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingStarAskState {
        case .notAsked:
            defaults.onboardingStarAskState = .snoozed
            defaults.onboardingStarAskSnoozedUntil = now().addingTimeInterval(Self.starAskSnoozeInterval)
            // The retry gets its own budget of launches.
            defaults.onboardingStarAskImpressions = 0
        case .snoozed:
            defaults.onboardingStarAskState = .dismissedForever
        case .starred, .dismissedForever:
            // Already terminal — nothing was spent, so nothing was freed.
            return
        }
        didEndAnAskRoundThisLaunch = true
    }

    /// The card's ✕ — an explicit no. Unlike the feedback card there is no second
    /// surface where a real decline is recorded, and "Maybe later" is right there
    /// for anyone who only wants it gone for now, so this is permanent.
    func dismissStarAskForever() {
        starCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true

        guard defaults.onboardingStarAskState != .starred else { return }
        defaults.onboardingStarAskState = .dismissedForever
    }

    /// Whether the star ask has waited long enough to take the slot from the
    /// Quota Meter card.
    ///
    /// Fixed priority alone is not enough: even with the Quota Meter's bounded
    /// release rounds, the star ask can repeatedly lose the slot while eligible.
    /// After two weeks of waiting it goes first; it then spends itself within
    /// two rounds and hands the slot straight back, so this cannot deadlock the
    /// other direction.
    func starAskOutranksQuotaMeterCard() -> Bool {
        guard let dueSince = defaults.onboardingStarAskDueSince else { return false }
        guard now().timeIntervalSince(dueSince) / 86_400 >= Self.starAskPriorityAfterDays else { return false }
        return shouldShowStarCard()
    }

    /// Retention test for the star ask: earliest of 25 sessions opened or 30 days
    /// since first launch. Same shape as `usageTriggerMet()`, higher bars.
    private func starAskTriggerMet() -> Bool {
        if defaults.onboardingSessionsOpenedCount >= Self.starAskSessionsThreshold { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        let days = now().timeIntervalSince(first) / 86_400
        return days >= Self.starAskDaysThreshold
    }

    // MARK: - Contribute a translation

    /// Whether the translation invitation should occupy the session-list slot.
    /// It is aimed only at an established user whose first preferred macOS
    /// language is not covered by a localization in the current app bundle.
    func shouldShowLanguageCard() -> Bool {
        guard whatsNewMajorMinor == nil else { return false }
        guard !didConsumeTopSlotAskThisLaunch else { return false }
        guard !languageCardSuppressedThisLaunch else { return false }
        guard !didPresentFreshInstallThisLaunch else { return false }
        guard hasUnsupportedPreferredLanguage else { return false }

        switch defaults.onboardingLanguageAskState {
        case .opened, .dismissedForever:
            return false
        case .notAsked:
            break
        case .snoozed:
            if let until = defaults.onboardingLanguageAskSnoozedUntil, now() < until {
                return false
            }
        }

        return languageAskTriggerMet()
    }

    /// The user opened either translation page — terminal, never ask again.
    func recordLanguageContributionOpened() {
        defaults.onboardingLanguageAskState = .opened
        languageCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
    }

    func snoozeLanguageAsk() {
        languageCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endLanguageAskRound()
    }

    func noteLanguageCardShown() {
        guard !didCountLanguageImpressionThisLaunch else { return }
        guard !didEndAnAskRoundThisLaunch else { return }
        didCountLanguageImpressionThisLaunch = true

        let seen = defaults.onboardingLanguageAskImpressions + 1
        defaults.onboardingLanguageAskImpressions = seen
        guard seen >= Self.languageAskMaxImpressionsPerRound else { return }
        endLanguageAskRound()
    }

    private func endLanguageAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingLanguageAskState {
        case .notAsked:
            defaults.onboardingLanguageAskState = .snoozed
            defaults.onboardingLanguageAskSnoozedUntil =
                now().addingTimeInterval(Self.languageAskSnoozeInterval)
            defaults.onboardingLanguageAskImpressions = 0
        case .snoozed:
            defaults.onboardingLanguageAskState = .dismissedForever
        case .opened, .dismissedForever:
            return
        }
        didEndAnAskRoundThisLaunch = true
    }

    func dismissLanguageAskForever() {
        languageCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true

        guard defaults.onboardingLanguageAskState != .opened else { return }
        defaults.onboardingLanguageAskState = .dismissedForever
    }

    func languageAskOutranksFeedbackCard() -> Bool {
        guard let dueSince = defaults.onboardingLanguageAskDueSince else { return false }
        guard now().timeIntervalSince(dueSince) / 86_400 >= Self.languageAskPriorityAfterDays else { return false }
        return shouldShowLanguageCard()
    }

    /// Earliest of 40 opened sessions or 45 days installed, and only for a
    /// preferred language that the shipped catalogs do not currently cover.
    private func languageAskTriggerMet() -> Bool {
        guard hasUnsupportedPreferredLanguage else { return false }
        if defaults.onboardingSessionsOpenedCount >= Self.languageAskSessionsThreshold { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        return now().timeIntervalSince(first) / 86_400 >= Self.languageAskDaysThreshold
    }

    private var hasUnsupportedPreferredLanguage: Bool {
        unsupportedPreferredLanguageIdentifier != nil
    }

    private var unsupportedPreferredLanguageIdentifier: String? {
        guard let preferred = preferredLanguagesProvider().first else { return nil }
        return Self.isSupportedLanguageIdentifier(
            preferred,
            shippedLocalizations: shippedLocalizationsProvider()
        ) ? nil : Self.normalizedLanguageIdentifier(preferred)
    }

    private func refreshLanguageAskTarget() {
        let target = unsupportedPreferredLanguageIdentifier
        guard defaults.onboardingLanguageAskTargetIdentifier != target else { return }
        defaults.onboardingLanguageAskTargetIdentifier = target
        defaults.onboardingLanguageAskDueSince = nil
        defaults.onboardingLanguageAskImpressions = 0
    }

    /// Locale coverage comes from the bundle being run, so adding a catalog
    /// automatically retires the ask for that language. Language variants share
    /// coverage except Chinese, where Simplified and Traditional are distinct.
    static func isSupportedLanguageIdentifier(
        _ identifier: String,
        shippedLocalizations: [String]
    ) -> Bool {
        let preferred = normalizedLanguageIdentifier(identifier)
        return shippedLocalizations.contains { localization in
            let shipped = normalizedLanguageIdentifier(localization)
            guard shipped != "base" else { return false }
            let preferredLanguage = preferred.split(separator: "-").first
            let shippedLanguage = shipped.split(separator: "-").first
            guard preferredLanguage == shippedLanguage else { return false }
            guard preferredLanguage == "zh" else { return true }

            let preferredScript = chineseScript(for: preferred)
            let shippedScript = chineseScript(for: shipped)
            return preferredScript == nil || shippedScript == nil || preferredScript == shippedScript
        }
    }

    private static func normalizedLanguageIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func chineseScript(for identifier: String) -> String? {
        let parts = Set(identifier.split(separator: "-").map(String.init))
        // An explicit script is authoritative even when paired with an unusual
        // region, for example zh-Hans-TW. Infer from region only when absent.
        if parts.contains("hant") { return "hant" }
        if parts.contains("hans") { return "hans" }
        if !parts.isDisjoint(with: ["tw", "hk", "mo"]) { return "hant" }
        if !parts.isDisjoint(with: ["cn", "sg", "my"]) { return "hans" }
        return nil
    }

    /// Central priority policy. The view calls this once after session inventory
    /// is ready, then keeps the answer fixed for the remainder of the launch.
    func selectTopSlotCard(
        hasCodexOrClaudeSessions: Bool,
        isQuotaMeterActive: Bool
    ) -> TopSlotCardSelection? {
        let candidate: TopSlotCardSelection?
        if let version = whatsNewMajorMinor {
            candidate = .whatsNew(version)
        } else if shouldShowQuotaMeterCard(
            hasCodexOrClaudeSessions: hasCodexOrClaudeSessions,
            isQuotaMeterActive: isQuotaMeterActive
        ) {
            candidate = .quotaMeter
        } else if shouldShowStarCard() {
            candidate = .star
        } else if shouldShowFeedbackCard() {
            candidate = .feedback
        } else if shouldShowLanguageCard() {
            candidate = .language
        } else if let target = stewardAskTarget, shouldShowStewardCard() {
            candidate = .steward(target)
        } else if shouldShowContributeCard() {
            candidate = .contribute
        } else {
            candidate = nil
        }

        guard let candidate, canShowAfterPreviousTopSlotCard(candidate) else { return nil }
        return candidate
    }

    /// What's New can be selected before session indexing completes, but still
    /// observes the same inter-card quiet period as every other card.
    func selectWhatsNewTopSlotCard() -> TopSlotCardSelection? {
        guard let version = whatsNewMajorMinor else { return nil }
        let candidate = TopSlotCardSelection.whatsNew(version)
        return canShowAfterPreviousTopSlotCard(candidate) ? candidate : nil
    }

    func noteTopSlotCardShown(_ card: TopSlotCardSelection) {
        guard !didRecordTopSlotCardAppearanceThisLaunch else { return }
        didRecordTopSlotCardAppearanceThisLaunch = true
        defaults.onboardingLastTopSlotCardIdentifier = card.persistenceIdentifier
        defaults.onboardingLastTopSlotCardShownAt = now()
    }

    private func canShowAfterPreviousTopSlotCard(_ card: TopSlotCardSelection) -> Bool {
        guard let previous = defaults.onboardingLastTopSlotCardIdentifier,
              previous != card.persistenceIdentifier,
              let shownAt = defaults.onboardingLastTopSlotCardShownAt else {
            return true
        }
        return now().timeIntervalSince(shownAt) >= Self.topSlotInterCardQuietPeriod
    }

    // MARK: - Contribute an agent source

    /// Whether the contribute card should occupy the session-list top slot.
    ///
    /// It sits last, below feedback: it asks for the most work of any card here,
    /// so anything else with something to say goes first — until it has waited
    /// `contributeAskPriorityAfterDays`, after which it ages past the feedback
    /// card only (see `contributeAskOutranksFeedbackCard()`). The star card
    /// outranks it unconditionally — there is no aging rule, because unlike the Quota
    /// Meter card the star ask always terminates within two rounds and hands the
    /// slot back on its own.
    ///
    /// Never fires on a fresh-install launch, and never asks again once the user
    /// has opened either contribution page.
    func shouldShowContributeCard() -> Bool {
        // The steward ask is this same invitation aimed at an agent we can see
        // the user runs, so it goes first whenever it has a target. It stays a
        // separate ask with its own lifecycle: spending it does not spend this
        // one, and a user with no stewardless agent sees exactly what they saw
        // before the steward card existed.
        guard !shouldShowStewardCard() else { return false }
        guard whatsNewMajorMinor == nil else { return false }
        guard !didConsumeTopSlotAskThisLaunch else { return false }
        guard !contributeCardSuppressedThisLaunch else { return false }
        guard !didPresentFreshInstallThisLaunch else { return false }

        switch defaults.onboardingContributeAskState {
        case .opened, .dismissedForever:
            return false
        case .notAsked:
            break
        case .snoozed:
            // One retry, once the snooze has actually elapsed. A missing date
            // would mean a snooze that never expires, so treat it as due.
            if let until = defaults.onboardingContributeAskSnoozedUntil, now() < until {
                return false
            }
        }

        return contributeAskTriggerMet()
    }

    /// The user opened a contribution page — terminal, never ask again.
    func recordContributeOpened() {
        defaults.onboardingContributeAskState = .opened
        contributeCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
    }

    /// "Maybe later" — silent for two weeks, then exactly one retry.
    func snoozeContributeAsk() {
        contributeCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endContributeAskRound()
    }

    /// Records that this launch put the contribute card on screen. Being ignored
    /// is an answer; three unanswered launches end the round like "Maybe later".
    func noteContributeCardShown() {
        guard !didCountContributeImpressionThisLaunch else { return }
        guard !didEndAnAskRoundThisLaunch else { return }
        didCountContributeImpressionThisLaunch = true

        let seen = defaults.onboardingContributeAskImpressions + 1
        defaults.onboardingContributeAskImpressions = seen
        guard seen >= Self.contributeAskMaxImpressionsPerRound else { return }
        endContributeAskRound()
    }

    /// One round only: the first buys two weeks and a retry, the second is a no.
    private func endContributeAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingContributeAskState {
        case .notAsked:
            defaults.onboardingContributeAskState = .snoozed
            defaults.onboardingContributeAskSnoozedUntil =
                now().addingTimeInterval(Self.contributeAskSnoozeInterval)
            // The retry gets its own budget of launches.
            defaults.onboardingContributeAskImpressions = 0
        case .snoozed:
            defaults.onboardingContributeAskState = .dismissedForever
        case .opened, .dismissedForever:
            // Already terminal — nothing was spent, so nothing was freed.
            return
        }
        didEndAnAskRoundThisLaunch = true
    }

    /// The card's ✕ — an explicit no, permanent. "Maybe later" is right beside it
    /// for anyone who only wants it gone for now.
    func dismissContributeAskForever() {
        contributeCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true

        guard defaults.onboardingContributeAskState != .opened else { return }
        defaults.onboardingContributeAskState = .dismissedForever
    }

    /// Whether the contribute ask has waited long enough to take the slot from
    /// the feedback card.
    ///
    /// Fixed priority alone is not enough, for the same reason the star ask ages
    /// past the feedback card. After two weeks of waiting it goes first; it then
    /// spends itself within two rounds and hands the slot straight back.
    ///
    /// This outranks the feedback card only — never What's New, the Quota Meter
    /// card, or the star ask, all of which still come first unconditionally.
    func contributeAskOutranksFeedbackCard() -> Bool {
        guard let dueSince = defaults.onboardingContributeAskDueSince else { return false }
        guard now().timeIntervalSince(dueSince) / 86_400 >= Self.contributeAskPriorityAfterDays else { return false }
        return shouldShowContributeCard()
    }

    /// Retention test for the contribute ask: earliest of 60 sessions opened or
    /// 45 days since first launch.
    private func contributeAskTriggerMet() -> Bool {
        if defaults.onboardingSessionsOpenedCount >= Self.contributeAskSessionsThreshold { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        let days = now().timeIntervalSince(first) / 86_400
        return days >= Self.contributeAskDaysThreshold
    }

    // MARK: - Steward an existing agent

    /// Whether the steward card should occupy the session-list top slot.
    ///
    /// It sits directly above the contribute card and below feedback: it asks
    /// for the same kind of work, but of someone we can see already has the
    /// sessions the job needs, so it is the better of the two asks to spend on
    /// this user. It ages past the feedback card on the same rule the contribute
    /// ask uses (see `stewardAskOutranksFeedbackCard()`).
    ///
    /// Requires a target agent, which the session list supplies once the index
    /// loads. No target means no honest ask — there is nothing to name.
    ///
    /// Never fires on a fresh-install launch, and never asks again once the user
    /// has opened the signup form or dismissed it.
    func shouldShowStewardCard() -> Bool {
        guard stewardAskTarget != nil else { return false }
        guard whatsNewMajorMinor == nil else { return false }
        guard !didConsumeTopSlotAskThisLaunch else { return false }
        guard !stewardCardSuppressedThisLaunch else { return false }
        guard !didPresentFreshInstallThisLaunch else { return false }

        switch defaults.onboardingStewardAskState {
        case .signedUp, .dismissedForever:
            return false
        case .notAsked:
            break
        case .askedThisRelease:
            // One round per release. Without a readable version there is no way
            // to tell whether the release moved, so stay quiet; a missing stamp,
            // on the other hand, is a round that could never expire, so treat it
            // as spendable.
            guard let current = currentMajorMinorProvider(),
                  defaults.onboardingStewardAskAskedAtMajorMinor != current else {
                return false
            }
        }

        return stewardAskTriggerMet()
    }

    /// The user opened the signup form — terminal, never ask again. Whether they
    /// actually submit it is not visible from here, and re-asking someone who
    /// went to the form would land on the person most likely to have said yes.
    func recordStewardSignupOpened() {
        defaults.onboardingStewardAskState = .signedUp
        stewardCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
    }

    /// "What's involved" — they went to read the job description and did not sign
    /// up. That ends this release's round rather than the ask: reading it is the
    /// most interested a not-yet-yes gets, and next release is a fair time to ask
    /// again.
    func recordStewardGuideOpened() {
        stewardCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endStewardAskRound()
    }

    /// Records that this launch put the steward card on screen. Being ignored is
    /// an answer; three unanswered launches end the round, and with no "Maybe
    /// later" button on this card that silence is the only soft no available.
    func noteStewardCardShown() {
        guard !didCountStewardImpressionThisLaunch else { return }
        guard !didEndAnAskRoundThisLaunch else { return }
        didCountStewardImpressionThisLaunch = true

        let seen = defaults.onboardingStewardAskImpressions + 1
        defaults.onboardingStewardAskImpressions = seen
        guard seen >= Self.stewardAskMaxImpressionsPerRound else { return }
        endStewardAskRound()
    }

    /// Spends one round: quiet until the next major.minor bump, and permanently
    /// quiet once `stewardAskMaxRounds` of them have gone unanswered.
    private func endStewardAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingStewardAskState {
        case .signedUp, .dismissedForever:
            return
        case .notAsked, .askedThisRelease:
            break
        }
        didEndAnAskRoundThisLaunch = true

        let spent = defaults.onboardingStewardAskRoundsSpent + 1
        defaults.onboardingStewardAskRoundsSpent = spent
        // Every round gets its own budget of launches.
        defaults.onboardingStewardAskImpressions = 0

        guard spent < Self.stewardAskMaxRounds else {
            defaults.onboardingStewardAskState = .dismissedForever
            return
        }
        defaults.onboardingStewardAskState = .askedThisRelease
        defaults.onboardingStewardAskAskedAtMajorMinor = currentMajorMinorProvider()
    }

    /// The card's ✕ — an explicit no about stewardship as a whole, not just this
    /// agent. There is no "Maybe later" to mean the softer thing, and silence
    /// already covers the user who has not decided.
    func dismissStewardAskForever() {
        stewardCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true

        guard defaults.onboardingStewardAskState != .signedUp else { return }
        defaults.onboardingStewardAskState = .dismissedForever
    }

    /// Whether the steward ask has waited long enough to take the slot from the
    /// feedback card.
    ///
    /// Same aging rule as the contribute ask: after two weeks it goes first, and
    /// it spends itself within three rounds.
    ///
    /// This outranks the feedback card only — What's New, the Quota Meter card,
    /// and the star ask all still come first unconditionally.
    func stewardAskOutranksFeedbackCard() -> Bool {
        guard let dueSince = defaults.onboardingStewardAskDueSince else { return false }
        guard now().timeIntervalSince(dueSince) / 86_400 >= Self.stewardAskPriorityAfterDays else { return false }
        return shouldShowStewardCard()
    }

    /// Retention test for the steward ask: earliest of 25 sessions opened or 45
    /// days since first launch. Note this is retention only — whether the user
    /// runs a stewardless agent is `stewardAskTarget`'s job.
    private func stewardAskTriggerMet() -> Bool {
        if defaults.onboardingSessionsOpenedCount >= Self.stewardAskSessionsThreshold { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        let days = now().timeIntervalSince(first) / 86_400
        return days >= Self.stewardAskDaysThreshold
    }

    private func usageTriggerMet() -> Bool {
        if defaults.onboardingSessionsOpenedCount >= 10 { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        let days = now().timeIntervalSince(first) / 86_400
        return days >= 14
    }

    func recordFeedbackSubmitted() {
        defaults.onboardingFeedbackAskState = .completed
        feedbackCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        isFeedbackPromptPresented = false
    }

    /// "Not now": ask once more after the next major.minor bump, then never again.
    func recordFeedbackDeclined() {
        feedbackCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        endFeedbackAskRound()
        isFeedbackPromptPresented = false
    }

    /// Advances at most once in a launch. This keeps an explicit decline after
    /// the third impression from consuming both release rounds at once.
    private func endFeedbackAskRound() {
        guard !didEndAnAskRoundThisLaunch else { return }
        switch defaults.onboardingFeedbackAskState {
        case .notAsked:
            defaults.onboardingFeedbackAskState = .declinedOnce
            defaults.onboardingFeedbackDeclinedAtMajorMinor = currentMajorMinorProvider()
        case .declinedOnce:
            defaults.onboardingFeedbackAskState = .dismissedForever
        case .completed, .dismissedForever:
            return
        }
        didEndAnAskRoundThisLaunch = true
    }
}

extension OnboardingCoordinator {
    nonisolated static func defaultIsFreshInstall() -> Bool {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let dbURL = appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("index.db", isDirectory: false)
        return !fm.fileExists(atPath: dbURL.path)
    }
}
