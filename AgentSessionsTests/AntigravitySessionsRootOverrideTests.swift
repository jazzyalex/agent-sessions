import XCTest
@testable import AgentSessions

/// The Antigravity sessions-root override reached availability
/// (`AntigravitySourceDescriptor`), presence (`PresenceEngine`) and archive
/// backfill, but never the indexer — which built its discovery with no
/// arguments and so always scanned the default root. A custom path therefore
/// made the agent look available at that path while listing nothing from it,
/// which is worse than ignoring the setting outright.
///
/// The indexer assertions deliberately check both directions. A machine that
/// happens to have a real `~/.gemini/antigravity/brain` would pass the
/// "custom root is readable" case even unwired, and a machine without one
/// would pass the "missing root is unreadable" case even unwired; only a
/// wired indexer satisfies both.
@MainActor
final class AntigravitySessionsRootOverrideTests: XCTestCase {

    private let overrideKey = PreferencesKey.Paths.antigravitySessionsRootOverride
    /// `refresh()` returns before touching discovery when the agent is off, and
    /// tests share `UserDefaults.standard` with the developer's own settings —
    /// so this must be forced on, and it is the enablement key the registry
    /// reads (`AgentEnabledAntigravity`), not `IncludeAntigravitySessions`.
    private let enabledKey = PreferencesKey.Agents.antigravityEnabled

    private var savedOverride: Any?
    private var savedEnabled: Any?
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        savedOverride = UserDefaults.standard.object(forKey: overrideKey)
        savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    override func tearDown() {
        restore(savedOverride, forKey: overrideKey)
        restore(savedEnabled, forKey: enabledKey)
        for url in tempRoots { try? FileManager.default.removeItem(at: url) }
        tempRoots = []
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A brain root in the real on-disk shape: `<root>/<conversation-id>/<artifact>.md`.
    private func makeBrainRoot(artifact: String, function: String = #function) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRootOverride.\(function).\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conversation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        try "# walkthrough\n".write(to: conversation.appendingPathComponent(artifact), atomically: true, encoding: .utf8)
        tempRoots.append(root)
        return root
    }

    private func missingRootPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRootOverride.absent.\(UUID().uuidString)", isDirectory: true)
            .path
    }

    // MARK: - Discovery contract

    /// The plumbing target: a custom root changes which files are discovered.
    func testCustomRootChangesTheDiscoveredFileSet() throws {
        let rootA = try makeBrainRoot(artifact: "alpha.md")
        let rootB = try makeBrainRoot(artifact: "beta.md")

        // `cliRoot` is pinned to an absent directory on purpose. Without it this
        // test picks up the developer's real `~/.gemini/antigravity-cli/brain`,
        // which is itself the finding: the single override moves the markdown
        // brain store only, and CLI transcripts keep coming from the default
        // location. The Preferences copy now says so.
        let absentCLI = missingRootPath()
        let fromA = AntigravitySessionDiscovery(customRoot: rootA.path, cliRoot: absentCLI).discoverSessionFiles()
        let fromB = AntigravitySessionDiscovery(customRoot: rootB.path, cliRoot: absentCLI).discoverSessionFiles()

        XCTAssertEqual(fromA.map(\.lastPathComponent), ["alpha.md"])
        XCTAssertEqual(fromB.map(\.lastPathComponent), ["beta.md"])
        XCTAssertNotEqual(fromA, fromB, "a different custom root must yield a different file set")
    }

    /// An empty override string means "use the default", never "use the empty path".
    func testEmptyOverrideFallsBackToTheDefaultRoot() {
        let root = AntigravitySessionDiscovery(customRoot: "").sessionsRoot()
        XCTAssertEqual(root.path, NSHomeDirectory() + "/.gemini/antigravity/brain")
    }

    func testCLIDiscoveryConfirmedMissingTranscriptKeepsRootAuthoritative() throws {
        let cliRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityCLI.MissingTranscript.\(UUID().uuidString)", isDirectory: true)
        let conversation = cliRoot.appendingPathComponent("conversation-missing", isDirectory: true)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        tempRoots.append(cliRoot)

        let snapshot = AntigravitySessionDiscovery(
            customRoot: missingRootPath(),
            cliRoot: cliRoot.path
        ).discoverSnapshot()

        XCTAssertTrue(snapshot.files.isEmpty)
        XCTAssertTrue(
            snapshot.isAuthoritative(path: conversation.appendingPathComponent(".system_generated/logs/transcript.jsonl").path),
            "a confirmed absent transcript is a complete observation, not a root read failure"
        )
    }

    func testCLIDiscoveryPartialTranscriptProbeFailureIsNotAuthoritative() throws {
        let cliRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityCLI.PartialFailure.\(UUID().uuidString)", isDirectory: true)
        let readableConversation = cliRoot.appendingPathComponent("conversation-readable", isDirectory: true)
        let blockedConversation = cliRoot.appendingPathComponent("conversation-blocked", isDirectory: true)
        let readableTranscript = readableConversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
        let blockedTranscript = blockedConversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: readableTranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blockedTranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: readableTranscript, atomically: true, encoding: .utf8)
        try "{}\n".write(to: blockedTranscript, atomically: true, encoding: .utf8)
        tempRoots.append(cliRoot)

        let snapshot = AntigravitySessionDiscovery(
            customRoot: missingRootPath(),
            cliRoot: cliRoot.path,
            cliTranscriptProbe: { url in
                if url.path.contains("/conversation-blocked/") {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.Code.fileReadNoPermission.rawValue
                    )
                }
                return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
        ).discoverSnapshot()

        XCTAssertEqual(
            snapshot.files.map { $0.resolvingSymlinksInPath().path },
            [readableTranscript.resolvingSymlinksInPath().path]
        )
        XCTAssertFalse(
            snapshot.isAuthoritative(path: readableTranscript.path),
            "one indeterminate transcript subtree must make the CLI root non-authoritative"
        )
    }

    // MARK: - Indexer wiring (the regression)

    func testIndexerReadsTheCustomRootWhenTheOverrideIsSet() throws {
        let root = try makeBrainRoot(artifact: "alpha.md")
        UserDefaults.standard.set(root.path, forKey: overrideKey)

        let indexer = AntigravitySessionIndexer()

        XCTAssertTrue(indexer.canAccessRootDirectory,
                      "indexer ignored the override and scanned the default root instead of \(root.path)")
    }

    func testIndexerReportsAMissingCustomRootAsUnreadable() {
        let absent = missingRootPath()
        UserDefaults.standard.set(absent, forKey: overrideKey)

        let indexer = AntigravitySessionIndexer()

        XCTAssertFalse(indexer.canAccessRootDirectory,
                       "indexer fell back to the default root; a custom path that does not exist must read as unreadable")
    }

    /// Changing the preference after launch must re-point discovery, otherwise
    /// the setting only takes effect on the next app start.
    func testRefreshPicksUpAnOverrideChangedAfterInit() async throws {
        UserDefaults.standard.set(missingRootPath(), forKey: overrideKey)
        let indexer = AntigravitySessionIndexer()
        XCTAssertFalse(indexer.canAccessRootDirectory)

        let (root, conversation) = try makeTempBrainConversation()
        let alphaURL = try writeHydrationArtifact(in: conversation, named: "alpha.md")
        UserDefaults.standard.set(root.path, forKey: overrideKey)
        indexer.hydrateOverride = { nil }
        indexer.discoverSnapshotOverride = {
            AntigravitySessionDiscovery.DiscoverySnapshot(files: [alphaURL], authoritativeRoots: [root])
        }
        indexer.deletePersistedPathsOverride = { (_: [String]) async throws in return }
        indexer.refresh(mode: .fullReconcile, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertTrue(indexer.canAccessRootDirectory,
                      "refresh did not re-read the override, so a Preferences change needs an app restart")
        XCTAssertTrue(indexer.allSessions.contains(where: { $0.filePath.hasSuffix("alpha.md") }))
    }

    // MARK: - Hydration reconciliation (non-empty DB)

    private final class HydrationParsedRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            paths.append(URL(fileURLWithPath: url.path).standardized.path)
        }
        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private final class HydrationDeletionCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func capture(_ new: [String]) {
            lock.lock()
            defer { lock.unlock() }
            paths.append(contentsOf: new)
        }
        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private func makeHydrationSnapshot(files: [URL], roots: [URL]) -> AntigravitySessionDiscovery.DiscoverySnapshot {
        AntigravitySessionDiscovery.DiscoverySnapshot(files: files, authoritativeRoots: roots)
    }

    private func makeTempBrainConversation() throws -> (root: URL, conversation: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityHydration.\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conversation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        tempRoots.append(root)
        return (root, conversation)
    }

    private func writeHydrationArtifact(in conversation: URL, named name: String) throws -> URL {
        let url = conversation.appendingPathComponent(name)
        try "# walkthrough\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitForHydrationReady(
        _ indexer: AntigravitySessionIndexer,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while indexer.launchPhase != .ready {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testAntigravityHydrationReconcilesAddedAndDeletedFiles() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let oldURL = try writeHydrationArtifact(in: conversation, named: "old.md")
        let deletedURL = try writeHydrationArtifact(in: conversation, named: "deleted.md")
        guard let oldSession = AntigravitySessionParser.parseFile(at: oldURL) else {
            XCTFail("test artifact did not parse: \(oldURL.path)")
            return
        }
        guard let deletedSession = AntigravitySessionParser.parseFile(at: deletedURL) else {
            XCTFail("test artifact did not parse: \(deletedURL.path)")
            return
        }
        try FileManager.default.removeItem(at: deletedURL)
        let newURL = try writeHydrationArtifact(in: conversation, named: "new.md")

        let indexer = AntigravitySessionIndexer()
        let cached = [oldSession, deletedSession]
        indexer.hydrateOverride = { cached }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [oldURL, newURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        let sessions = indexer.allSessions
        XCTAssertEqual(sessions.count, 2, "expected retained old plus parsed new; deleted must be dropped")
        XCTAssertTrue(sessions.contains(where: { $0.id == oldSession.id }), "cached old session must survive")
        XCTAssertFalse(sessions.contains(where: { $0.id == deletedSession.id }), "deleted file must be dropped")
        XCTAssertTrue(sessions.contains(where: { $0.filePath.hasSuffix("new.md") }), "new disk file must be parsed")
        XCTAssertEqual(deletions.snapshot, [AntigravitySessionDiscovery.normalizedPath(deletedURL.path)])
    }

    func testNonemptyHydrationDoesNotReparseUnchangedSessions() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let oldURL = try writeHydrationArtifact(in: conversation, named: "old.md")
        let newURL = try writeHydrationArtifact(in: conversation, named: "new.md")
        guard let oldSession = AntigravitySessionParser.parseFile(at: oldURL) else {
            XCTFail("test artifact did not parse: \(oldURL.path)")
            return
        }

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [oldSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [oldURL, newURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        let recorder = HydrationParsedRecorder()
        indexer.parseLightweightOverride = { url in
            recorder.record(url)
            return AntigravitySessionParser.parseFile(at: url)
        }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        let sessions = indexer.allSessions
        XCTAssertEqual(sessions.count, 2)
        let parsed = recorder.snapshot
        let oldKey = URL(fileURLWithPath: oldURL.path).standardized.path
        let newKey = URL(fileURLWithPath: newURL.path).standardized.path
        XCTAssertFalse(parsed.contains(oldKey), "unchanged cached session must not be reparsed")
        XCTAssertTrue(parsed.contains(newKey), "new disk file must be parsed")
        XCTAssertTrue(sessions.contains(where: { $0.id == oldSession.id }))
        XCTAssertTrue(deletions.snapshot.isEmpty)
    }

    func testAntigravityHydrationPreservesCacheWhenNewFileIsUnparseable() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let oldURL = try writeHydrationArtifact(in: conversation, named: "old.md")
        let badURL = try writeHydrationArtifact(in: conversation, named: "bad.md")
        guard let oldSession = AntigravitySessionParser.parseFile(at: oldURL) else {
            XCTFail("test artifact did not parse: \(oldURL.path)")
            return
        }

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [oldSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [oldURL, badURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        indexer.parseLightweightOverride = { url in
            if url.lastPathComponent == "bad.md" { return nil }
            return AntigravitySessionParser.parseFile(at: url)
        }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        let sessions = indexer.allSessions
        XCTAssertTrue(sessions.contains(where: { $0.id == oldSession.id }),
                      "an unparseable new file must not remove unrelated cached rows")
        XCTAssertTrue(deletions.snapshot.isEmpty)
    }

    func testAntigravityHydrationEmptyCacheFallsBackToFullScan() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let aURL = try writeHydrationArtifact(in: conversation, named: "a.md")
        let bURL = try writeHydrationArtifact(in: conversation, named: "b.md")

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { nil }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [aURL, bURL], roots: [root]) }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "scan did not finish promptly")
        let sessions = indexer.allSessions
        XCTAssertEqual(sessions.count, 2, "empty cache must still full-scan the injected two URLs")
        XCTAssertTrue(sessions.contains(where: { $0.filePath.hasSuffix("a.md") }))
        XCTAssertTrue(sessions.contains(where: { $0.filePath.hasSuffix("b.md") }))
    }

    func testAntigravityHydrationReparsesChangedCachedFile() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let changingURL = try writeHydrationArtifact(in: conversation, named: "changing.md")
        let steadyURL = try writeHydrationArtifact(in: conversation, named: "steady.md")
        guard let changingCached = AntigravitySessionParser.parseFile(at: changingURL) else {
            XCTFail("test artifact did not parse: \(changingURL.path)")
            return
        }
        guard let steadyCached = AntigravitySessionParser.parseFile(at: steadyURL) else {
            XCTFail("test artifact did not parse: \(steadyURL.path)")
            return
        }
        let handle = try FileHandle(forWritingTo: changingURL)
        handle.seekToEndOfFile()
        handle.write(Data("\nchanged content padding to grow size substantially 1234567890\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: changingURL.path)
        guard let changingExpected = AntigravitySessionParser.parseFile(at: changingURL) else {
            XCTFail("changed artifact did not parse: \(changingURL.path)")
            return
        }
        XCTAssertNotEqual(changingExpected.fileSizeBytes, changingCached.fileSizeBytes, "fixture must actually change size")

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [changingCached, steadyCached] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [changingURL, steadyURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        let recorder = HydrationParsedRecorder()
        indexer.parseLightweightOverride = { url in
            recorder.record(url)
            return AntigravitySessionParser.parseFile(at: url)
        }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        let sessions = indexer.allSessions
        let parsed = recorder.snapshot
        let changingKey = URL(fileURLWithPath: changingURL.path).standardized.path
        let steadyKey = URL(fileURLWithPath: steadyURL.path).standardized.path
        XCTAssertTrue(parsed.contains(changingKey), "changed cached file must be reparsed")
        XCTAssertFalse(parsed.contains(steadyKey), "unchanged cached file must not be reparsed")
        guard let published = sessions.first(where: { $0.id == changingCached.id }) else {
            XCTFail("changed session id must survive reparse")
            return
        }
        XCTAssertEqual(published.fileSizeBytes, changingExpected.fileSizeBytes, "published row must carry updated size")
        XCTAssertTrue(deletions.snapshot.isEmpty)
    }

    func testAntigravityHydrationPreservesChangedCachedFileWhenReparseFails() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let changingURL = try writeHydrationArtifact(in: conversation, named: "changing.md")
        guard let cached = AntigravitySessionParser.parseFile(at: changingURL) else {
            XCTFail("test artifact did not parse: \(changingURL.path)")
            return
        }
        let handle = try FileHandle(forWritingTo: changingURL)
        handle.seekToEndOfFile()
        handle.write(Data("\nchanged content padding to force a different size 1234567890\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: changingURL.path
        )

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [cached] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [changingURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        let recorder = HydrationParsedRecorder()
        indexer.parseLightweightOverride = { url in
            recorder.record(url)
            return nil
        }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertEqual(recorder.snapshot, [AntigravitySessionDiscovery.normalizedPath(changingURL.path)])
        guard let published = indexer.allSessions.first(where: { $0.id == cached.id }) else {
            XCTFail("failed reparse must preserve the last-known-good cached row")
            return
        }
        XCTAssertEqual(published.fileSizeBytes, cached.fileSizeBytes)
        XCTAssertTrue(deletions.snapshot.isEmpty, "a changed but unreadable file is not a confirmed deletion")
    }

    func testNonemptyHydrationUnavailableRootPreservesCache() async throws {
        let (_, conversation) = try makeTempBrainConversation()
        let oldURL = try writeHydrationArtifact(in: conversation, named: "old.md")
        guard let oldSession = AntigravitySessionParser.parseFile(at: oldURL) else {
            XCTFail("test artifact did not parse: \(oldURL.path)")
            return
        }

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [oldSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [], roots: []) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertTrue(indexer.allSessions.contains(where: { $0.id == oldSession.id }), "unavailable roots must preserve cache")
        XCTAssertTrue(deletions.snapshot.isEmpty, "unavailable roots must capture no deletion")
    }

    func testNonemptyHydrationAuthoritativeEmptyRootDropsLiveRow() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let oldURL = try writeHydrationArtifact(in: conversation, named: "old.md")
        guard let oldSession = AntigravitySessionParser.parseFile(at: oldURL) else {
            XCTFail("test artifact did not parse: \(oldURL.path)")
            return
        }
        try FileManager.default.removeItem(at: oldURL)

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [oldSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertFalse(indexer.allSessions.contains(where: { $0.id == oldSession.id }), "authoritative empty root must drop the live row")
        XCTAssertEqual(deletions.snapshot, [AntigravitySessionDiscovery.normalizedPath(oldURL.path)])
    }

    func testNonemptyHydrationPreservesPinnedArchiveFallback() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let liveURL = try writeHydrationArtifact(in: conversation, named: "live.md")
        let archiveURL = try writeHydrationArtifact(in: conversation, named: "archive-source.md")
        guard let liveSession = AntigravitySessionParser.parseFile(at: liveURL) else {
            XCTFail("test artifact did not parse: \(liveURL.path)")
            return
        }
        guard let archiveSession = AntigravitySessionParser.parseFile(at: archiveURL) else {
            XCTFail("test artifact did not parse: \(archiveURL.path)")
            return
        }

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [liveSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [liveURL], roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        indexer.archiveMergeOverride = { sessions in sessions + [archiveSession] }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertTrue(indexer.allSessions.contains(where: { $0.id == liveSession.id }))
        XCTAssertTrue(indexer.allSessions.contains(where: { $0.id == archiveSession.id }), "archive merge seam must survive publish")
    }

    func testNonemptyHydrationCancellationStopsRemainingParses() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let seedURL = try writeHydrationArtifact(in: conversation, named: "seed.md")
        guard let seedSession = AntigravitySessionParser.parseFile(at: seedURL) else {
            XCTFail("test artifact did not parse: \(seedURL.path)")
            return
        }
        var extraURLs: [URL] = []
        for name in ["n1.md", "n2.md", "n3.md", "n4.md"] {
            extraURLs.append(try writeHydrationArtifact(in: conversation, named: name))
        }

        let indexer = AntigravitySessionIndexer()
        indexer.hydrateOverride = { [seedSession] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [seedURL] + extraURLs, roots: [root]) }
        let deletions = HydrationDeletionCapture()
        indexer.deletePersistedPathsOverride = { (paths: [String]) async throws in deletions.capture(paths) }
        let recorder = HydrationParsedRecorder()
        indexer.parseLightweightOverride = { url in
            recorder.record(url)
            return AntigravitySessionParser.parseFile(at: url)
        }
        indexer.reconciliationShouldContinueOverride = { false }
        indexer.refresh(mode: .incremental, trigger: .manual)

        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertTrue(recorder.snapshot.isEmpty, "cancelled reconciliation must not parse remaining URLs")
        XCTAssertTrue(indexer.allSessions.contains(where: { $0.id == seedSession.id }))
    }
}
