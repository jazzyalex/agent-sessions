import Combine
import XCTest
@testable import AgentSessions

private final class VerificationStore: SearchSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var scanned: [SearchCoordinator.SessionKey] = []
    private var hydrated = 0
    private var published = 0
    var scans: [SearchCoordinator.SessionKey] { lock.lock(); defer { lock.unlock() }; return scanned }
    var hydrationCount: Int { lock.lock(); defer { lock.unlock() }; return hydrated }
    var publicationCount: Int { lock.lock(); defer { lock.unlock() }; return published }
    func transcriptCache(for source: SessionSource) -> TranscriptCache? { nil }
    func updateSession(_ session: Session) { lock.lock(); published += 1; lock.unlock() }
    func parseFull(session: Session) async -> Session? { noteHydration(); return nil }
    private func noteHydration() { lock.lock(); hydrated += 1; lock.unlock() }
    private func noteScan(_ session: Session) { lock.lock(); scanned.append(.init(session)); lock.unlock() }
    func scan(session: Session, query: SearchQuery) async -> SearchScanResult {
        noteScan(session)
        return await SearchSourceScanner.scan(session: session, query: query)
    }
}

@MainActor
final class SearchCoordinatorVerificationTests: XCTestCase {
    private func row(_ id: String, text: String, source: SessionSource = .claude, endTime: Date? = nil) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(id + ".jsonl")
        let record: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: path)
        return Session(id: id, source: source, startTime: nil, endTime: endTime, model: nil, filePath: path.path,
            eventCount: 1, events: [], cwd: nil, repoName: nil, lightweightTitle: "Fixture")
    }
    private func settled(_ coordinator: SearchCoordinator, excerpts: [Session] = []) async throws {
        for _ in 0..<200 {
            if !coordinator.isRunning, excerpts.allSatisfy({ coordinator.snippets[.init($0)] != nil }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Search did not terminate")
    }

    func testInstantWithoutDatabaseNeverScansOrHydratesAndReturnScansEveryEligibleRow() async throws {
        let rows = try [row("first", text: "needle"), row("second", text: "needle")]
        let store = VerificationStore()
        let coordinator = SearchCoordinator(store: store, db: nil)
        coordinator.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude], enableDeepScan: false, all: rows)
        try await settled(coordinator)
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertTrue(store.scans.isEmpty)
        XCTAssertEqual(store.hydrationCount, 0)
        let verifying = SearchCoordinator(store: store, db: nil)
        verifying.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude], enableDeepScan: true, all: rows)
        try await settled(verifying)
        XCTAssertEqual(Set(store.scans), Set(rows.map(SearchCoordinator.SessionKey.init)))
        XCTAssertEqual(verifying.verifiedKeys.count, 2)
        XCTAssertEqual(verifying.completeCount, 2)
        XCTAssertEqual(store.hydrationCount, 0)
        XCTAssertEqual(store.publicationCount, 0)
        XCTAssertTrue(verifying.results.allSatisfy { $0.events.isEmpty })
    }

    func testReturnRemovesContradictedSampledHitAndRetainsActualSourceHit() async throws {
        let (db, cleanup) = try makeTestIndexDB(); defer { cleanup() }
        let stale = try row("stale", text: "other"), actual = try row("actual", text: "needle")
        try await index(stale, in: db, text: "needle was in the sampled passage")
        try await index(actual, in: db, text: "other")
        let store = VerificationStore()
        let coordinator = SearchCoordinator(store: store, db: db)
        coordinator.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude], enableDeepScan: false, all: [stale, actual])
        try await settled(coordinator, excerpts: [stale])
        XCTAssertEqual(coordinator.results.map(\.id), [stale.id])
        XCTAssertEqual(coordinator.snippets[.init(stale)]?.match, "needle")

        coordinator.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude], enableDeepScan: true, all: [stale, actual])
        try await settled(coordinator)
        XCTAssertEqual(coordinator.results.map(\.id), [actual.id])
        XCTAssertEqual(coordinator.completeCount, 2)
        XCTAssertNil(coordinator.snippets[.init(stale)])
        XCTAssertEqual(coordinator.snippets[.init(actual)]?.match, "needle")
        XCTAssertEqual(store.hydrationCount, 0)
    }

    func testInstantRanksTitleThenTranscriptAndShowsAccentedIndexedPassage() async throws {
        let (db, cleanup) = try makeTestIndexDB(); defer { cleanup() }
        let weak = try row("newer-weak", text: "first hit", endTime: Date(timeIntervalSince1970: 200))
        let strong = try row("older-strong", text: "second hit", source: .codex, endTime: Date(timeIntervalSince1970: 100))
        let title = try row("title", text: "third hit")
        try await index(weak, in: db, text: String(repeating: "mostly unrelated text ", count: 70) + "Québec explains the weak hit")
        try await index(strong, in: db, text: "An important Québec match repeats Québec and Québec again")
        let coordinator = SearchCoordinator(store: VerificationStore(), db: db)
        var excerptCountAtFirstPublication: Int?
        let subscription = coordinator.$results.sink { [weak coordinator] results in
            if !results.isEmpty, excerptCountAtFirstPublication == nil {
                excerptCountAtFirstPublication = coordinator?.snippets.count
            }
        }
        defer { subscription.cancel() }
        coordinator.start(query: "quebec", filters: Filters(query: "quebec"), allowed: [.claude, .codex],
                          enableDeepScan: false, all: [weak, strong, title],
                          effectiveDisplayTitles: [.init(title): "Québec live title"])
        try await settled(coordinator, excerpts: [weak, strong])

        XCTAssertEqual(excerptCountAtFirstPublication, 0)
        XCTAssertTrue(coordinator.usesRelevanceOrder)
        XCTAssertEqual(coordinator.results.map(\.id), [title.id, strong.id, weak.id])
        XCTAssertEqual(coordinator.snippets[.init(weak)]?.match, "Québec")
        XCTAssertTrue(coordinator.snippets[.init(weak)]?.text.contains("weak hit") == true)
        XCTAssertNil(coordinator.snippets[.init(title)])
    }

    func testReturnReplacesIndexedExcerptWithoutChangingMembership() async throws {
        let (db, cleanup) = try makeTestIndexDB(); defer { cleanup() }
        let row = try row("passage", text: "needle appears in verified passage")
        try await index(row, in: db, text: "needle appears in sampled passage")
        let coordinator = SearchCoordinator(store: VerificationStore(), db: db)
        for deep in [false, true] {
            coordinator.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude],
                              enableDeepScan: deep, all: [row])
            try await settled(coordinator, excerpts: [row])
            XCTAssertEqual(coordinator.results.map(\.id), [row.id])
            let expected = deep ? "verified passage" : "sampled passage"
            XCTAssertTrue(coordinator.snippets[.init(row)]?.text.contains(expected) == true)
        }
    }

    private func index(_ row: Session, in db: IndexDB, text: String) async throws {
        let source = row.source.rawValue
        try await db.upsertSessionMeta(.init(sessionID: row.id, source: source, path: row.filePath,
            mtime: 1, size: 1, startTS: 1, endTS: 1, model: nil, cwd: nil, repo: nil, title: "Fixture",
            codexInternalSessionID: nil, isHousekeeping: false, messages: 1, commands: 0,
            parentSessionID: nil, subagentType: nil, customTitle: nil))
        try await db.upsertFile(path: row.filePath, mtime: 1, size: 1, source: source)
        try await db.upsertSessionSearch(sessionID: row.id, source: source, mtime: 1, size: 1, text: text)
    }

    func testExactIdentityMatchesOnlyOwnSourceQualifiedIdentityWithoutSourceScan() async throws {
        let a = try row("same", text: "a"), b = try row("same", text: "b", source: .codex)
        let store = VerificationStore()
        let coordinator = SearchCoordinator(store: store, db: nil)
        coordinator.start(query: "same", filters: Filters(query: "same"), allowed: [.claude, .codex], enableDeepScan: true, all: [a, b])
        try await settled(coordinator)
        XCTAssertEqual(Set(coordinator.results.map(SearchCoordinator.SessionKey.init)), Set([a, b].map(SearchCoordinator.SessionKey.init)))
        XCTAssertFalse(coordinator.usesRelevanceOrder)
        XCTAssertTrue(store.scans.isEmpty)
    }

    func testMalformedSourceCannotVerifyNegativeAndClearDiscardsCoverage() async throws {
        let input = try row("partial", text: "alpha")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: input.filePath))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\": }\n".utf8)); try handle.close()
        let coordinator = SearchCoordinator(store: VerificationStore(), db: nil)
        coordinator.start(query: "alpha NOT beta", filters: Filters(query: "alpha NOT beta"), allowed: [.claude], enableDeepScan: true, all: [input])
        try await settled(coordinator)
        XCTAssertEqual(coordinator.incompleteCount, 1)
        XCTAssertEqual(coordinator.unresolvedCount, 1)
        XCTAssertTrue(coordinator.verifiedKeys.isEmpty)
        coordinator.clear()
        await Task.yield()
        XCTAssertEqual(coordinator.eligibleCount, 0)
        XCTAssertTrue(coordinator.verifiedKeys.isEmpty)
        XCTAssertTrue(coordinator.snippets.isEmpty)
        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertFalse(coordinator.wasCanceled)
    }

    func testAppDeactivationDoesNotRelabelSettledSearchAsCanceled() async throws {
        let input = try row("settled", text: "needle")
        let coordinator = SearchCoordinator(store: VerificationStore(), db: nil)
        coordinator.start(query: "needle", filters: Filters(query: "needle"),
                          allowed: [.claude], enableDeepScan: true, all: [input])
        try await settled(coordinator)
        XCTAssertEqual(coordinator.results.map(\.id), [input.id])
        XCTAssertEqual(coordinator.verifiedKeys.count, 1)
        XCTAssertFalse(coordinator.wasCanceled)

        coordinator.setAppActive(false)
        await Task.yield()

        XCTAssertEqual(coordinator.results.map(\.id), [input.id])
        XCTAssertEqual(coordinator.verifiedKeys.count, 1)
        XCTAssertFalse(coordinator.wasCanceled)

        coordinator.clear()
        coordinator.setAppActive(false)

        XCTAssertTrue(coordinator.results.isEmpty)
        XCTAssertTrue(coordinator.verifiedKeys.isEmpty)
        XCTAssertTrue(coordinator.snippets.isEmpty)
        XCTAssertFalse(coordinator.wasCanceled)
    }
}
