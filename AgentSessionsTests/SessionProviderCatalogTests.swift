import XCTest
import Combine
@testable import AgentSessions

/// SPEC §10.7 + K16. Two obligations:
///
/// 1. **Completeness** — the catalog builds a working runtime for every `SessionSource`,
///    so a thirteenth source that forgets its adapter fails here rather than crashing at
///    the first `catalog[.newSource]`.
/// 2. **Silence (K16)** — the catalog publishes nothing that changes after init. Every
///    catalog consumer would otherwise re-render on every index tick, which is strictly
///    worse than the twelve-`@StateObject` wiring it replaces.
///
/// `@MainActor` throughout: the catalog's init is main-actor isolated, and forcing the
/// registry's descriptors materializes `static let`s that touch AppKit.
@MainActor
final class SessionProviderCatalogTests: XCTestCase {

    // MARK: - Completeness

    func testCatalogCoversEverySourceWithWorkingRuntimes() {
        let catalog = SessionProviderCatalog()
        XCTAssertEqual(Set(catalog.runtimes.keys), Set(SessionSource.allCases))
        for s in SessionSource.allCases {
            XCTAssertEqual(catalog[s].source, s)
            _ = catalog[s].searchAdapter   // constructing must not crash / not be a stub
        }
    }

    /// The runtime's indexer is the concrete class that source's adapter names, and the
    /// typed downcast helper agrees with the type-erased `indexerObject`.
    func testTypedIndexerLookupMatchesRuntimeObject() {
        let catalog = SessionProviderCatalog()
        XCTAssertTrue(catalog.indexer(.codex, as: SessionIndexer.self)
            === (catalog[.codex].indexerObject as? SessionIndexer))
        XCTAssertTrue(catalog.indexer(.claude, as: ClaudeSessionIndexer.self)
            === (catalog[.claude].indexerObject as? ClaudeSessionIndexer))
        XCTAssertTrue(catalog.indexer(.grok, as: GrokSessionIndexer.self)
            === (catalog[.grok].indexerObject as? GrokSessionIndexer))
    }

    /// Registry order must mirror `SessionSource.allCases` order (SPEC §10.1) — the catalog
    /// builds indexers in that order, so it is also the construction order that replaced
    /// `AgentSessionsApp`'s twelve `@StateObject` declarations.
    func testRegistryOrderMatchesAllCasesOrder() {
        XCTAssertEqual(SessionSourceRegistry.ordered.map { $0.descriptor.source },
                       SessionSource.allCases)
    }

    /// Every registered adapter produces a runtime whose `source` matches the descriptor it
    /// was declared under — catches a copy-paste `makeRuntime` that builds the wrong
    /// provider's indexer.
    func testEveryAdapterRuntimeReportsItsOwnSource() {
        let catalog = SessionProviderCatalog()
        for adapter in SessionSourceRegistry.ordered {
            let source = adapter.descriptor.source
            XCTAssertEqual(catalog[source].source, source)
        }
    }

    // MARK: - K16: the catalog publishes nothing

    /// Structural check: no `@Published` stored properties at all.
    func testCatalogHasNoPublishedStoredProperties() {
        let catalog = SessionProviderCatalog()
        let published = Mirror(reflecting: catalog).children.filter {
            String(describing: type(of: $0.value)).contains("Published")
        }
        XCTAssertTrue(published.isEmpty,
                      "catalog must publish nothing post-init; found \(published.map { $0.label ?? "?" })")
    }

    /// Behavioural check: churning a source's indexer — the exact traffic a real index run
    /// produces — must not make the catalog emit `objectWillChange`.
    ///
    /// The published properties are driven directly rather than via `handle.refresh(…)`:
    /// a real refresh would scan the developer's own session directories, and every
    /// provider `refresh` early-returns unless that agent is enabled, so it would prove
    /// nothing in most environments. Setting the properties fires each indexer's
    /// `objectWillChange` unconditionally, which is what this test needs to stay silent
    /// at the catalog.
    func testCatalogDoesNotEmitWhenAnIndexerChurns() {
        let catalog = SessionProviderCatalog()
        var emissions = 0
        let token = catalog.objectWillChange.sink { _ in emissions += 1 }
        defer { token.cancel() }

        let codex = catalog.indexer(.codex, as: SessionIndexer.self)
        codex.isIndexing = true
        codex.filesProcessed = 7
        codex.totalFiles = 12
        codex.launchPhase = .scanning
        codex.isIndexing = false
        codex.launchPhase = .ready

        let grok = catalog.indexer(.grok, as: GrokSessionIndexer.self)
        grok.isProcessingTranscripts = true
        grok.indexingError = "synthetic"
        grok.launchPhase = .ready

        XCTAssertEqual(emissions, 0, "catalog emitted objectWillChange on indexer churn")
    }

    /// The handles must observe the same objects the catalog retains: a value pushed into a
    /// concrete indexer shows up through the type-erased handle, with no downcast.
    func testHandleReadsTrackTheRetainedIndexer() {
        let catalog = SessionProviderCatalog()
        let grok = catalog.indexer(.grok, as: GrokSessionIndexer.self)
        grok.launchPhase = .scanning
        XCTAssertEqual(catalog[.grok].handle.currentLaunchPhase(), .scanning)
        grok.isIndexing = true
        XCTAssertTrue(catalog[.grok].handle.currentIsIndexing())
        grok.launchPhase = .ready
        XCTAssertEqual(catalog[.grok].handle.currentLaunchPhase(), .ready)
    }

    /// `combineLatestArray` is the fold the pyramids collapse into (SPEC §3.4): it holds the
    /// latest of every upstream, emits nothing until all of them have produced, and keeps
    /// the input order.
    func testCombineLatestArrayHoldsLatestOfEachInOrder() {
        let a = CurrentValueSubject<Int, Never>(1)
        let b = PassthroughSubject<Int, Never>()
        var received: [[Int]] = []
        let token = Publishers.combineLatestArray([a.eraseToAnyPublisher(), b.eraseToAnyPublisher()])
            .sink { received.append($0) }
        defer { token.cancel() }

        XCTAssertTrue(received.isEmpty, "must not emit before every upstream has a value")
        b.send(2)
        XCTAssertEqual(received, [[1, 2]])
        a.send(3)
        XCTAssertEqual(received, [[1, 2], [3, 2]])
    }

    func testCombineLatestArrayEmitsEmptyForNoPublishers() {
        var received: [[Int]] = []
        let token = Publishers.combineLatestArray([AnyPublisher<Int, Never>]())
            .sink { received.append($0) }
        defer { token.cancel() }
        XCTAssertEqual(received, [[]])
    }
}
