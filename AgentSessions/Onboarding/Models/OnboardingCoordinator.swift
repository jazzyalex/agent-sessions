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
        whatsNewMajorMinor == nil
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
            break
        }
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

    /// Retention test for the star ask: earliest of 25 sessions opened or 30 days
    /// since first launch. Same shape as `usageTriggerMet()`, higher bars.
    private func starAskTriggerMet() -> Bool {
        if defaults.onboardingSessionsOpenedCount >= Self.starAskSessionsThreshold { return true }
        guard let first = defaults.onboardingFirstLaunchDate else { return false }
        let days = now().timeIntervalSince(first) / 86_400
        return days >= Self.starAskDaysThreshold
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
