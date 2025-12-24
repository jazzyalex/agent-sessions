import Foundation

struct OnboardingContent: Equatable {
    enum Kind: Equatable {
        case fullTour
        case updateTour
    }

    struct Screen: Identifiable, Equatable {
        struct Shortcut: Identifiable, Equatable {
            let keys: String
            let label: String

            var id: String { "\(keys)-\(label)" }
        }

        let symbolName: String
        let title: String
        let body: String
        let bullets: [String]
        let shortcuts: [Shortcut]

        var id: String { title }

        init(symbolName: String, title: String, body: String, bullets: [String] = [], shortcuts: [Shortcut] = []) {
            self.symbolName = symbolName
            self.title = title
            self.body = body
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
        updateCatalog[majorMinor]
    }

    static func fullTour(for majorMinor: String) -> OnboardingContent {
        OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .fullTour,
            screens: [
                Screen(
                    symbolName: "sparkles",
                    title: "Welcome to Agent Sessions",
                    body: "Browse, search, and keep important CLI agent sessions in one place.",
                    bullets: [
                        "Unified sessions list across agents.",
                        "Search and filters to find past work fast.",
                        "Saved Sessions keep key sessions locally so they don’t disappear when history is pruned.",
                        "You can reopen this tour anytime from Help."
                    ]
                ),
                Screen(
                    symbolName: "tray.full",
                    title: "Connect your agents",
                    body: "Indexing decides what shows up and what background work runs.",
                    bullets: [
                        "Enable or disable agents in Settings to control what appears across the app.",
                        "Configure where each agent’s sessions are scanned from.",
                        "If something is missing, check agent enablement and scan paths first, then Refresh."
                    ],
                    shortcuts: [
                        .init(keys: "⌘,", label: "Settings…"),
                        .init(keys: "⌘R", label: "Refresh")
                    ]
                ),
                Screen(
                    symbolName: "magnifyingglass",
                    title: "Find sessions fast",
                    body: "The sessions list is the hub. Use search, filters, and Saved Only to stay focused.",
                    bullets: [
                        "Search menu includes Search Sessions and Search in Transcript.",
                        "Filter by agent and project to reduce noise.",
                        "Use Saved Only when you want your curated set.",
                        "Open the Saved Sessions window to manage saved sessions."
                    ],
                    shortcuts: [
                        .init(keys: "⌥⌘F", label: "Search Sessions…"),
                        .init(keys: "⌘F", label: "Search in Transcript…"),
                        .init(keys: "⇧⌥⌘P", label: "Saved Sessions…")
                    ]
                ),
                Screen(
                    symbolName: "rectangle.split.3x1",
                    title: "Choose your transcript view",
                    body: "Switch views depending on whether you’re reading, scanning, or debugging.",
                    bullets: [
                        "Plain is best for careful reading and selection.",
                        "Color is CLI-like hierarchy (agent message, user prompt, tool use, error) for quick scanning.",
                        "JSON helps when a transcript looks incomplete or strange."
                    ],
                    shortcuts: [
                        .init(keys: "⌘⇧T", label: "Toggle Plain / Color")
                    ]
                ),
                Screen(
                    symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                    title: "Navigate long sessions",
                    body: "Jump by structure instead of scrolling.",
                    bullets: [
                        "In Color view, use the role chips (User, Agent, Tools, Errors) to filter and scan.",
                        "Jump to the first prompt when a session includes an injected preamble.",
                        "Use the arrow shortcuts to jump between prompts, tools, and errors."
                    ],
                    shortcuts: [
                        .init(keys: "⌥⌘↓ / ⌥⌘↑", label: "Next / Previous prompt"),
                        .init(keys: "⌥⌘→ / ⌥⌘←", label: "Next / Previous tool call or output"),
                        .init(keys: "⌥⌘⇧↓ / ⌥⌘⇧↑", label: "Next / Previous error")
                    ]
                ),
                Screen(
                    symbolName: "terminal",
                    title: "Resume and return to the repo",
                    body: "Go from reading history to continuing work in the right folder.",
                    bullets: [
                        "Resume works for Codex and Claude sessions when enough data is available.",
                        "Reveal the working directory to jump back into the project quickly."
                    ],
                    shortcuts: [
                        .init(keys: "⌃⌘R", label: "Resume"),
                        .init(keys: "⌘⇧O", label: "Open Working Directory")
                    ]
                ),
                Screen(
                    symbolName: "gauge.with.dots.needle.67percent",
                    title: "Usage tracking and analytics",
                    body: "Choose how visible and how automatic you want usage and trends to be.",
                    bullets: [
                        "Enable the usage strip to see limits in the main window.",
                        "Enable menu bar usage if you want usage without opening the app.",
                        "Usage can refresh automatically on a cadence or manually on demand.",
                        "Optional probes can query the CLI for current usage. Probing may launch the CLI and may count toward usage depending on the provider.",
                        "Analytics shows trends and breakdowns across agents over time."
                    ],
                    shortcuts: [
                        .init(keys: "⌘,", label: "Settings…")
                    ]
                )
            ]
        )
    }

    static func fallbackUpdateTour(for majorMinor: String) -> OnboardingContent {
        OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .updateTour,
            screens: [
                Screen(
                    symbolName: "sparkles",
                    title: "Welcome to Agent Sessions \(majorMinor)",
                    body: "A quick update tour is not available for this version.",
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

    private static let updateCatalog: [String: OnboardingContent] = [
        "2.9": OnboardingContent(
            versionMajorMinor: "2.9",
            kind: .updateTour,
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
                    ],
                    shortcuts: [
                        .init(keys: "⇧⌥⌘P", label: "Saved Sessions…")
                    ]
                ),
                Screen(
                    symbolName: "keyboard",
                    title: "Better keyboard shortcuts",
                    body: "Common actions have improved shortcuts throughout the app. You can reopen this tour anytime from the Help menu.",
                    bullets: [
                        "Search Sessions and Search in Transcript are now in the Search menu.",
                        "Saved Sessions has a dedicated shortcut in the View menu."
                    ],
                    shortcuts: [
                        .init(keys: "⌥⌘F", label: "Search Sessions…"),
                        .init(keys: "⌘F", label: "Search in Transcript…"),
                        .init(keys: "⌘⇧T", label: "Toggle Plain / Color"),
                        .init(keys: "⌥⌘↓ / ⌥⌘↑", label: "Next / Previous prompt"),
                        .init(keys: "⌥⌘→ / ⌥⌘←", label: "Next / Previous tool call or output"),
                        .init(keys: "⌥⌘⇧↓ / ⌥⌘⇧↑", label: "Next / Previous error")
                    ]
                )
            ]
        )
    ]
}
