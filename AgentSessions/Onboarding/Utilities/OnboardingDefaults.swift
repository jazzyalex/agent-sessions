import Foundation

extension UserDefaults {
    private enum OnboardingKeys {
        static let lastActionMajorMinor = "OnboardingLastActionMajorMinor"
        static let fullTourCompleted = "OnboardingFullTourCompleted"
        static let lastSeenAppMajorMinor = "OnboardingLastSeenAppMajorMinor"
        static let whatsNewDismissedMajorMinor = "OnboardingWhatsNewDismissedMajorMinor"
        static let firstLaunchDate = "OnboardingFirstLaunchDate"
        static let sessionsOpenedCount = "OnboardingSessionsOpenedCount"
        static let feedbackAskState = "OnboardingFeedbackAskState"
        static let feedbackDeclinedAtMajorMinor = "OnboardingFeedbackDeclinedAtMajorMinor"
        static let quotaMeterAskState = "OnboardingQuotaMeterAskState"
        static let quotaMeterDeclinedAtMajorMinor = "OnboardingQuotaMeterDeclinedAtMajorMinor"
        static let cockpitEverOpened = "OnboardingCockpitEverOpened"
        static let starAskState = "OnboardingStarAskState"
        static let starAskSnoozedUntil = "OnboardingStarAskSnoozedUntil"
        static let starAskImpressions = "OnboardingStarAskImpressions"
        static let starAskDueSince = "OnboardingStarAskDueSince"
        static let contributeAskState = "OnboardingContributeAskState"
        static let contributeAskSnoozedUntil = "OnboardingContributeAskSnoozedUntil"
        static let contributeAskImpressions = "OnboardingContributeAskImpressions"
    }

    /// Lifecycle of the one-time invitation to contribute a new agent source.
    ///
    /// Deliberately the same shape as `StarAskState` — a clock-based snooze
    /// rather than a version-gated retry — but strictly one round: this is an
    /// invitation, not a campaign, so the second round-out is permanent.
    enum ContributeAskState: String {
        /// Not yet shown — eligible once the retention trigger fires.
        case notAsked
        /// "Maybe later" once — eligible again after `contributeAskSnoozedUntil`.
        case snoozed
        /// Dismissed outright, or a second "Maybe later" — never ask again.
        case dismissedForever
        /// The user opened one of the contribution pages — never ask again.
        case opened
    }

    /// Lifecycle of the one-time GitHub star ask.
    ///
    /// Unlike the feedback and Quota Meter cards, the retry is on a clock rather
    /// than a version bump: releases ship every few days here, so a bump-gated
    /// retry would land almost immediately and read as nagging.
    enum StarAskState: String {
        /// Not yet shown — eligible once the retention trigger fires.
        case notAsked
        /// "Maybe later" once — eligible again after `starAskSnoozedUntil`.
        case snoozed
        /// Dismissed outright, or a second "Maybe later" — never ask again.
        case dismissedForever
        /// The user opened the repository — never ask again.
        case starred
    }

    /// Lifecycle of the Quota Meter activation card. Mirrors `FeedbackAskState`:
    /// one soft strike, a second chance after a version bump, then silence.
    enum QuotaMeterAskState: String {
        /// Not yet shown — eligible once the audience test passes.
        case notAsked
        /// Dismissed once — eligible again after the next major.minor bump.
        case dismissedOnce
        /// Dismissed a second time (after a bump) — never ask again.
        case dismissedForever
        /// The user opened the Quota Meter — never ask again.
        case activated
    }

    /// Lifecycle state of the one-time native feedback ask.
    enum FeedbackAskState: String {
        /// Not yet shown — eligible once the usage trigger fires.
        case notAsked
        /// User picked "Not now" once — eligible again after the next major.minor bump.
        case declinedOnce
        /// User picked "Not now" a second time (after a bump) — never ask again.
        case dismissedForever
        /// Feedback was sent — never ask again.
        case completed
    }

    /// The last major.minor version for which the onboarding flow was either completed or skipped.
    ///
    /// This intentionally ignores patch releases so `2.9.1` does not re-trigger onboarding after `2.9`.
    var onboardingLastActionMajorMinor: String? {
        get { string(forKey: OnboardingKeys.lastActionMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.lastActionMajorMinor) }
    }

    /// True once the user completes or skips the full onboarding tour (fresh install experience).
    var onboardingFullTourCompleted: Bool {
        get { bool(forKey: OnboardingKeys.fullTourCompleted) }
        set { set(newValue, forKey: OnboardingKeys.fullTourCompleted) }
    }

    /// The app major.minor seen on the previous launch.
    ///
    /// This is used to gate update onboarding for specific upgrade paths.
    var onboardingLastSeenAppMajorMinor: String? {
        get { string(forKey: OnboardingKeys.lastSeenAppMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.lastSeenAppMajorMinor) }
    }

    /// The major.minor version whose What's New card the user explicitly dismissed.
    /// Once set to a version, that version's card never re-appears.
    var onboardingWhatsNewDismissedMajorMinor: String? {
        get { string(forKey: OnboardingKeys.whatsNewDismissedMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.whatsNewDismissedMajorMinor) }
    }

    /// The date of the first launch (set once). Drives the 14-day feedback trigger.
    var onboardingFirstLaunchDate: Date? {
        get { object(forKey: OnboardingKeys.firstLaunchDate) as? Date }
        set { set(newValue, forKey: OnboardingKeys.firstLaunchDate) }
    }

    /// Number of sessions the user has opened. Drives the 10-session feedback trigger.
    var onboardingSessionsOpenedCount: Int {
        get { integer(forKey: OnboardingKeys.sessionsOpenedCount) }
        set { set(newValue, forKey: OnboardingKeys.sessionsOpenedCount) }
    }

    /// Lifecycle state of the one-time native feedback ask.
    var onboardingFeedbackAskState: FeedbackAskState {
        get { FeedbackAskState(rawValue: string(forKey: OnboardingKeys.feedbackAskState) ?? "") ?? .notAsked }
        set { set(newValue.rawValue, forKey: OnboardingKeys.feedbackAskState) }
    }

    /// The major.minor version at which the user last picked "Not now" for feedback.
    /// Used to re-ask exactly once after the next major.minor bump.
    var onboardingFeedbackDeclinedAtMajorMinor: String? {
        get { string(forKey: OnboardingKeys.feedbackDeclinedAtMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.feedbackDeclinedAtMajorMinor) }
    }

    /// Lifecycle of the Quota Meter activation card.
    var onboardingQuotaMeterAskState: QuotaMeterAskState {
        get { QuotaMeterAskState(rawValue: string(forKey: OnboardingKeys.quotaMeterAskState) ?? "") ?? .notAsked }
        set { set(newValue.rawValue, forKey: OnboardingKeys.quotaMeterAskState) }
    }

    /// The major.minor at which the user last dismissed the Quota Meter card.
    var onboardingQuotaMeterDeclinedAtMajorMinor: String? {
        get { string(forKey: OnboardingKeys.quotaMeterDeclinedAtMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.quotaMeterDeclinedAtMajorMinor) }
    }

    /// True once the cockpit window has ever been opened. Distinguishes the
    /// "usage tracking is on but they've never actually seen it" audience from
    /// people already using the feature.
    var onboardingCockpitEverOpened: Bool {
        get { bool(forKey: OnboardingKeys.cockpitEverOpened) }
        set { set(newValue, forKey: OnboardingKeys.cockpitEverOpened) }
    }

    /// Lifecycle state of the one-time GitHub star ask.
    var onboardingStarAskState: StarAskState {
        get { StarAskState(rawValue: string(forKey: OnboardingKeys.starAskState) ?? "") ?? .notAsked }
        set { set(newValue.rawValue, forKey: OnboardingKeys.starAskState) }
    }

    /// When a "Maybe later" on the star ask expires. Nil until the first snooze.
    var onboardingStarAskSnoozedUntil: Date? {
        get { object(forKey: OnboardingKeys.starAskSnoozedUntil) as? Date }
        set { set(newValue, forKey: OnboardingKeys.starAskSnoozedUntil) }
    }

    /// Launches that have shown the star card in the current round without the
    /// user answering. Reset when a round ends; caps how long silence can run.
    var onboardingStarAskImpressions: Int {
        get { integer(forKey: OnboardingKeys.starAskImpressions) }
        set { set(newValue, forKey: OnboardingKeys.starAskImpressions) }
    }

    /// When the star ask first became due. Drives the aging rule that lets it
    /// overtake a Quota Meter card the user is neither acting on nor dismissing.
    var onboardingStarAskDueSince: Date? {
        get { object(forKey: OnboardingKeys.starAskDueSince) as? Date }
        set { set(newValue, forKey: OnboardingKeys.starAskDueSince) }
    }

    /// Lifecycle state of the one-time "contribute an agent source" invitation.
    var onboardingContributeAskState: ContributeAskState {
        get { ContributeAskState(rawValue: string(forKey: OnboardingKeys.contributeAskState) ?? "") ?? .notAsked }
        set { set(newValue.rawValue, forKey: OnboardingKeys.contributeAskState) }
    }

    /// When a "Maybe later" on the contribute ask expires. Nil until the first snooze.
    var onboardingContributeAskSnoozedUntil: Date? {
        get { object(forKey: OnboardingKeys.contributeAskSnoozedUntil) as? Date }
        set { set(newValue, forKey: OnboardingKeys.contributeAskSnoozedUntil) }
    }

    /// Launches that have shown the contribute card in the current round without
    /// the user answering. Reset when the first round ends.
    var onboardingContributeAskImpressions: Int {
        get { integer(forKey: OnboardingKeys.contributeAskImpressions) }
        set { set(newValue, forKey: OnboardingKeys.contributeAskImpressions) }
    }
}
