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

    private let defaults: UserDefaults
    private let currentMajorMinorProvider: () -> String?
    private let isFreshInstallProvider: () -> Bool
    private let whatsNewAvailableProvider: (String) -> Bool
    private let now: () -> Date
    private var hasChecked: Bool = false
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
        whatsNewMajorMinor == nil && !feedbackCardSuppressedThisLaunch && isFeedbackAskDue()
    }

    /// Soft-dismiss the feedback card (its ✕). Hides it for this launch only; the
    /// permanent decline lifecycle is untouched, so it can return next launch.
    func suppressFeedbackCardThisLaunch() {
        feedbackCardSuppressedThisLaunch = true
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
