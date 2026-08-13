import Foundation

/// The providers whose sessions analytics rolls up.
///
/// One declaration, two views: `AnalyticsService` needs `SessionSource` values, the
/// `UnifiedSessionIndexer` build/backfill path needs raw strings. Those were separate
/// hand-maintained lists until Pi was added, and nothing tied them together — a provider
/// present in one and missing from the other produced no error, just silently absent
/// analytics.
///
/// Every provider rolls up. This is `SessionSource.allCases` rather than a hand-written
/// subset because the subset kept drifting: Grok shipped wired into `AnalyticsService`,
/// `AnalyticsColors` and `AnalyticsView` but missing from the list, and Cursor was absent
/// for longer still. Nothing failed in either case — the provider simply never entered an
/// analytics build. Analytics is source-agnostic (`AnalyticsIndexer` derives everything
/// from `session_meta`, which `SearchIngestService` writes for every ingested source), so
/// there was never a technical reason for a provider to sit outside it.
///
/// Adding a provider still needs a dedicated `AnalyticsAgentFilter` case, or the agent
/// picker has no way to isolate it; `testEveryAnalyticsSupportedSourceHasADedicatedAgentFilter`
/// enforces that pairing and now fails loudly for any new source until the case exists.
enum AnalyticsSourceSupport {
    static let sources: Set<SessionSource> = Set(SessionSource.allCases)

    static let rawValues: Set<String> = Set(sources.map(\.rawValue))
}
