import Foundation

struct OnboardingContent: Equatable {
    enum Kind: Equatable {
        case fullTour
        case updateTour
        case powerTips
    }

    struct Screen: Identifiable, Equatable {
        struct AgentShowcaseItem: Identifiable, Equatable {
            let id: String
            let symbolName: String
            let title: LocalizedStringResource
        }

        struct Tip: Identifiable, Equatable {
            let id: String
            let title: LocalizedStringResource
            let description: LocalizedStringResource
        }

        struct Shortcut: Identifiable, Equatable {
            let id: String
            let keys: String
            let label: LocalizedStringResource
        }

        let id: String
        let symbolName: String
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let agentShowcase: [AgentShowcaseItem]
        let bullets: [Tip]
        let shortcuts: [Shortcut]

        init(
            id: String,
            symbolName: String,
            title: LocalizedStringResource,
            body: LocalizedStringResource,
            agentShowcase: [AgentShowcaseItem] = [],
            bullets: [Tip] = [],
            shortcuts: [Shortcut] = []
        ) {
            self.id = id
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
                id: "power-tips",
                symbolName: "lightbulb.max",
                title: "Power Tips",
                body: "A couple of useful settings are easy to miss.",
                bullets: [
                    Screen.Tip(
                        id: "hide-dock-icon",
                        title: "Hide the Dock icon",
                        description: "Turn it on from Settings > Advanced. Agent Sessions keeps the menu bar item enabled so the app remains reachable."
                    ),
                    Screen.Tip(
                        id: "use-agent-cockpit",
                        title: "Use Agent Cockpit",
                        description: "Open View > Agent Cockpit to monitor active iTerm2 sessions from Codex CLI, Claude Code, and OpenCode."
                    )
                ]
            ),
            Screen(
                id: "cockpit-workflow",
                symbolName: "sparkles.tv",
                title: "Cockpit Workflow",
                body: "Keep live agent work visible without switching terminal tabs.",
                bullets: [
                    Screen.Tip(
                        id: "pin-cockpit",
                        title: "Pin Cockpit",
                        description: "Keep Agent Cockpit in a screen corner so active and waiting sessions stay visible."
                    ),
                    Screen.Tip(
                        id: "focus-live-agent",
                        title: "Focus a live agent",
                        description: "Use Focus in iTerm2 from Cockpit when you need to jump back to a running agent."
                    )
                ]
            ),
            Screen(
                id: "live-session-context",
                symbolName: "folder.badge.gearshape",
                title: "Live Session Context",
                body: "Cockpit rows expose useful session context.",
                bullets: [
                    Screen.Tip(
                        id: "reveal-the-log",
                        title: "Reveal the log",
                        description: "Open the session log in Finder from a live Cockpit row."
                    ),
                    Screen.Tip(
                        id: "open-working-directory",
                        title: "Open the working directory",
                        description: "Jump to the repo folder for the active agent session."
                    )
                ]
            ),
            Screen(
                id: "search-faster",
                symbolName: "magnifyingglass",
                title: "Search Faster",
                body: "Use the two search surfaces for different jobs.",
                bullets: [
                    Screen.Tip(
                        id: "search-across-sessions",
                        title: "Search across sessions",
                        description: "Use Unified Search with Option-Command-F."
                    ),
                    Screen.Tip(
                        id: "search-inside-session",
                        title: "Search inside one session",
                        description: "Use Command-F while reading a transcript."
                    )
                ]
            ),
            Screen(
                id: "resume-work",
                symbolName: "arrowshape.turn.up.right",
                title: "Resume Work",
                body: "Return to past agent sessions from the session list.",
                bullets: [
                    Screen.Tip(
                        id: "resume-past-work",
                        title: "Resume past work",
                        description: "Right-click supported sessions to continue where you left off."
                    ),
                    Screen.Tip(
                        id: "copy-exact-commands",
                        title: "Copy exact commands",
                        description: "Copy Resume Command gives you the CLI command without launching it."
                    )
                ]
            ),
            Screen(
                id: "images",
                symbolName: "photo.on.rectangle.angled",
                title: "Images",
                body: "Image-heavy sessions have dedicated navigation.",
                bullets: [
                    Screen.Tip(
                        id: "open-image-browser",
                        title: "Open Image Browser",
                        description: "Review images embedded in sessions."
                    ),
                    Screen.Tip(
                        id: "jump-image-prompts",
                        title: "Jump image prompts",
                        description: "Use the Images control in a transcript to move between image prompts."
                    )
                ]
            ),
            Screen(
                id: "transcript-tools",
                symbolName: "doc.text.magnifyingglass",
                title: "Transcript Tools",
                body: "Switch views depending on what you need.",
                bullets: [
                    Screen.Tip(
                        id: "change-transcript-view",
                        title: "Change transcript view",
                        description: "Switch between Session, Text, and JSON views for readability or raw structure."
                    ),
                    Screen.Tip(
                        id: "export-as-markdown",
                        title: "Export as Markdown",
                        description: "Save a session transcript when you need to keep or share it."
                    )
                ]
            ),
            Screen(
                id: "reading-controls",
                symbolName: "textformat.size",
                title: "Reading Controls",
                body: "Long transcripts are easier with keyboard controls.",
                bullets: [
                    Screen.Tip(
                        id: "copy-transcript",
                        title: "Copy the transcript",
                        description: "Use the transcript toolbar to copy the full session."
                    ),
                    Screen.Tip(
                        id: "adjust-text-size",
                        title: "Adjust text size",
                        description: "Use Command-Plus and Command-Minus while reading."
                    )
                ]
            ),
            Screen(
                id: "saved-sessions",
                symbolName: "bookmark",
                title: "Saved Sessions",
                body: "Keep important sessions easy to find.",
                bullets: [
                    Screen.Tip(
                        id: "star-important-sessions",
                        title: "Star important sessions",
                        description: "Reopen them later from Saved Sessions."
                    ),
                    Screen.Tip(
                        id: "filter-to-favorites",
                        title: "Filter to favorites",
                        description: "Use favorites-only mode when you want a short working set."
                    )
                ]
            ),
            Screen(
                id: "reduce-noise",
                symbolName: "line.3.horizontal.decrease.circle",
                title: "Reduce Noise",
                body: "Filters keep the session list focused.",
                bullets: [
                    Screen.Tip(
                        id: "hide-noisy-sessions",
                        title: "Hide noisy sessions",
                        description: "Settings can hide zero-message, low-message, housekeeping, or probe sessions."
                    ),
                    Screen.Tip(
                        id: "show-command-sessions",
                        title: "Show command sessions",
                        description: "Use the commands-only filter to focus on sessions that ran tools or shell commands."
                    )
                ]
            ),
            Screen(
                id: "usage-limits",
                symbolName: "chart.bar.xaxis",
                title: "Usage Limits",
                body: "Usage surfaces can stay visible while agents run.",
                bullets: [
                    Screen.Tip(
                        id: "enable-usage-strips",
                        title: "Enable usage strips",
                        description: "Track Codex and Claude rate-limit state in the app."
                    ),
                    Screen.Tip(
                        id: "use-menu-bar-meters",
                        title: "Use menu bar meters",
                        description: "Keep usage state visible without opening the main window."
                    )
                ]
            ),
            Screen(
                id: "agent-sources",
                symbolName: "slider.horizontal.3",
                title: "Agent Sources",
                body: "Only enable the providers you use.",
                bullets: [
                    Screen.Tip(
                        id: "choose-active-agents",
                        title: "Choose active agents",
                        description: "Disable unused providers from Settings so they stay out of filters."
                    ),
                    Screen.Tip(
                        id: "browse-unified-list",
                        title: "Browse one unified list",
                        description: "Agent Sessions can combine multiple local agent histories."
                    )
                ]
            ),
            Screen(
                id: "side-chats",
                symbolName: "bubble.left.and.bubble.right",
                title: "Side Chats",
                body: "Codex Desktop side chats are recoverable.",
                bullets: [
                    Screen.Tip(
                        id: "filter-to-side-chats",
                        title: "Filter to side chats",
                        description: "Use #side, or #side phrase to search within them."
                    ),
                    Screen.Tip(
                        id: "find-parent-thread",
                        title: "Find the parent thread",
                        description: "Copy Session ID on a side chat copies its parent thread ID."
                    )
                ]
            ),
            Screen(
                id: "archived-sessions",
                symbolName: "archivebox",
                title: "Archived Sessions",
                body: "Old Desktop sessions stay reachable.",
                bullets: [
                    Screen.Tip(
                        id: "search-codex-archives",
                        title: "Search Codex archives",
                        description: "Click the archive icon on the Codex filter (Command-1) to narrow to archived Desktop sessions."
                    ),
                    Screen.Tip(
                        id: "restore-claude-archives",
                        title: "Restore Claude archives",
                        description: "Use the archive icon on the Claude filter (Command-2), then restore in place from the transcript."
                    )
                ]
            ),
            Screen(
                id: "workflow-subagents",
                symbolName: "point.3.connected.trianglepath.dotted",
                title: "Workflow Subagents",
                body: "Claude Code workflows stay readable.",
                bullets: [
                    Screen.Tip(
                        id: "spot-fan-out",
                        title: "Spot fan-out",
                        description: "Workflow subagents nest under the session that launched them with a workflow badge."
                    ),
                    Screen.Tip(
                        id: "resume-the-parent",
                        title: "Resume the parent",
                        description: "Resuming a workflow child resolves to its parent session."
                    )
                ]
            ),
            Screen(
                id: "quick-navigation",
                symbolName: "cursorarrow.click.2",
                title: "Quick Navigation",
                body: "Small shortcuts help when scanning lots of history.",
                bullets: [
                    Screen.Tip(
                        id: "move-through-matches",
                        title: "Move through matches",
                        description: "Use Command-G and Shift-Command-G after searching a transcript."
                    ),
                    Screen.Tip(
                        id: "filter-by-project",
                        title: "Filter by project",
                        description: "Double-click project names in the session list."
                    )
                ]
            )
        ]
    }
}
