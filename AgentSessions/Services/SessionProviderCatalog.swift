import Foundation
import Combine
import SwiftUI

// MARK: - SourceRuntime (SPEC §3.2)

/// Everything one source contributes to the running app: the retained indexer, the
/// type-erased pipeline surface, and the search-store adapter.
///
/// Built exactly once per source by `SessionSourceAdapter.makeRuntime`, at catalog
/// construction, on the main actor.
///
/// RETAIN-CYCLE RULE (SPEC §3.4): the closures inside `handle` and `searchAdapter` capture
/// the concrete indexer instance and NOTHING else — never `self`, never the catalog, never
/// a view. `UnifiedSessionIndexer` has a `deinit` that must keep running, and it holds the
/// runtimes; a closure that captured it back would strand that teardown.
@MainActor
struct SourceRuntime {
    let source: SessionSource
    /// The retained concrete indexer, type-erased so the catalog can hold every registered
    /// provider in one dictionary. The indexers conform to `SessionIndexerProtocol`, so no
    /// provider-specific storage is needed here.
    let indexerObject: any SessionIndexerProtocol & ObservableObject
    /// Type-erased pipeline surface. Declared nested in `UnifiedSessionIndexer` so it can
    /// name that type's `FocusedReloadTrigger`.
    let handle: UnifiedSessionIndexer.ProviderHandle
    /// The `SearchSessionStore.Adapter` that used to be built inline in
    /// `UnifiedSessionsView.init`, transcribed verbatim per source.
    let searchAdapter: SearchSessionStore.Adapter
}

// MARK: - SessionProviderCatalog (SPEC §3.3)

/// One lifecycle owner for every source's runtime, replacing the twelve positional
/// `@StateObject`s that used to be threaded by hand through `AgentSessionsApp` →
/// `UnifiedSessionsView` → `TranscriptHostView` / `AnalyticsService` / `FirstRunSetupView`.
///
/// **K16 — publishes NOTHING post-init.** `runtimes` is a `let`, and there are deliberately
/// no `@Published` stored properties, so `objectWillChange` never fires. Views keep
/// observing the concrete indexers they always observed, which means invalidation
/// granularity is unchanged: putting an `@Published` here would re-render every catalog
/// consumer on every index tick. `SessionProviderCatalogTests` pins both halves of that
/// (no `@Published` members; zero emissions under indexer churn).
///
/// It is an `ObservableObject` only so `AgentSessionsApp` can hold it in a `@StateObject`
/// and get SwiftUI's once-per-scene lifetime guarantee for every registered indexer.
@MainActor
final class SessionProviderCatalog: ObservableObject {
    let runtimes: [SessionSource: SourceRuntime]

    init(runtimes: [SessionSource: SourceRuntime]) {
        self.runtimes = runtimes
    }

    /// Builds every runtime the registry declares, in registry order.
    ///
    /// Registry order is `SessionSource.allCases` order (enforced by
    /// `testRegistryOrderEqualsSessionSourceAllCases`), giving construction a stable,
    /// explicit order independent of the former `@StateObject` declaration layout.
    convenience init(adapters: [SessionSourceAdapter] = SessionSourceRegistry.ordered) {
        var built: [SessionSource: SourceRuntime] = [:]
        for adapter in adapters {
            let runtime = adapter.makeRuntime()
            let descriptorUsesIdentity = adapter.descriptor.parseFullByIdentity != nil
                && adapter.descriptor.searchUsesIdentityAtURL != nil
            precondition(
                runtime.handle.searchIdentitySnapshots.isApplicable == descriptorUsesIdentity,
                "\(adapter.descriptor.source) runtime identity snapshot capability does not match its descriptor"
            )
            built[adapter.descriptor.source] = runtime
        }
        self.init(runtimes: built)
    }

    /// Non-optional by design, matching `SessionSourceRegistry.adapter(for:)`: a missing
    /// runtime is a programming error the completeness test catches long before this runs.
    subscript(source: SessionSource) -> SourceRuntime {
        guard let runtime = runtimes[source] else {
            preconditionFailure("SessionProviderCatalog has no runtime for \(source)")
        }
        return runtime
    }

    /// The concrete indexer, for the call sites that genuinely need the nominal type
    /// (`TranscriptHostView`'s twelve transcript views, `PreferencesWindowController`,
    /// `UnifiedSessionIndexer`'s still-switch-based internals).
    ///
    /// Non-optional for the same reason as the subscript: the pairing of source to indexer
    /// class is fixed in that source's own adapter, so a failed cast is a wiring bug, not a
    /// runtime condition any call site could handle.
    func indexer<T: ObservableObject>(_ source: SessionSource, as type: T.Type) -> T {
        guard let typed = self[source].indexerObject as? T else {
            preconditionFailure("Runtime for \(source) is not a \(T.self)")
        }
        return typed
    }
}
