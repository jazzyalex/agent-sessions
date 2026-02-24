import Foundation

extension UserDefaults {
    private enum OnboardingKeys {
        static let lastActionMajorMinor = "OnboardingLastActionMajorMinor"
        static let fullTourCompleted = "OnboardingFullTourCompleted"
        static let lastSeenAppMajorMinor = "OnboardingLastSeenAppMajorMinor"
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
}
