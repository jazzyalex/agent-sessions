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

    private func scratchRepairDefaults(generation: Int? = nil) -> UserDefaults {
        let name = "AntigravityRootOverrideRepair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if let generation {
            defaults.set(generation, forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey)
        }
        return defaults
    }

    /// Every refresh in this class runs against a scratch parser-repair defaults
    /// suite that is already at the current generation, and a no-op row writer. The
    /// one-time Antigravity repair therefore never forces a reparse here, and it can
    /// never reach the real index database or `UserDefaults.standard`.
    private func makeIndexer() -> AntigravitySessionIndexer {
        let indexer = AntigravitySessionIndexer()
        indexer.parserRepairDefaultsOverride = scratchRepairDefaults(
            generation: AntigravitySessionIndexer.parserGeneration)
        indexer.persistSessionMetaOverride = { (_: SessionMetaRow) async throws in }
        return indexer
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

        let indexer = makeIndexer()

        XCTAssertTrue(indexer.canAccessRootDirectory,
                      "indexer ignored the override and scanned the default root instead of \(root.path)")
    }

    func testIndexerReportsAMissingCustomRootAsUnreadable() {
        let absent = missingRootPath()
        UserDefaults.standard.set(absent, forKey: overrideKey)

        let indexer = makeIndexer()

        XCTAssertFalse(indexer.canAccessRootDirectory,
                       "indexer fell back to the default root; a custom path that does not exist must read as unreadable")
    }

    /// Changing the preference after launch must re-point discovery, otherwise
    /// the setting only takes effect on the next app start.
    func testRefreshPicksUpAnOverrideChangedAfterInit() async throws {
        UserDefaults.standard.set(missingRootPath(), forKey: overrideKey)
        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

        let indexer = makeIndexer()
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

    // MARK: - One-time parser repair (call-site wiring)

    private final class SessionMetaRowCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [SessionMetaRow] = []
        func capture(_ row: SessionMetaRow) {
            lock.lock()
            defer { lock.unlock() }
            rows.append(row)
        }
        var snapshot: [SessionMetaRow] {
            lock.lock()
            defer { lock.unlock() }
            return rows
        }
    }

    /// A hydrated CLI row whose file is unchanged on disk is normally skipped, so an
    /// older parser's model would survive forever. The first refresh below the parser
    /// generation must reparse it, write the corrected row, and advance the
    /// generation; the next refresh must skip the unchanged file again.
    func testHydratedRefreshRepairsAStaleModelOnceAndWritesTheRow() async throws {
        let (root, conversation) = try makeTempBrainConversation()
        let logs = conversation.appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("transcript.jsonl")
        let transcript = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:21:00Z","content":"<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it.\n</USER_SETTINGS_CHANGE>"}"#
        try (transcript + "\n").write(to: url, atomically: true, encoding: .utf8)
        // Pin the file mtime to the session's last record so the cached row's
        // (mtime, size) equals the file's, and only a forced reparse reaches it.
        let lastRecord = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T20:21:00Z"))
        try FileManager.default.setAttributes([.modificationDate: lastRecord], ofItemAtPath: url.path)

        let parsed = try XCTUnwrap(AntigravitySessionParser.parseFile(at: url))
        XCTAssertEqual(parsed.model, "Gemini 3.5 Flash (Medium)")
        let staleModel = "Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it."
        let stale = Session(id: parsed.id,
                            source: .antigravity,
                            startTime: parsed.startTime,
                            endTime: parsed.endTime,
                            model: staleModel,
                            filePath: parsed.filePath,
                            fileSizeBytes: parsed.fileSizeBytes,
                            eventCount: parsed.eventCount,
                            events: [],
                            cwd: nil,
                            repoName: nil,
                            lightweightTitle: parsed.lightweightTitle)

        let defaults = scratchRepairDefaults()
        let writes = SessionMetaRowCapture()
        let parses = HydrationParsedRecorder()
        let indexer = AntigravitySessionIndexer()
        indexer.parserRepairDefaultsOverride = defaults
        indexer.persistSessionMetaOverride = { (row: SessionMetaRow) async throws in writes.capture(row) }
        indexer.hydrateOverride = { [stale] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [url], roots: [root]) }
        indexer.deletePersistedPathsOverride = { (_: [String]) async throws in return }
        indexer.parseLightweightOverride = { url in
            parses.record(url)
            return AntigravitySessionParser.parseFile(at: url)
        }

        indexer.refresh(mode: .incremental, trigger: .manual)
        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertEqual(parses.snapshot.count, 1, "the forced repair must reparse the unchanged file")
        XCTAssertEqual(writes.snapshot.map(\.sessionID), [stale.id])
        XCTAssertEqual(writes.snapshot.first?.model, "Gemini 3.5 Flash (Medium)")
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey),
                       AntigravitySessionIndexer.parserGeneration)
        XCTAssertEqual(indexer.allSessions.first { $0.id == stale.id }?.model, "Gemini 3.5 Flash (Medium)")

        // The repair is one-time: the next refresh sees the current generation and
        // skips the unchanged file without writing.
        indexer.refresh(mode: .incremental, trigger: .manual)
        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "second hydration did not finish promptly")
        XCTAssertEqual(parses.snapshot.count, 1, "an unchanged file must not be reparsed after the repair")
        XCTAssertEqual(writes.snapshot.count, 1)
    }

    /// A CLI transcript that never parses makes every forced pass incomplete. The
    /// forced reparse must then run once per launch, not on every refresh (the
    /// monitor refreshes per agent turn); the generation stays unrecorded so the
    /// next launch retries.
    func testForcedRepairRunsOncePerLaunchWhenATranscriptStaysUnparseable() async throws {
        let (root, goodConversation) = try makeTempBrainConversation()
        let badConversation = root.appendingPathComponent("conversation-bad-\(UUID().uuidString)", isDirectory: true)
        let lastRecord = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T20:21:00Z"))

        func writeTranscript(in conversation: URL, _ text: String) throws -> URL {
            let logs = conversation.appendingPathComponent(".system_generated/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("transcript.jsonl")
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            // Pin mtime to the cached row's last-record time so only a forced pass
            // reparses these files.
            try FileManager.default.setAttributes([.modificationDate: lastRecord], ofItemAtPath: url.path)
            return url
        }
        let goodURL = try writeTranscript(in: goodConversation, #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:21:00Z","content":"<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>"}"#)
        // No `step_index`: the transcript parser rejects it on every attempt.
        let badURL = try writeTranscript(in: badConversation, #"{"type":"USER_INPUT","content":"x"}"#)
        XCTAssertNil(AntigravitySessionParser.parseFile(at: badURL))

        func cachedRow(id: String, url: URL) throws -> Session {
            let size = try XCTUnwrap(
                (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
            return Session(id: id, source: .antigravity, startTime: lastRecord, endTime: lastRecord,
                           model: "Gemini 3.5 Flash (Medium). No need to comment on this change.",
                           filePath: url.path, fileSizeBytes: size, eventCount: 1, events: [],
                           cwd: nil, repoName: nil, lightweightTitle: "Go")
        }
        let good = try cachedRow(id: goodConversation.lastPathComponent, url: goodURL)
        let bad = try cachedRow(id: badConversation.lastPathComponent, url: badURL)

        let defaults = scratchRepairDefaults()
        let writes = SessionMetaRowCapture()
        let parses = HydrationParsedRecorder()
        let indexer = AntigravitySessionIndexer()
        indexer.parserRepairDefaultsOverride = defaults
        indexer.persistSessionMetaOverride = { (row: SessionMetaRow) async throws in writes.capture(row) }
        indexer.hydrateOverride = { [good, bad] }
        indexer.discoverSnapshotOverride = { self.makeHydrationSnapshot(files: [goodURL, badURL], roots: [root]) }
        indexer.deletePersistedPathsOverride = { (_: [String]) async throws in return }
        indexer.parseLightweightOverride = { url in
            parses.record(url)
            return AntigravitySessionParser.parseFile(at: url)
        }

        indexer.refresh(mode: .incremental, trigger: .manual)
        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "hydration did not finish promptly")
        XCTAssertEqual(Set(parses.snapshot),
                       Set([goodURL, badURL].map { AntigravitySessionDiscovery.normalizedPath($0.path) }),
                       "the first refresh must force a reparse of every CLI row")
        XCTAssertTrue(writes.snapshot.isEmpty, "an incomplete pass writes nothing")
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0)

        indexer.refresh(mode: .incremental, trigger: .manual)
        await waitForHydrationReady(indexer)
        XCTAssertEqual(indexer.launchPhase, .ready, "second hydration did not finish promptly")
        XCTAssertEqual(parses.snapshot.count, 2, "a later refresh in the same launch must not force again")
        XCTAssertTrue(writes.snapshot.isEmpty)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0,
                       "the next launch must retry")
    }
}
