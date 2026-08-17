import Foundation
import SwiftUI
import AppKit

// MARK: - SessionSourceAdapter

/// A source's entry in the registry (SPEC §3.2): the descriptor's value data plus the
/// factory for that source's runtime object graph, so one adapter supplies everything the
/// app needs from a provider.
///
/// `makeRuntime` is called exactly once per source, by `SessionProviderCatalog.init`, on the
/// main actor. Each source declares its own in its descriptor file, so adding a source is
/// still one new file plus one line in `ordered` below.
struct SessionSourceAdapter {
    let descriptor: SessionSourceDescriptor
    let makeRuntime: @MainActor () -> SourceRuntime
}

// MARK: - SessionSourceRegistry

/// The canonical runtime registry. Preferences keeps one separate, test-pinned sidebar
/// ordering because that sequence follows UI history rather than registry order.
///
/// `ordered` must stay in `SessionSource.allCases` order — `testRegistryOrderEqualsSessionSourceAllCases`
/// enforces exact array equality, so a new source that forgets its entry, or adds it in the
/// wrong place, fails immediately rather than drifting invisibly through the ~35 hand lists
/// this program replaces.
enum SessionSourceRegistry {
    /// Each entry is a `static let` declared in that source's own descriptor file, next to
    /// the descriptor it wraps.
    static let ordered: [SessionSourceAdapter] = validateIdentityConfigurations([
        .codex,
        .claude,
        .antigravity,
        .opencode,
        .hermes,
        .copilot,
        .droid,
        .openclaw,
        .cursor,
        .pi,
        .kimi,
        .grok,
        .qwen
    ])

    /// Identity parsing and URL classification are one capability. Keeping the closures
    /// separate lets hybrid providers such as Hermes select only their database URLs, but
    /// configuring just one side would silently drop search ingest for those identities.
    private static func validateIdentityConfigurations(
        _ adapters: [SessionSourceAdapter]
    ) -> [SessionSourceAdapter] {
        for adapter in adapters {
            let descriptor = adapter.descriptor
            let hasParser = descriptor.parseFullByIdentity != nil
            let hasSelector = descriptor.searchUsesIdentityAtURL != nil
            precondition(
                hasParser == hasSelector,
                "\(descriptor.source) must configure parseFullByIdentity and searchUsesIdentityAtURL together"
            )
        }
        return adapters
    }

    static let bySource: [SessionSource: SessionSourceAdapter] = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.descriptor.source, $0) }
    )

    /// Non-optional by design: a missing entry is a programming error the order test
    /// catches long before this runs.
    static func adapter(for source: SessionSource) -> SessionSourceAdapter {
        guard let adapter = bySource[source] else {
            preconditionFailure("SessionSourceRegistry.ordered is missing an entry for \(source)")
        }
        return adapter
    }

    static func descriptor(for source: SessionSource) -> SessionSourceDescriptor {
        adapter(for: source).descriptor
    }

    /// One `NSColor` instance per source, built once.
    ///
    /// The memo is not an optimization detail — it is what keeps brand colors *value-stable*.
    /// `adaptiveBrand` mints a fresh `NSColor(name: nil) { … }` on every call, and two such
    /// dynamic colors never compare equal even when they draw identically. Before the
    /// registry, the row accent and the analytics palette read memoized `Color.agentX`
    /// statics, so repeated reads returned the same instance and SwiftUI's equality checks
    /// short-circuited. `cellSource(for:)` asks for a row accent twice per row per rebuild,
    /// and this repo is measurably sensitive to `Table` diffing, so handing back a new
    /// object each time would quietly defeat that. Resolving once here restores the old
    /// identity guarantee — see `testResolvedBrandAccentIsValueStableAcrossCalls`.
    ///
    /// Safe with respect to the initialization cycle Task 3 hit: the only thing this
    /// computes with is `adaptiveBrand`, which never re-enters the registry.
    private static let resolvedBrandAccents: [SessionSource: NSColor] = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.descriptor.source, makeBrandAccent(for: $0.descriptor)) }
    )

    /// Rebuilds exactly what `TranscriptColorSystem.agentBrandAccent(source:)` returned
    /// before Task 3: `.system` hues pass straight through, `.calibrated` triples go through
    /// `adaptiveBrand` (K6).
    private static func makeBrandAccent(for descriptor: SessionSourceDescriptor) -> NSColor {
        switch descriptor.brandHue {
        case .system(let color):
            return color
        case .calibrated(let red, let green, let blue):
            return TranscriptColorSystem.adaptiveBrand(
                NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
            )
        }
    }

    /// The source's brand accent. `TranscriptColorSystem.agentBrandAccent(source:)` is this.
    /// Repeated calls return the *same* instance (see `resolvedBrandAccents`).
    static func resolvedBrandAccent(for source: SessionSource) -> NSColor {
        guard let color = resolvedBrandAccents[source] else {
            preconditionFailure("SessionSourceRegistry.ordered is missing an entry for \(source)")
        }
        return color
    }
}

// MARK: - SessionSource convenience

extension SessionSource {
    /// This source's registry descriptor. App-target only — `SessionSource.swift` itself
    /// stays free of registry dependencies so it keeps compiling into the standalone
    /// logic-test target (K15).
    var descriptor: SessionSourceDescriptor {
        SessionSourceRegistry.descriptor(for: self)
    }
}
