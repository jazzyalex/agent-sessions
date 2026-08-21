import Foundation

/// What the coordinator asks the modal onboarding window to present.
/// Updates never present a modal — they publish `whatsNewMajorMinor` instead.
enum OnboardingPresentation: Equatable {
    /// Fresh-install single setup screen (agents + Quota Meter + Start Exploring).
    case firstRunSetup
    /// Legacy multi-slide Power Tips tour (Help → Power Tips). Untouched by the rework.
    case powerTips(OnboardingContent)
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// The public repository the star ask points at. Held here so the card, the
    /// menu item, and the tests can never drift onto different URLs.
    static let githubRepositoryURL = URL(string: "https://github.com/jazzyalex/agent-sessions")!

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
    static let contributeAskSessionsThreshold = 25

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

    /// Set when the user dismisses the feedback card with its ✕. In-memory only —
    /// hides the card for the rest of this launch without advancing the permanent
    /// decline lifecycle (only the prompt's explicit "Not now" does that), so an
    /// accidental ✕ never costs a strike.
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
    private let now: () -> Date
    private var hasChecked: Bool = false
    /// One impression per launch, not per render: `.onAppear` fires again every
    /// time the list rebuilds the card.
    private var didCountStarImpressionThisLaunch: Bool = false
    /// Same one-impression-per-launch rule for the contribute card.
    private var didCountContributeImpressionThisLaunch: Bool = false
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
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.currentMajorMinorProvider = currentMajorMinorProvider
        self.isFreshInstallProvider = isFreshInstallProvider
        self.whatsNewAvailableProvider = whatsNewAvailableProvider
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
        return whatsNewAvailableProvider(current)
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

    /// Increments the sessions-opened counter that drives the 10-session trigger.
    func noteSessionOpened() {
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
    /// What's New always wins the slot, and a ✕ dismissal hides it for this launch.
    func shouldShowFeedbackCard() -> Bool {
        if stewardAskOutranksFeedbackCard() { return false }
        if contributeAskOutranksFeedbackCard() { return false }
        return whatsNewMajorMinor == nil
            && !didConsumeTopSlotAskThisLaunch
            && !feedbackCardSuppressedThisLaunch
            && isFeedbackAskDue()
    }

    /// Soft-dismiss the feedback card (its ✕). Hides it for this launch only; the
    /// permanent decline lifecycle is untouched, so it can return next launch.
    func suppressFeedbackCardThisLaunch() {
        feedbackCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
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

    /// Soft-dismiss the card (its ✕). Costs a strike, since unlike the feedback
    /// card there is no second surface where a real decline is recorded.
    func suppressQuotaMeterCardThisLaunch() {
        quotaMeterCardSuppressedThisLaunch = true
        didConsumeTopSlotAskThisLaunch = true
        recordQuotaMeterDeclined()
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
        switch defaults.onboardingQuotaMeterAskState {
        case .notAsked:
            defaults.onboardingQuotaMeterAskState = .dismissedOnce
            defaults.onboardingQuotaMeterDeclinedAtMajorMinor = currentMajorMinorProvider()
        case .dismissedOnce:
            defaults.onboardingQuotaMeterAskState = .dismissedForever
        case .activated, .dismissedForever:
            break
        }
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
    /// slot at most twice. The feedback card's ✕ is soft and returns every
    /// launch, so putting it first would starve the star ask indefinitely. Its
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
    /// Fixed priority alone is not enough. The Quota Meter card only leaves the
    /// slot when the user activates it or dismisses it — someone who does
    /// neither, and simply ignores it, holds the slot on every launch
    /// indefinitely. The star ask sits below it and would never be seen. After
    /// two weeks of waiting it goes first; it then spends itself within two
    /// rounds and hands the slot straight back, so this cannot deadlock the
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
    /// past the Quota Meter card. The feedback card's ✕ is soft: it returns every
    /// launch, and a user who neither submits feedback nor declines it in the
    /// prompt holds the slot indefinitely, so the contribute ask below it would
    /// never be seen. After two weeks of waiting it goes first; it then spends
    /// itself within two rounds and hands the slot straight back, so this cannot
    /// deadlock the other direction.
    ///
    /// This outranks the feedback card only — never What's New, the Quota Meter
    /// card, or the star ask, all of which still come first unconditionally.
    func contributeAskOutranksFeedbackCard() -> Bool {
        guard let dueSince = defaults.onboardingContributeAskDueSince else { return false }
        guard now().timeIntervalSince(dueSince) / 86_400 >= Self.contributeAskPriorityAfterDays else { return false }
        return shouldShowContributeCard()
    }

    /// Retention test for the contribute ask: earliest of 25 sessions opened or
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
    /// Same problem the contribute ask has, and the same fix: the feedback card's
    /// ✕ is soft and returns every launch, so a user who neither submits feedback
    /// nor declines it in the prompt would hold this off forever. After two weeks
    /// it goes first, and it spends itself within three rounds, so this cannot
    /// deadlock the other direction.
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
        isFeedbackPromptPresented = false
    }

    /// "Not now": ask once more after the next major.minor bump, then never again.
    func recordFeedbackDeclined() {
        switch defaults.onboardingFeedbackAskState {
        case .notAsked:
            defaults.onboardingFeedbackAskState = .declinedOnce
            defaults.onboardingFeedbackDeclinedAtMajorMinor = currentMajorMinorProvider()
        case .declinedOnce:
            defaults.onboardingFeedbackAskState = .dismissedForever
        case .completed, .dismissedForever:
            break
        }
        isFeedbackPromptPresented = false
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
