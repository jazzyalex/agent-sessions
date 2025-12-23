import Foundation

struct OnboardingContent: Equatable {
    struct Screen: Identifiable, Equatable {
        let symbolName: String
        let title: String
        let body: String
        let bullets: [String]

        var id: String { title }

        init(symbolName: String, title: String, body: String, bullets: [String] = []) {
            self.symbolName = symbolName
            self.title = title
            self.body = body
            self.bullets = bullets
        }
    }

    /// major.minor, e.g. "2.9"
    let versionMajorMinor: String
    let screens: [Screen]
}

extension OnboardingContent {
    static func majorMinor(from versionString: String) -> String? {
        guard let semver = SemanticVersion(string: versionString) else { return nil }
        return "\(semver.major).\(semver.minor)"
    }

    static func currentMajorMinor() -> String? {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return majorMinor(from: currentVersion)
    }

    static func forMajorMinor(_ majorMinor: String) -> OnboardingContent? {
        catalog[majorMinor]
    }

    static func fallback(for majorMinor: String) -> OnboardingContent {
        OnboardingContent(
            versionMajorMinor: majorMinor,
            screens: [
                Screen(
                    symbolName: "sparkles",
                    title: "Welcome to Agent Sessions \(majorMinor)",
                    body: "A quick tour is not available for this version.",
                    bullets: [
                        "You can still review the Sparkle release notes after updating.",
                        "Onboarding is always available from the Help menu."
                    ]
                ),
                Screen(
                    symbolName: "checkmark.circle.fill",
                    title: "You’re all set",
                    body: "Continue using Agent Sessions as usual."
                )
            ]
        )
    }

    private static let catalog: [String: OnboardingContent] = [
        "2.9": OnboardingContent(
            versionMajorMinor: "2.9",
            screens: [
                Screen(
                    symbolName: "sparkles",
                    title: "Welcome to Agent Sessions 2.9",
                    body: "A short tour of what’s changed, so you can get productive faster."
                ),
                Screen(
                    symbolName: "person.crop.circle.badge.plus",
                    title: "New agent: Copilot",
                    body: "GitHub Copilot sessions are now indexed alongside your other agents.",
                    bullets: [
                        "Enable or configure Copilot in Settings.",
                        "Copilot sessions appear in the unified sessions list."
                    ]
                ),
                Screen(
                    symbolName: "bookmark.fill",
                    title: "Saved Sessions",
                    body: "Save sessions you care about and browse them in the new Saved Sessions window.",
                    bullets: [
                        "Use the Save button to keep a session from being pruned.",
                        "Open Saved Sessions from the View menu."
                    ]
                ),
                Screen(
                    symbolName: "keyboard",
                    title: "Better keyboard shortcuts",
                    body: "Common actions have improved shortcuts throughout the app.",
                    bullets: [
                        "Search Sessions and Search in Transcript are now in the Search menu.",
                        "Saved Sessions has a dedicated shortcut in the View menu."
                    ]
                ),
                Screen(
                    symbolName: "checkmark.circle.fill",
                    title: "You’re ready",
                    body: "You can reopen this tour anytime from the Help menu."
                )
            ]
        )
    ]
}
