import Foundation

struct OnboardingContent: Equatable {
    enum Kind: Equatable {
        case fullTour
        case updateTour
    }

    struct Screen: Identifiable, Equatable {
        struct AgentShowcaseItem: Identifiable, Equatable {
            let symbolName: String
            let title: String

            var id: String { title }
        }

        struct Shortcut: Identifiable, Equatable {
            let keys: String
            let label: String

            var id: String { "\(keys)-\(label)" }
        }

        let symbolName: String
        let title: String
        let body: String
        let agentShowcase: [AgentShowcaseItem]
        let bullets: [String]
        let shortcuts: [Shortcut]

        var id: String { title }

        init(symbolName: String, title: String, body: String, agentShowcase: [AgentShowcaseItem] = [], bullets: [String] = [], shortcuts: [Shortcut] = []) {
            self.symbolName = symbolName
            self.title = title
            self.body = body
            self.agentShowcase = agentShowcase
            self.bullets = bullets
            self.shortcuts = shortcuts
        }
    }

    /// major.minor, e.g. "2.9"
    let versionMajorMinor: String
    let kind: Kind
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

    static func updateTour(for majorMinor: String) -> OnboardingContent? {
        guard var content = updateCatalog[majorMinor] else { return nil }
        let extra = newProviderScreens(for: majorMinor)
        if !extra.isEmpty {
            content = OnboardingContent(
                versionMajorMinor: content.versionMajorMinor,
                kind: content.kind,
                screens: content.screens + extra
            )
        }
        return content
    }

    static func fullTour(for majorMinor: String) -> OnboardingContent {
        OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .fullTour,
            screens: fullTourScreens()
        )
    }

    static func fallbackUpdateTour(for majorMinor: String) -> OnboardingContent {
        let base = release3UpdateTourScreens()
        let extra = newProviderScreens(for: majorMinor)
        return OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .updateTour,
            screens: base + extra
        )
    }

    /// Returns a "New Agent Support" screen for any providers introduced in the
    /// given version.  Returns an empty array if no providers match.
    static func newProviderScreens(for majorMinor: String) -> [Screen] {
        let newSources = SessionSource.allCases.filter { $0.versionIntroduced == majorMinor }
        guard !newSources.isEmpty else { return [] }
        let showcaseItems = newSources.map {
            Screen.AgentShowcaseItem(symbolName: $0.iconName, title: $0.displayName)
        }
        let bullets = newSources.map { $0.featureDescription }
        return [
            Screen(
                symbolName: "party.popper",
                title: "New Agent Support",
                body: "This update adds support for new AI coding assistants.",
                agentShowcase: showcaseItems,
                bullets: bullets
            )
        ]
    }

    private static let updateCatalog: [String: OnboardingContent] = [
        "2.9": OnboardingContent(
            versionMajorMinor: "2.9",
            kind: .updateTour,
            screens: legacyUpdateTourScreens()
        ),
        "3.0": OnboardingContent(
            versionMajorMinor: "3.0",
            kind: .updateTour,
            screens: release3UpdateTourScreens()
        )
    ]

    private static func fullTourScreens() -> [Screen] {
        [
            Screen(
                symbolName: "checkmark.circle",
                title: "Sessions Found",
                body: "Your CLI agent history is ready to browse."
            ),
            Screen(
                symbolName: "display",
                title: "Connect Your Agents",
                body: "Enable the agents you use. Disabled agents will not appear in filters or analytics."
            ),
            Screen(
                symbolName: "sparkles.tv",
                title: "Agent Cockpit (Beta)",
                body: "Open a live HUD for active sessions in iTerm2. Beta scope currently covers Codex CLI, Claude Code, and OpenCode."
            ),
            Screen(
                symbolName: "chart.bar.xaxis",
                title: "Analytics & Usage",
                body: "See your coding patterns and track usage limits."
            ),
            Screen(
                symbolName: "heart.text.square",
                title: "Feedback & Community Support",
                body: "Share feedback in the Google Form, star the GitHub repository, and support ongoing development via GitHub Sponsors or Buy Me a Coffee."
            )
        ]
    }

    private static func legacyUpdateTourScreens() -> [Screen] {
        [
            Screen(
                symbolName: "checkmark.circle",
                title: "Sessions Found",
                body: "Your CLI agent history is ready to browse."
            ),
            Screen(
                symbolName: "display",
                title: "Connect Your Agents",
                body: "Enable the agents you use. Disabled agents will not appear in filters or analytics."
            ),
            Screen(
                symbolName: "list.bullet",
                title: "Work With Sessions",
                body: "Quick actions to navigate and manage your work."
            ),
            Screen(
                symbolName: "chart.bar.xaxis",
                title: "Analytics & Usage",
                body: "See your coding patterns and track usage limits."
            )
        ]
    }

    private static func release3UpdateTourScreens() -> [Screen] {
        [
            Screen(
                symbolName: "sparkles.tv",
                title: "Agent Cockpit (Beta)",
                body: "Live session HUD for iTerm2, currently scoped to Codex CLI, Claude Code, and OpenCode."
            ),
            Screen(
                symbolName: "heart.text.square",
                title: "Feedback & Community Support",
                body: "Share feedback in the Google Form, star the GitHub repository, and support ongoing development via GitHub Sponsors or Buy Me a Coffee."
            )
        ]
    }
}
