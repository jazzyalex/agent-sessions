import XCTest
@testable import AgentSessions

/// One-time repair of Antigravity `session_meta` rows written by an older
/// `AntigravityTranscriptParser`. Hydrated rows are skipped while mtime and
/// size are unchanged, and `reconcileHydratedSessions` corrects them only in
/// memory, so the repair must force a reparse, write every reparsed row, and
/// record the parser generation only after the whole pass succeeded.
///
/// Every test uses a scratch database and a scratch `UserDefaults` suite.
final class AntigravityIndexRepairTests: XCTestCase {
    private static let sessionDate = Date(timeIntervalSince1970: 1_791_145_294)
    private static let sessionSize = 1_234
    private static let staleModel =
        "Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it."

    private func scratchDefaults() -> UserDefaults {
        let name = "AntigravityRepair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func antigravitySession(id: String, path: String, model: String?) -> Session {
        // Same initializer AntigravityTranscriptParser.parse uses.
        Session(id: id,
                source: .antigravity,
                startTime: Self.sessionDate,
                endTime: Self.sessionDate,
                model: model,
                filePath: path,
                fileSizeBytes: Self.sessionSize,
                eventCount: 3,
                events: [],
                cwd: nil,
                repoName: nil,
                lightweightTitle: "Go")
    }

    /// One hydrated CLI row whose current file stat equals the cached stat, so an
    /// unforced reconcile skips it.
    private struct ReconcileFixture {
        let root: URL
        let url: URL
        let hydrated: Session
        let fixed: Session
        let snapshot: AntigravitySessionDiscovery.DiscoverySnapshot
        let unchangedStat: SessionFileStat
    }

    private func reconcileFixture() -> ReconcileFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-repair-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("ag-r/.system_generated/logs/transcript.jsonl")
        let hydrated = antigravitySession(id: "ag-r", path: url.path, model: Self.staleModel)
        let fixed = antigravitySession(id: "ag-r", path: url.path, model: "Gemini 3.5 Flash (Medium)")
        return ReconcileFixture(
            root: root,
            url: url,
            hydrated: hydrated,
            fixed: fixed,
            snapshot: .init(files: [url], authoritativeRoots: [root]),
            unchangedStat: SessionFileStat(mtime: Int64(Self.sessionDate.timeIntervalSince1970),
                                           size: Int64(Self.sessionSize)))
    }

    /// The repair must reach the database, not only memory.
    func testParserRepairWritesTheCorrectedModelAndAdvancesTheGeneration() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let stale = antigravitySession(
            id: "ag-1", path: "/tmp/ag-1/transcript.jsonl",
            model: "Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it.")
        try await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: stale))

        let fixed = antigravitySession(id: "ag-1", path: "/tmp/ag-1/transcript.jsonl",
                                       model: "Gemini 3.5 Flash (Medium)")
        let defaults = scratchDefaults()
        let advanced = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: true, defaults: defaults,
            write: { try await db.upsertSessionMetaCore($0) })

        XCTAssertTrue(advanced)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey),
                       AntigravitySessionIndexer.parserGeneration)
        // Read back through the repository the app hydrates from.
        let stored = try await SessionMetaRepository(db: db).fetchSessions(for: .antigravity)
        XCTAssertEqual(stored.first { $0.id == "ag-1" }?.model, "Gemini 3.5 Flash (Medium)")
    }

    func testParserRepairDoesNotAdvanceWhenAWriteFails() async {
        struct WriteFailed: Error {}
        let defaults = scratchDefaults()
        let fixed = antigravitySession(id: "ag-2", path: "/tmp/ag-2/transcript.jsonl", model: "X")
        let advanced = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: true, defaults: defaults,
            write: { _ in throw WriteFailed() })
        XCTAssertFalse(advanced)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0)
    }

    func testParserRepairDoesNotAdvanceWhenThePassWasCancelledOrIncomplete() async {
        let defaults = scratchDefaults()
        let fixed = antigravitySession(id: "ag-3", path: "/tmp/ag-3/transcript.jsonl", model: "X")
        var writes = 0
        let incomplete = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: false, defaults: defaults, write: { _ in writes += 1 })
        XCTAssertFalse(incomplete)
        XCTAssertEqual(writes, 0, "an incomplete pass writes nothing and is retried whole")

        let cancelled = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed, fixed], completed: true, defaults: defaults,
            shouldContinue: { writes < 1 }, write: { _ in writes += 1 })
        XCTAssertFalse(cancelled)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0)
    }

    func testForcedReconcileReparsesUnchangedFilesAndReportsThem() throws {
        let f = reconcileFixture()
        var parses = 0
        let parseNew: (URL) -> Session? = { _ in parses += 1; return f.fixed }

        let unforced = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: f.snapshot, parseNew: parseNew,
            currentStat: { _ in f.unchangedStat }, forceReparse: false)
        XCTAssertTrue(unforced.reparsed.isEmpty, "unchanged mtime and size skip the reparse")
        XCTAssertTrue(unforced.completed)
        XCTAssertEqual(parses, 0)
        XCTAssertEqual(unforced.sessions.first?.model, Self.staleModel)

        let forced = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: f.snapshot, parseNew: parseNew,
            currentStat: { _ in f.unchangedStat }, forceReparse: true)
        XCTAssertEqual(forced.reparsed.count, 1)
        XCTAssertEqual(forced.reparsed.first?.model, "Gemini 3.5 Flash (Medium)")
        XCTAssertTrue(forced.completed)
        XCTAssertEqual(forced.sessions.first?.model, "Gemini 3.5 Flash (Medium)")

        let stopped = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: f.snapshot, parseNew: parseNew,
            currentStat: { _ in f.unchangedStat }, forceReparse: true,
            shouldContinue: { false })
        XCTAssertFalse(stopped.completed)
    }

    /// The repair targets CLI transcripts only. Markdown rows always store a nil
    /// model, so they are never force-reparsed and can never block the repair, even
    /// when their brain directory is gone and they stay non-authoritative forever.
    func testForcedReconcileTargetsOnlyCLITranscripts() throws {
        let f = reconcileFixture()
        let orphanMarkdown = antigravitySession(
            id: "md-orphan", path: "/nonexistent-antigravity-brain/conv-old/task.md", model: nil)
        let rootMarkdownURL = f.root.appendingPathComponent("conv-md/task.md")
        let rootMarkdown = antigravitySession(id: "md-root", path: rootMarkdownURL.path, model: nil)
        let snapshot = AntigravitySessionDiscovery.DiscoverySnapshot(
            files: [f.url, rootMarkdownURL], authoritativeRoots: [f.root])
        XCTAssertFalse(snapshot.isAuthoritative(path: orphanMarkdown.filePath))

        var parsedPaths: [String] = []
        let result = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated, orphanMarkdown, rootMarkdown],
            snapshot: snapshot,
            parseNew: { url in
                parsedPaths.append(url.path)
                return url.pathExtension == "jsonl" ? f.fixed : rootMarkdown
            },
            currentStat: { _ in f.unchangedStat },
            forceReparse: true)

        XCTAssertTrue(result.completed, "rows the repair does not target must not block it")
        XCTAssertEqual(result.reparsed.map(\.id), [f.hydrated.id])
        XCTAssertEqual(parsedPaths, [f.url.path], "an unchanged markdown row must not be reparsed")
        XCTAssertTrue(result.sessions.contains { $0.id == orphanMarkdown.id }, "orphan rows are kept as before")
    }

    func testForcedReconcileIsIncompleteWhenAHydratedRowCannotBeRepaired() async throws {
        let f = reconcileFixture()
        let unstattable = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: f.snapshot, parseNew: { _ in f.fixed },
            currentStat: { _ in nil }, forceReparse: true)

        let partialSnapshot = AntigravitySessionDiscovery.DiscoverySnapshot(files: [f.url], authoritativeRoots: [])
        XCTAssertFalse(partialSnapshot.isAuthoritative(path: f.hydrated.filePath))
        let nonAuthoritative = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: partialSnapshot,
            parseNew: { _ in f.fixed },
            currentStat: { _ in f.unchangedStat }, forceReparse: true)

        // The root was not scanned at all, so the file loop never reaches the row.
        let unscannedRoot = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated],
            snapshot: .init(files: [], authoritativeRoots: []),
            parseNew: { _ in f.fixed },
            currentStat: { _ in f.unchangedStat }, forceReparse: true)

        let unparseable = AntigravitySessionIndexer.reconcileHydratedSessions(
            hydrated: [f.hydrated], snapshot: f.snapshot, parseNew: { _ in nil },
            currentStat: { _ in f.unchangedStat }, forceReparse: true)

        for (label, result) in [("unstattable", unstattable),
                                ("non-authoritative", nonAuthoritative),
                                ("unscanned root", unscannedRoot),
                                ("unparseable", unparseable)] {
            XCTAssertFalse(result.completed, label)
            let defaults = scratchDefaults()
            var writes = 0
            let advanced = await AntigravitySessionIndexer.persistParserRepair(
                reparsed: result.reparsed, completed: result.completed, defaults: defaults,
                write: { _ in writes += 1 })
            XCTAssertFalse(advanced, label)
            XCTAssertEqual(writes, 0, label)
            XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0, label)
        }
    }
}
