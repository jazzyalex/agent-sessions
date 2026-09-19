import Foundation

// MARK: - SessionSourceDescriptorCatalog

/// The UI-free list of every source's descriptor, in `SessionSource.allCases` order.
/// Shared by the macOS app and the Linux core: indexing, search ingest, and the CLI read
/// descriptors here. The app's `SessionSourceRegistry` pairs each descriptor with its
/// runtime factory and palette; `testRegistryMatchesDescriptorCatalog` keeps the two
/// lists in step, so a new source adds one line to each.
enum SessionSourceDescriptorCatalog {
    static let ordered: [SessionSourceDescriptor] = validateIdentityConfigurations([
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
        .qwen,
        .devin,
        .fx,
        .cline
    ])

    /// Identity parsing and URL classification are one capability. Keeping the closures
    /// separate lets hybrid providers such as Hermes select only their database URLs, but
    /// configuring just one side would silently drop search ingest for those identities.
    private static func validateIdentityConfigurations(
        _ descriptors: [SessionSourceDescriptor]
    ) -> [SessionSourceDescriptor] {
        for descriptor in descriptors {
            let hasParser = descriptor.parseFullByIdentity != nil
            let hasSelector = descriptor.searchUsesIdentityAtURL != nil
            // `assert`, not `precondition`: the invariant is compile-time constant and is
            // covered by the registry tests, so a descriptor mistake must fail the suite,
            // not trap in a shipped build (this runs inside a `static let` initializer).
            assert(
                hasParser == hasSelector,
                "\(descriptor.source) must configure parseFullByIdentity and searchUsesIdentityAtURL together"
            )
        }
        return descriptors
    }

    static let bySource: [SessionSource: SessionSourceDescriptor] = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.source, $0) }
    )

    /// Sources whose sessions share one storage database and are therefore keyed by
    /// identity rather than by file path. Their search rows record a per-session logical
    /// revision instead of the storage file's stat, so file-stat currency predicates do
    /// not apply to them — see `IndexDB.indexedSessionIDsCurrent`.
    static let identityBackedSourceRawValues: Set<String> = Set(
        ordered
            .filter { $0.parseFullByIdentity != nil && $0.searchUsesIdentityAtURL != nil }
            .map { $0.source.rawValue }
    )

    /// Non-optional by design: a missing entry is a programming error the order test
    /// catches long before this runs.
    static func descriptor(for source: SessionSource) -> SessionSourceDescriptor {
        guard let descriptor = bySource[source] else {
            preconditionFailure("SessionSourceDescriptorCatalog.ordered is missing an entry for \(source)")
        }
        return descriptor
    }
}
