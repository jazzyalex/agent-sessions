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
        "4.3": "A calmer first run, and a What's New you open on your own terms."
    ]

    private static let bundled: [String: [WhatsNewItem]] = [
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
