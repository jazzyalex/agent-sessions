import XCTest
import Combine
@testable import AgentSessions

/// SPEC §10.7 + K16. Two obligations:
///
/// 1. **Completeness** — the catalog builds a correctly typed runtime for every `SessionSource`,
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

    func testCatalogCoversEverySourceWithRuntimes() {
        let catalog = SessionProviderCatalog()
        XCTAssertEqual(Set(catalog.runtimes.keys), Set(SessionSource.allCases))
        for s in SessionSource.allCases {
            XCTAssertEqual(catalog[s].source, s)
            _ = catalog[s].searchAdapter
        }
    }

    /// The runtime's indexer is the concrete class that source's adapter names, and the
    /// typed downcast helper agrees with the type-erased `indexerObject`.
    func testTypedIndexerLookupMatchesRuntimeObject() {
        let catalog = SessionProviderCatalog()
        assertIndexer(catalog, source: .codex, is: SessionIndexer.self)
        assertIndexer(catalog, source: .claude, is: ClaudeSessionIndexer.self)
        assertIndexer(catalog, source: .antigravity, is: AntigravitySessionIndexer.self)
        assertIndexer(catalog, source: .opencode, is: OpenCodeSessionIndexer.self)
        assertIndexer(catalog, source: .hermes, is: HermesSessionIndexer.self)
        assertIndexer(catalog, source: .copilot, is: CopilotSessionIndexer.self)
        assertIndexer(catalog, source: .droid, is: DroidSessionIndexer.self)
        assertIndexer(catalog, source: .openclaw, is: OpenClawSessionIndexer.self)
        assertIndexer(catalog, source: .cursor, is: CursorSessionIndexer.self)
        assertIndexer(catalog, source: .pi, is: PiSessionIndexer.self)
        assertIndexer(catalog, source: .kimi, is: KimiSessionIndexer.self)
        assertIndexer(catalog, source: .grok, is: GrokSessionIndexer.self)
        assertIndexer(catalog, source: .qwen, is: QwenSessionIndexer.self)
        assertIndexer(catalog, source: .devin, is: DevinSessionIndexer.self)
        assertIndexer(catalog, source: .fx, is: FxSessionIndexer.self)
    }

    /// Registry order must mirror `SessionSource.allCases` order (SPEC §10.1) — the catalog
    /// builds indexers in that order, so it is also the construction order that replaced
    /// `AgentSessionsApp`'s twelve `@StateObject` declarations.
    func testRegistryOrderMatchesAllCasesOrder() {
        XCTAssertEqual(SessionSourceRegistry.ordered.map { $0.descriptor.source },
                       SessionSource.allCases)
    }

    /// Every registered adapter produces a runtime whose `source` matches the descriptor it
    /// was declared under. Concrete indexer-class pairing is checked independently above.
    func testEveryAdapterRuntimeReportsItsOwnSource() {
        let catalog = SessionProviderCatalog()
        for adapter in SessionSourceRegistry.ordered {
            let source = adapter.descriptor.source
            XCTAssertEqual(catalog[source].source, source)
        }
    }

    func testRuntimeIdentitySnapshotCapabilityMatchesDescriptor() {
        let catalog = SessionProviderCatalog()
        for adapter in SessionSourceRegistry.ordered {
            let source = adapter.descriptor.source
            let descriptorUsesIdentity = adapter.descriptor.parseFullByIdentity != nil
                && adapter.descriptor.searchUsesIdentityAtURL != nil
            XCTAssertEqual(catalog[source].handle.searchIdentitySnapshots.isApplicable,
                           descriptorUsesIdentity,
                           "\(source)")
        }
    }

    private func assertIndexer<T: ObservableObject>(_ catalog: SessionProviderCatalog,
                                                     source: SessionSource,
                                                     is type: T.Type,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) {
        guard let erased = catalog[source].indexerObject as? T else {
            return XCTFail("Runtime for \(source) is not \(T.self)", file: file, line: line)
        }
        XCTAssertTrue(catalog.indexer(source, as: type) === erased, file: file, line: line)
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

    /// `UnifiedSessionIndexer.performProviderRefresh` triggers a provider refresh and then
    /// polls `currentIsIndexing()` to learn when that refresh finished, because only then is
    /// the provider's session list current enough to hand to search ingest. The poll starts
    /// immediately after `refresh(...)` returns, so the contract every indexer owes it is:
    /// **`isIndexing` must be observable as `true` by the time `refresh` returns.**
    ///
    /// Claude was the one provider that broke it — it published the flag from inside
    /// `publishAfterCurrentUpdate` (a main-queue hop plus two `Task.yield()`s), so the first
    /// poll read `false`, the wait loop exited after zero iterations, and the kick ran
    /// against the *pre-refresh* session list: empty at launch, and byte-identical across the
    /// monitor path's before/after fingerprint comparison, which then suppressed the kick
    /// outright. Claude's search corpus stopped advancing entirely.
    func testRefreshPublishesIsIndexingBeforeItReturns() {
        let defaults = UserDefaults.standard
        let overrideKey = PreferencesKey.Paths.claudeSessionsRootOverride
        // Derived, not spelled: `AgentEnablement.isEnabled` reads `descriptor.enablementKey`,
        // and a hand-written literal that drifts from it would write a dead key while
        // `defaultEnabled: .always` kept the test green — passing without controlling its
        // own precondition.
        let enabledKey = AgentEnablement.enablementKey(for: .claude)
        let previousOverride = defaults.string(forKey: overrideKey)
        let previousEnabled = defaults.object(forKey: enabledKey)

        // The refresh task hydrates through `IndexDB()`, which opens the real
        // ~/Library/Application Support/AgentSessions/index.db and is NOT scoped by the
        // sessions-root override — that override only bounds filesystem discovery. Without
        // this hook the test would read (and, via `upsertSessionMetaCore`, write) the
        // developer's live index.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-refresh-flag-\(UUID().uuidString)")
        let emptyRoot = sandbox.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let previousProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        IndexDBTestHooks.applicationSupportDirectoryProvider = { sandbox }
        defaults.set(emptyRoot.path, forKey: overrideKey)
        defaults.set(true, forKey: enabledKey)
        defer {
            IndexDBTestHooks.applicationSupportDirectoryProvider = previousProvider
            if let previousOverride { defaults.set(previousOverride, forKey: overrideKey) }
            else { defaults.removeObject(forKey: overrideKey) }
            if let previousEnabled { defaults.set(previousEnabled, forKey: enabledKey) }
            else { defaults.removeObject(forKey: enabledKey) }
            try? FileManager.default.removeItem(at: sandbox)
        }

        // Optional, and explicitly dropped in the defer below — which runs before the defaults
        // restore above (LIFO). Restoring the sessions-root override is a real value change,
        // and ClaudeSessionIndexer's own FilteredDefaultsObserver (:158) answers a change by
        // scheduling another refresh — one that would run against the developer's real root,
        // after the IndexDB hook is already back. Releasing the indexer here leaves nothing to
        // answer it, instead of depending on this local going out of scope at the right moment.
        var indexer: ClaudeSessionIndexer? = ClaudeSessionIndexer()
        defer {
            indexer?.cancelInFlightWork()
            indexer = nil
        }

        XCTAssertEqual(indexer?.isIndexing, false, "precondition: a freshly built indexer is idle")
        indexer?.refresh(mode: .incremental, trigger: .launch, executionProfile: .interactive)
        XCTAssertEqual(indexer?.isIndexing, true,
                       "refresh() must publish isIndexing synchronously; performProviderRefresh polls it the instant refresh returns")

        // The other half of the contract. `shouldRefreshSource` is
        // `isAgentEnabled(source) && !currentIsIndexing()`, so a flag that never clears drops
        // every later refresh at that guard — the same stall from the opposite direction, and
        // just as silent. Waiting for the real transition (rather than only asserting the
        // leading edge) also guarantees the sandbox outlives the refresh's own DB work.
        //
        // Known cost: this wait is what makes the test seconds rather than milliseconds —
        // measured 3.7s / 8.6s / 5.6s / 5.1s across four runs, against ~0.013s before it was
        // added. Against an empty sandbox DB `hydrateFromIndexDBIfAvailable` always returns
        // nil, so the refresh always takes the 250ms retry sleep before scanning and
        // prewarming; the spread on top of that is scan/prewarm contention with whatever else
        // the machine is doing. That is the price of the teardown barrier the IndexDB sandbox
        // depends on, not stray waste — budget it deliberately before trimming it.
        let cleared = expectation(description: "claude refresh clears isIndexing")
        // The claim is "isIndexing cleared", not "cleared exactly once". `@Published` emits on
        // assignment rather than on change, so any future early-exit that assigns false a
        // second time would otherwise fail this test as an XCTest over-fulfil API violation —
        // pointing the next reader at the test instead of at the path they just added.
        cleared.assertForOverFulfill = false
        let watch = indexer?.$isIndexing.dropFirst().sink { if !$0 { cleared.fulfill() } }
        defer { watch?.cancel() }
        wait(for: [cleared], timeout: 30)
        XCTAssertEqual(indexer?.isIndexing, false,
                       "refresh() must clear isIndexing when it completes, or shouldRefreshSource drops every later refresh")

        // Pin the isolation itself, not just the behaviour it protects. Nothing above would
        // notice if the IndexDB hook stopped being honoured — the assertions never observe
        // the database — so the test would quietly go back to driving the developer's real
        // index and still report green, which is how its first version shipped. `IndexDB`
        // writes `<appSupport>/AgentSessions/index.db`, so this file existing under the
        // sandbox is proof the refresh above hydrated from there and nowhere else.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sandbox.appendingPathComponent("AgentSessions/index.db").path),
            "the refresh must have hydrated from the sandboxed IndexDB, not the real one")
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

    // MARK: - SPEC §10.4 / §8.1: the launch-phase pipeline covers every source

    /// THE §8.1 proof. Before Task 7 the `launchPhase` pyramid combined ten of the twelve
    /// providers — `kimi` and `grok` were never added to it — so a phase change from either
    /// one could not move `launchState`. The unified indexer is built here over twelve fake
    /// handles (no real indexers, no disk), `kimi`'s phase subject is pushed, and the
    /// resulting `launchState.sourcePhases[.kimi]` must follow.
    ///
    /// It has to be the launch-phase pipeline that recomputes: the `include*` side-channel
    /// also calls `updateLaunchState()`, so nothing here touches an inclusion flag after the
    /// indexer is built.
    func testKimiLaunchPhaseEmissionUpdatesLaunchState() throws {
        let kimiPhase = CurrentValueSubject<LaunchPhase, Never>(.idle)
        var handles = FakeProviderHandles.allReady()
        handles[.kimi] = FakeProviderHandles.handle(launchPhase: kimiPhase)

        let suiteName = "KimiLaunchPhaseEmission-\(UUID().uuidString)"
        let scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { scratch.removePersistentDomain(forName: suiteName) }
        // Only kimi is enabled: every other source folds to `.ready` in `updateLaunchState`,
        // and no source flips off→on except (possibly) kimi itself.
        for source in SessionSource.allCases {
            scratch.set(source == .kimi, forKey: AgentEnablement.enablementKey(for: source))
        }

        let unified = UnifiedSessionIndexer(handles: handles)
        let savedIncludeKimi = unified.includeKimi
        defer { unified.includeKimi = savedIncludeKimi }
        unified.includeKimi = true
        unified.syncAgentEnablementFromDefaults(defaults: scratch)

        // Inclusion and enablement changes each recompute the launch state through their own
        // subscriptions, so they are drained to quiescence *before* the phase is pushed —
        // otherwise a trailing side-channel emission would pick the new phase up and this
        // test would pass even with kimi missing from the launchPhase fold (it did, first
        // time round). After this drain the fold is the only thing that can move it.
        drain(seconds: 0.6)
        XCTAssertEqual(unified.launchState.sourcePhases[.kimi], .idle,
                       "kimi must be enabled, included and observed before the emission under test")

        kimiPhase.send(.scanning)

        XCTAssertTrue(waitForLaunchPhase(.scanning, source: .kimi, on: unified),
                      "kimi's launchPhase emission never reached launchState; got \(String(describing: unified.launchState.sourcePhases[.kimi]))")

        kimiPhase.send(.ready)
        XCTAssertTrue(waitForLaunchPhase(.ready, source: .kimi, on: unified),
                      "kimi never returned to .ready; got \(String(describing: unified.launchState.sourcePhases[.kimi]))")
    }

    /// Runs the main run loop for `seconds` so every queued Combine delivery, debounced
    /// recompute and `publishAfterCurrentUpdate` hop lands before the next assertion.
    private func drain(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// `updateLaunchState` publishes through `publishAfterCurrentUpdate` (two main-queue
    /// hops), so the assertion has to spin the run loop rather than read straight through.
    private func waitForLaunchPhase(_ phase: LaunchPhase,
                                    source: SessionSource,
                                    on unified: UnifiedSessionIndexer,
                                    timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if unified.launchState.sourcePhases[source] == phase { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return unified.launchState.sourcePhases[source] == phase
    }
}

// MARK: - Test support

/// Twelve synthetic `ProviderHandle`s, so a `UnifiedSessionIndexer` can be built without a
/// single real provider indexer (and therefore without touching the developer's session
/// directories). Each handle is backed by `CurrentValueSubject`s so every array fold in the
/// indexer has a value from every source immediately — `combineLatestArray` emits nothing
/// until all of its upstreams have produced.
@MainActor
enum FakeProviderHandles {
    /// One handle per source, all idle/ready-ish and inert: `refresh` and
    /// `reloadFocusedSession` do nothing.
    static func allReady() -> [SessionSource: UnifiedSessionIndexer.ProviderHandle] {
        Dictionary(uniqueKeysWithValues: SessionSource.allCases.map {
            ($0, handle(launchPhase: CurrentValueSubject<LaunchPhase, Never>(.ready)))
        })
    }

    static func handle(launchPhase: CurrentValueSubject<LaunchPhase, Never>)
        -> UnifiedSessionIndexer.ProviderHandle {
        UnifiedSessionIndexer.ProviderHandle(
            allSessions: CurrentValueSubject<[Session], Never>([]).eraseToAnyPublisher(),
            isIndexing: CurrentValueSubject<Bool, Never>(false).eraseToAnyPublisher(),
            isProcessingTranscripts: CurrentValueSubject<Bool, Never>(false).eraseToAnyPublisher(),
            filesProcessed: CurrentValueSubject<Int, Never>(0).eraseToAnyPublisher(),
            totalFiles: CurrentValueSubject<Int, Never>(0).eraseToAnyPublisher(),
            indexingError: CurrentValueSubject<String?, Never>(nil).eraseToAnyPublisher(),
            launchPhase: launchPhase.eraseToAnyPublisher(),
            currentSessions: { [] },
            currentIsIndexing: { false },
            currentLaunchPhase: { launchPhase.value },
            searchIdentitySnapshots: .notApplicable,
            refresh: { _, _, _ in },
            reloadFocusedSession: { _, _, _ in }
        )
    }
}
