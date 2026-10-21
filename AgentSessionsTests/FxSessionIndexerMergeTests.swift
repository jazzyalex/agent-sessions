import XCTest
@testable import AgentSessions

/// Guide §3.1 regression: a successful full reload is authoritative for every
/// branch-derived field. fx has no branches, but compaction rewrites
/// `state.history` in place — so the reloaded transcript can be *shorter* than
/// the row it replaces and carry a different title. Merging those fields with
/// `max` or current-first fallbacks would keep discarded history's metadata
/// beside the newly parsed transcript.
final class FxSessionIndexerMergeTests: XCTestCase {
    private func makeSession(eventCount: Int,
                             title: String?,
                             commands: Int?,
                             startTime: Date? = Date(timeIntervalSince1970: 100),
                             model: String? = "demo/model-1") -> Session {
        // `nonMetaCount` derives from the rendered events, so the fixture
        // carries one non-meta event per claimed count.
        let events = (0..<eventCount).map {
            SessionEvent(id: "\($0)", timestamp: nil, kind: .user, role: "user", text: nil,
                         toolName: nil, toolInput: nil, toolOutput: nil,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "")
        }
        return Session(id: "fx-session",
                       source: .fx,
                       startTime: startTime,
                       endTime: Date(timeIntervalSince1970: 200),
                       model: model,
                       filePath: "/tmp/fx/fx-session/checkpoint.json",
                       eventCount: eventCount,
                       events: events,
                       cwd: "/tmp/alpha",
                       repoName: "alpha",
                       lightweightTitle: title,
                       lightweightCommands: commands)
    }

    private final class ReloadAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for fx indexer", file: file, line: line)
    }

    /// Success -> transient read failure -> file disappearance. Only the last
    /// step may remove the previously visible row.
    @MainActor
    func testTwoRefreshesPreserveLastGoodSessionWhenParseFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.jsonl")
        try Data("existing discovered file".utf8).write(to: url)
        let good = Session(id: "fx-good", source: .fx,
                           startTime: nil, endTime: Date(timeIntervalSince1970: 200),
                           model: nil, filePath: url.path, eventCount: 5, events: [],
                           cwd: nil, repoName: nil, lightweightTitle: "Last good title")
        let indexer = FxSessionIndexer()
        indexer.discoverFilesOverride = { [url] }
        indexer.parseLightweightOverride = { _ in good }
        indexer.refresh()
        try await waitUntil { !indexer.isIndexing }
        XCTAssertEqual(indexer.allSessions.map(\.id), ["fx-good"])

        indexer.parseLightweightOverride = { _ in nil }
        indexer.refresh()
        try await waitUntil { !indexer.isIndexing }
        XCTAssertEqual(indexer.allSessions.map(\.id), ["fx-good"])
        XCTAssertEqual(indexer.allSessions.first?.lightweightTitle, "Last good title")

        try FileManager.default.removeItem(at: url)
        indexer.discoverFilesOverride = { [] }
        indexer.refresh()
        try await waitUntil { !indexer.isIndexing }
        XCTAssertTrue(indexer.allSessions.isEmpty, "only authoritative absence removes the session")
    }

    /// A failed full parse must not update the file stat gate: the next forced
    /// monitor reload of the same revision must retry without any new file edit.
    @MainActor
    func testFailedFullReloadDoesNotPoisonStatGate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FxReload-\(UUID().uuidString).jsonl")
        try Data("same file revision".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let existing = Session(id: "fx-reload", source: .fx,
                               startTime: nil, endTime: nil, model: nil,
                               filePath: url.path, eventCount: 4,
                               events: [SessionEvent(id: "1", timestamp: nil, kind: .user, role: "user",
                                                     text: "old", toolName: nil, toolInput: nil,
                                                     toolOutput: nil, messageID: nil, parentID: nil,
                                                     isDelta: false, rawJSON: "")],
                               cwd: nil, repoName: nil, lightweightTitle: "Old")
        let updated = Session(id: existing.id, source: .fx,
                              startTime: nil, endTime: nil, model: nil,
                              filePath: url.path, eventCount: 1,
                              events: existing.events, cwd: nil, repoName: nil,
                              lightweightTitle: "Reloaded")
        let indexer = FxSessionIndexer()
        indexer.seedSessionsForTesting([existing])
        let attempts = ReloadAttempts()
        indexer.parseFullOverride = { _ in
            attempts.next() == 1 ? nil : updated
        }
        indexer.reloadSession(id: existing.id, force: true, reason: .focusedSessionMonitor)
        try await waitUntil { !indexer.isReloadingForTesting(existing.id) }
        indexer.reloadSession(id: existing.id, force: true, reason: .focusedSessionMonitor)
        try await waitUntil { !indexer.isReloadingForTesting(existing.id)
                              && indexer.allSessions.first?.lightweightTitle == "Reloaded" }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(indexer.allSessions.first?.lightweightTitle, "Reloaded")
    }

    /// Compaction shrank the transcript: the reloaded count must shrink with
    /// it, not ride `max` on the pre-compaction row.
    func testCompactedReloadShrinksEventCount() {
        let current = makeSession(eventCount: 40, title: "Pre-compaction title", commands: 12)
        let parsed = makeSession(eventCount: 6, title: "Post-compaction summary", commands: 1)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertEqual(merged.eventCount, 6)
    }

    /// A changed title follows the fresh parse; only a parse that could not
    /// produce one keeps the old row's.
    func testReloadTakesFreshTitleOverStaleTitle() {
        let current = makeSession(eventCount: 40, title: "Old first prompt", commands: nil)
        let renamed = makeSession(eventCount: 6, title: "New display.json title", commands: nil)
        XCTAssertEqual(FxSessionIndexer.mergedSession(parsed: renamed, current: current).lightweightTitle,
                       "New display.json title")

        let untitled = makeSession(eventCount: 6, title: nil, commands: nil)
        XCTAssertEqual(FxSessionIndexer.mergedSession(parsed: untitled, current: current).lightweightTitle,
                       "Old first prompt")
    }

    /// If compaction removed every tool turn, the fresh "command-free" verdict
    /// wins over the discarded history's command count.
    func testReloadDoesNotKeepDiscardedHistoryCommandCount() {
        let current = makeSession(eventCount: 40, title: nil, commands: 12)
        let parsed = makeSession(eventCount: 2, title: nil, commands: nil)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertNil(merged.lightweightCommands)
    }

    /// Values neither the checkpoint nor the reread sidecar carries survive a
    /// reload from the old row instead of being blanked.
    func testSidecarOnlyFactsSurviveAParseThatLostThem() {
        let current = makeSession(eventCount: 40, title: "Kept", commands: 3)
        let parsed = makeSession(eventCount: 4, title: "Kept", commands: 1,
                                 startTime: nil, model: nil)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertNotNil(merged.startTime)
        XCTAssertEqual(merged.model, "demo/model-1")
    }
}
