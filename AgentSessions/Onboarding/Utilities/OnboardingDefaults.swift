import Foundation

extension UserDefaults {
    private enum OnboardingKeys {
        static let lastActionMajorMinor = "OnboardingLastActionMajorMinor"
    }

    /// The last major.minor version for which the onboarding flow was either completed or skipped.
    ///
    /// This intentionally ignores patch releases so `2.9.1` does not re-trigger onboarding after `2.9`.
    var onboardingLastActionMajorMinor: String? {
        get { string(forKey: OnboardingKeys.lastActionMajorMinor) }
        set { set(newValue, forKey: OnboardingKeys.lastActionMajorMinor) }
    }
}

