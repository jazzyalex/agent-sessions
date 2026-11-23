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
    private func row(_ id: String, text: String, source: SessionSource = .claude) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(id + ".jsonl")
        let record: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: path)
        return Session(id: id, source: source, startTime: nil, endTime: nil, model: nil, filePath: path.path,
            eventCount: 1, events: [], cwd: nil, repoName: nil, lightweightTitle: "Fixture")
    }
    private func settled(_ coordinator: SearchCoordinator) async throws {
        for _ in 0..<200 {
            if !coordinator.isRunning { return }
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
        for row in [stale, actual] {
            try await db.upsertSessionMeta(.init(sessionID: row.id, source: "claude", path: row.filePath,
                mtime: 1, size: 1, startTS: 1, endTS: 1, model: nil, cwd: nil, repo: nil, title: "Fixture",
                codexInternalSessionID: nil, isHousekeeping: false, messages: 1, commands: 0,
                parentSessionID: nil, subagentType: nil, customTitle: nil))
        }
        try await db.upsertSessionSearch(sessionID: stale.id, source: "claude", mtime: 1, size: 1, text: "needle")
        let store = VerificationStore()
        let coordinator = SearchCoordinator(store: store, db: db)
        coordinator.start(query: "needle", filters: Filters(query: "needle"), allowed: [.claude], enableDeepScan: true, all: [stale, actual])
        try await settled(coordinator)
        XCTAssertEqual(coordinator.results.map(\.id), [actual.id])
        XCTAssertEqual(coordinator.completeCount, 2)
        XCTAssertEqual(store.hydrationCount, 0)
    }

    func testExactIdentityMatchesOnlyOwnSourceQualifiedIdentityWithoutSourceScan() async throws {
        let a = try row("same", text: "a"), b = try row("same", text: "b", source: .codex)
        let store = VerificationStore()
        let coordinator = SearchCoordinator(store: store, db: nil)
        coordinator.start(query: "same", filters: Filters(query: "same"), allowed: [.claude, .codex], enableDeepScan: true, all: [a, b])
        try await settled(coordinator)
        XCTAssertEqual(Set(coordinator.results.map(SearchCoordinator.SessionKey.init)), Set([a, b].map(SearchCoordinator.SessionKey.init)))
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
