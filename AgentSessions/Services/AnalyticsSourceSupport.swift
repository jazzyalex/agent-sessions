import Foundation

/// The providers whose sessions analytics rolls up.
///
/// One declaration, two views: `AnalyticsService` needs `SessionSource` values, the
/// `UnifiedSessionIndexer` build/backfill path needs raw strings. Those were separate
/// hand-maintained lists until Pi was added, and nothing tied them together — a provider
/// present in one and missing from the other produced no error, just silently absent
/// analytics.
///
/// Adding a provider here is not sufficient on its own. It also needs a dedicated
/// `AnalyticsAgentFilter` case, or the Analytics agent picker has no way to isolate it;
/// `testEveryAnalyticsSupportedSourceHasADedicatedAgentFilter` enforces that pairing.
enum AnalyticsSourceSupport {
    static let sources: Set<SessionSource> = [
        .codex, .claude, .antigravity, .opencode, .hermes, .copilot, .droid, .pi, .kimi
    ]

    static let rawValues: Set<String> = Set(sources.map(\.rawValue))
}
