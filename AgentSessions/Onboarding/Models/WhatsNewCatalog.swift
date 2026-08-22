import Foundation

/// A single row in the What's New panel. Kinds map to distinct visual treatments
/// (highlights and provider announcements share the highlight look; promos carry a
/// "Promo" tag; the feedback-ask and support rows are call-to-action rows).
struct WhatsNewItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case highlight
        case tip
        case promo
        case feedbackAsk
        case support
    }

    let kind: Kind
    let iconSystemName: String
    let title: String
    let body: String
    /// Optional external link (used by promo / support rows).
    let linkTitle: String?
    let linkURL: URL?

    init(
        kind: Kind,
        iconSystemName: String,
        title: String,
        body: String,
        linkTitle: String? = nil,
        linkURL: URL? = nil
    ) {
        self.kind = kind
        self.iconSystemName = iconSystemName
        self.title = title
        self.body = body
        self.linkTitle = linkTitle
        self.linkURL = linkURL
    }

    /// Stable identity (kind + title) so SwiftUI diffing and tests are deterministic.
    var id: String { "\(kind.rawValue)|\(title)" }
}

/// Bundled, per-release What's New content. Assembly combines authored highlights,
/// auto-generated "new agent support" items (carried over from the old
/// `newProviderScreens` logic), and at most one promo.
enum WhatsNewCatalog {
    // MARK: - Public API

    /// One-line teaser shown on the dismissible session-list card.
    static func teaser(for majorMinor: String) -> String? {
        teasers[majorMinor]
    }

    /// Assembles the ordered list of static What's New rows for a version:
    /// authored highlights, then auto-generated new-provider items, then any
    /// authored tip/promo/support rows (with promos capped at one).
    ///
    /// The `feedbackAsk` row is NOT included here — the panel injects it based on
    /// the coordinator's timing rules so timing stays in one place.
    static func assemble(for majorMinor: String) -> [WhatsNewItem] {
        let authored = enforceSinglePromo(bundled[majorMinor] ?? [])
        let highlights = authored.filter { $0.kind == .highlight }
        let rest = authored.filter { $0.kind != .highlight }
        let providerItems = providerHighlights(for: majorMinor)
        return highlights + providerItems + rest
    }

    /// True if a version has any static What's New content (authored or auto-provider).
    /// The coordinator gates the card on this so empty versions never flag.
    static func hasContent(for majorMinor: String) -> Bool {
        !assemble(for: majorMinor).isEmpty
    }

    // MARK: - Auto-generated provider items

    /// "New agent support" rows for any providers introduced in this version.
    static func providerHighlights(for majorMinor: String) -> [WhatsNewItem] {
        SessionSource.allCases
            .filter { $0.versionIntroduced == majorMinor }
            .map { source in
                WhatsNewItem(
                    kind: .highlight,
                    iconSystemName: source.iconName,
                    title: "New: \(source.displayName)",
                    body: source.featureDescription
                )
            }
    }

    // MARK: - Promo cap

    private static func enforceSinglePromo(_ items: [WhatsNewItem]) -> [WhatsNewItem] {
        var seenPromo = false
        return items.filter { item in
            guard item.kind == .promo else { return true }
            if seenPromo { return false }
            seenPromo = true
            return true
        }
    }

    // MARK: - Bundled content

    private static let githubRepositoryURL = URL(string: "https://github.com/jazzyalex/agent-sessions")
    private static let githubSponsorsURL = URL(string: "https://github.com/sponsors/jazzyalex")

    private static let teasers: [String: String] = [
        "4.3": "A calmer first run, and a What's New you open on your own terms.",
        "4.7": "Kimi Code joins the lineup, and the Quota Meter now sees Claude's cloud sessions.",
        "4.8": "Grok CLI joins the lineup, and Analytics now counts every agent you have enabled.",
        "5.0": "Qwen Code joins the lineup, and agents are now plug-in adapters — adding the one you use is a documented recipe.",
        "5.1": "Devin CLI joins the lineup."
    ]

    private static let bundled: [String: [WhatsNewItem]] = [
        "5.0": [
            // Qwen itself is NOT authored here: `providerHighlights(for:)` generates its
            // row from `SessionSource.qwen.versionIntroduced == "5.0"`. Same split as 4.7
            // and 4.8.
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "square.stack.3d.up",
                title: "Agents are plug-in adapters now",
                body: "Each agent used to be wired in by hand, surface by surface, so a new one could land in the session list and still be missing from Analytics, the filter pills or search. Every agent is now described once, in its own adapter, and every surface reads that description. Adding an agent dropped from 26 shared-file edits to 12, each one listed in the guide with a test that fails if it's missed."
            ),
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "person.2.badge.plus",
                title: "Add the agent you use",
                body: "If your coding agent is missing, there is now a written path to change that — a proposal form, an implementation brief you can hand to your own agent, and a pull-request template. Agents that ship can pick up a steward who keeps their format verified as the CLI moves."
            ),
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "switch.2",
                title: "The agent switches reach everywhere",
                body: "Switching an agent off could leave its sessions in filter-view search results, Kimi and Grok never reported that their loading had finished, and OpenClaw could mark Analytics out of date on every launch. Each of those came from a separate hand-written list of agents, and none of those lists remain."
            ),
            WhatsNewItem(
                kind: .support,
                iconSystemName: "heart.fill",
                title: "Support the project",
                body: "Agent Sessions is local-first, independent, and actively maintained. A GitHub star or sponsorship keeps it going.",
                linkTitle: "Sponsor on GitHub",
                linkURL: githubSponsorsURL
            )
        ],
        "4.8": [
            // Grok itself is NOT authored here: `providerHighlights(for:)` generates its
            // row from `SessionSource.grok.versionIntroduced == "4.8"`, and authoring it
            // again would show it twice. Same split as 4.7, where Kimi's row is auto and
            // these two are not.
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "chart.bar",
                title: "Analytics counts every agent",
                body: "Analytics ran on a hand-written list of agents, and Cursor and OpenClaw were never on it — their sessions showed up everywhere else but contributed to no total, chart or project breakdown. Every agent you enable is now counted, and Cursor gets its own entry in the agent picker."
            ),
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "terminal",
                title: "The right CLI wins",
                body: "Cursor, Kimi, Pi and Grok used the first matching binary they found, so an unrelated tool of the same name earlier in your PATH could mask the real one — reporting its version and refusing to resume. Each now looks for the CLI that answers like the CLI."
            ),
            WhatsNewItem(
                kind: .support,
                iconSystemName: "heart.fill",
                title: "Support the project",
                body: "Agent Sessions is local-first, independent, and actively maintained. A GitHub star or sponsorship keeps it going.",
                linkTitle: "Sponsor on GitHub",
                linkURL: githubSponsorsURL
            )
        ],
        "4.7": [
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "cloud",
                title: "Cloud sessions in the Quota Meter",
                body: "Claude sessions running on Anthropic's infrastructure now appear in the pinned Quota Meter beside your local agents, marked Cloud. Switch them on under Settings → Usage Tracking once you have saved a claude.ai cookie."
            ),
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "dot.radiowaves.left.and.right",
                title: "Headless runs show up too",
                body: "An agent run started by launchd, a shell script, or another app has no terminal, and Live Sessions used to miss it entirely. Those runs now appear like any other session."
            ),
            WhatsNewItem(
                kind: .support,
                iconSystemName: "heart.fill",
                title: "Support the project",
                body: "Agent Sessions is local-first, independent, and actively maintained. A GitHub star or sponsorship keeps it going.",
                linkTitle: "Sponsor on GitHub",
                linkURL: githubSponsorsURL
            )
        ],
        "4.3": [
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "sparkles",
                title: "A calmer first run",
                body: "Onboarding is now a single setup screen — pick your agents, flip on the Quota Meter, and start exploring. No multi-slide tour."
            ),
            WhatsNewItem(
                kind: .highlight,
                iconSystemName: "bell.badge",
                title: "What's New, on your terms",
                body: "Updates no longer interrupt you with a modal. Release highlights live in this panel and a dismissible card you open when you want."
            ),
            WhatsNewItem(
                kind: .tip,
                iconSystemName: "lightbulb.max",
                title: "Power Tip",
                body: "Search across every session with ⌥⌘F, or find inside the open transcript with ⌘F. More tips live in Help → Power Tips."
            ),
            WhatsNewItem(
                kind: .support,
                iconSystemName: "heart.fill",
                title: "Support the project",
                body: "Agent Sessions is local-first, independent, and actively maintained. A GitHub star or sponsorship keeps it going.",
                linkTitle: "Sponsor on GitHub",
                linkURL: githubSponsorsURL
            )
        ]
    ]
}
