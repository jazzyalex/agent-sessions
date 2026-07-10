import Foundation

struct OnboardingContent: Equatable {
    enum Kind: Equatable {
        case fullTour
        case updateTour
        case powerTips
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

    static func powerTipsTour(for majorMinor: String) -> OnboardingContent {
        OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .powerTips,
            screens: powerTipsTourScreens()
        )
    }

    private static func powerTipsTourScreens() -> [Screen] {
        [
            Screen(
                symbolName: "lightbulb.max",
                title: "Power Tips",
                body: "A couple of useful settings are easy to miss.",
                bullets: [
                    "Hide the Dock icon: Turn it on from Settings > Advanced. Agent Sessions keeps the menu bar item enabled so the app remains reachable.",
                    "Use Agent Cockpit: Open View > Agent Cockpit to monitor active iTerm2 sessions from Codex CLI, Claude Code, and OpenCode."
                ]
            ),
            Screen(
                symbolName: "sparkles.tv",
                title: "Cockpit Workflow",
                body: "Keep live agent work visible without switching terminal tabs.",
                bullets: [
                    "Pin Cockpit: Keep Agent Cockpit in a screen corner so active and waiting sessions stay visible.",
                    "Focus a live agent: Use Focus in iTerm2 from Cockpit when you need to jump back to a running agent."
                ]
            ),
            Screen(
                symbolName: "folder.badge.gearshape",
                title: "Live Session Context",
                body: "Cockpit rows expose useful session context.",
                bullets: [
                    "Reveal the log: Open the session log in Finder from a live Cockpit row.",
                    "Open the working directory: Jump to the repo folder for the active agent session."
                ]
            ),
            Screen(
                symbolName: "magnifyingglass",
                title: "Search Faster",
                body: "Use the two search surfaces for different jobs.",
                bullets: [
                    "Search across sessions: Use Unified Search with Option-Command-F.",
                    "Search inside one session: Use Command-F while reading a transcript."
                ]
            ),
            Screen(
                symbolName: "arrowshape.turn.up.right",
                title: "Resume Work",
                body: "Return to past agent sessions from the session list.",
                bullets: [
                    "Resume past work: Right-click supported sessions to continue where you left off.",
                    "Copy exact commands: Copy Resume Command gives you the CLI command without launching it."
                ]
            ),
            Screen(
                symbolName: "photo.on.rectangle.angled",
                title: "Images",
                body: "Image-heavy sessions have dedicated navigation.",
                bullets: [
                    "Open Image Browser: Review images embedded in sessions.",
                    "Jump image prompts: Use the Images control in a transcript to move between image prompts."
                ]
            ),
            Screen(
                symbolName: "doc.text.magnifyingglass",
                title: "Transcript Tools",
                body: "Switch views depending on what you need.",
                bullets: [
                    "Change transcript view: Switch between Session, Text, and JSON views for readability or raw structure.",
                    "Export as Markdown: Save a session transcript when you need to keep or share it."
                ]
            ),
            Screen(
                symbolName: "textformat.size",
                title: "Reading Controls",
                body: "Long transcripts are easier with keyboard controls.",
                bullets: [
                    "Copy the transcript: Use the transcript toolbar to copy the full session.",
                    "Adjust text size: Use Command-Plus and Command-Minus while reading."
                ]
            ),
            Screen(
                symbolName: "bookmark",
                title: "Saved Sessions",
                body: "Keep important sessions easy to find.",
                bullets: [
                    "Star important sessions: Reopen them later from Saved Sessions.",
                    "Filter to favorites: Use favorites-only mode when you want a short working set."
                ]
            ),
            Screen(
                symbolName: "line.3.horizontal.decrease.circle",
                title: "Reduce Noise",
                body: "Filters keep the session list focused.",
                bullets: [
                    "Hide noisy sessions: Settings can hide zero-message, low-message, housekeeping, or probe sessions.",
                    "Show command sessions: Use the commands-only filter to focus on sessions that ran tools or shell commands."
                ]
            ),
            Screen(
                symbolName: "chart.bar.xaxis",
                title: "Usage Limits",
                body: "Usage surfaces can stay visible while agents run.",
                bullets: [
                    "Enable usage strips: Track Codex and Claude rate-limit state in the app.",
                    "Use menu bar meters: Keep usage state visible without opening the main window."
                ]
            ),
            Screen(
                symbolName: "slider.horizontal.3",
                title: "Agent Sources",
                body: "Only enable the providers you use.",
                bullets: [
                    "Choose active agents: Disable unused providers from Settings so they stay out of filters.",
                    "Browse one unified list: Agent Sessions can combine multiple local agent histories."
                ]
            ),
            Screen(
                symbolName: "bubble.left.and.bubble.right",
                title: "Side Chats",
                body: "Codex Desktop side chats are recoverable.",
                bullets: [
                    "Filter to side chats: Use #side, or #side phrase to search within them.",
                    "Find the parent thread: Copy Session ID on a side chat copies its parent thread ID."
                ]
            ),
            Screen(
                symbolName: "archivebox",
                title: "Archived Sessions",
                body: "Old Desktop sessions stay reachable.",
                bullets: [
                    "Search Codex archives: Click the archive icon on the Codex filter (Command-1) to narrow to archived Desktop sessions.",
                    "Restore Claude archives: Use the archive icon on the Claude filter (Command-2), then restore in place from the transcript."
                ]
            ),
            Screen(
                symbolName: "point.3.connected.trianglepath.dotted",
                title: "Workflow Subagents",
                body: "Claude Code workflows stay readable.",
                bullets: [
                    "Spot fan-out: Workflow subagents nest under the session that launched them with a workflow badge.",
                    "Resume the parent: Resuming a workflow child resolves to its parent session."
                ]
            ),
            Screen(
                symbolName: "cursorarrow.click.2",
                title: "Quick Navigation",
                body: "Small shortcuts help when scanning lots of history.",
                bullets: [
                    "Move through matches: Use Command-G and Shift-Command-G after searching a transcript.",
                    "Filter by project: Double-click project names in the session list."
                ]
            )
        ]
    }
}
