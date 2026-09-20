import Foundation
import XCTest
@testable import AgentSessions

final class DeepSeekHarnessArchiveTests: XCTestCase {
    private let fileManager = FileManager.default
    private let cwd = "/tmp/dsh-archive-contract"

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: root)
        }
        return root
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func validGenerationData(version: Int, id: String) throws -> Data {
        var data = try jsonLine([
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": 1_700_000_000_000,
            "cwd": cwd,
            "isSeeded": false,
            "delegationDepth": 0,
        ])
        data.append(try jsonLine([
            "type": "turn/start",
            "seq": 0,
            "time": 1_700_000_000_001,
            "data": ["turn": 1],
        ]))
        data.append(try jsonLine([
            "type": "step/start",
            "seq": 1,
            "time": 1_700_000_000_002,
            "data": ["turn": 1, "step": 1],
        ]))
        data.append(try jsonLine([
            "type": "user/message",
            "seq": 2,
            "time": 1_700_000_000_003,
            "surfaceOp": "append",
            "data": [
                "id": "user-1",
                "role": "user",
                "content": [["type": "text", "text": "archive contract"]],
                "source": ["kind": "user"],
            ],
        ]))
        return data
    }

    @discardableResult
    private func writeGeneration(
        root: URL,
        id: String,
        version: Int,
        compression: DeepSeekHarnessCompression = .plain,
        data: Data? = nil
    ) throws -> URL {
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: cwd,
            id: id,
            version: version,
            compression: compression
        )
        try write(data ?? Data("fixture-\(version)\n".utf8), to: url)
        return url
    }

    private func archiveCapability() throws -> ArchiveCapability {
        try XCTUnwrap(SessionSource.deepseekHarness.descriptor.archive)
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 10,
                           condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description)
    }

    func testArchiveUnitRootsAtExactSessionDirectoryAndSelectedFilename() throws {
        let root = try temporaryRoot("DeepSeekHarnessArchiveUnit")
        let id = "archive-unit"
        let primary = try writeGeneration(
            root: root,
            id: id,
            version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        let capability = try archiveCapability()
        let unit = try XCTUnwrap(capability.archiveUnit?(primary))

        XCTAssertEqual(unit.root.standardizedFileURL, primary.deletingLastPathComponent().standardizedFileURL)
        XCTAssertTrue(unit.isDirectory)
        XCTAssertEqual(unit.primaryRelativePath, "session.v2.jsonl")
    }

    func testManifestEntriesAreFlatCanonicalSameEncodingAndBoundedToSelectedGeneration() throws {
        let root = try temporaryRoot("DeepSeekHarnessManifest")
        let id = "manifest-entries"
        let generationZero = try writeGeneration(root: root, id: id, version: 0)
        let generationOne = try writeGeneration(root: root, id: id, version: 1)
        _ = try writeGeneration(root: root, id: id, version: 3)
        _ = try writeGeneration(root: root, id: id, version: 4)
        let sessionDirectory = generationOne.deletingLastPathComponent()
        let primary = sessionDirectory.appendingPathComponent("session.v3.jsonl")
        let oppositeEncoding = sessionDirectory.appendingPathComponent("session.v2.jsonl.zstd")
        try write(Data("opposite\n".utf8), to: oppositeEncoding)
        let symlink = sessionDirectory.appendingPathComponent("session.v2.jsonl")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: generationOne)
        try write(Data("unrelated\n".utf8), to: sessionDirectory.appendingPathComponent("notes.txt"))
        let nested = sessionDirectory.appendingPathComponent("nested", isDirectory: true)
        try write(Data("nested\n".utf8), to: nested.appendingPathComponent("session.v0.jsonl"))

        let capability = try archiveCapability()
        let manifestEntries = try XCTUnwrap(capability.manifestEntries)
        let expected = [generationZero.lastPathComponent, "session.v1.jsonl", primary.lastPathComponent].sorted()
        let first = try XCTUnwrap(manifestEntries(sessionDirectory, primary.lastPathComponent))
        let second = try XCTUnwrap(manifestEntries(sessionDirectory, primary.lastPathComponent))

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, first, "manifest ordering must be deterministic")
        XCTAssertEqual(first, first.sorted())
        XCTAssertFalse(first.contains(oppositeEncoding.lastPathComponent))
        XCTAssertFalse(first.contains(symlink.lastPathComponent))
        XCTAssertFalse(first.contains("nested/session.v0.jsonl"))
        XCTAssertFalse(first.contains("session.v4.jsonl"))
        XCTAssertFalse(first.contains("notes.txt"))
    }

    func testInvalidSymlinkNonregularAndMissingPrimariesFailClosed() throws {
        let root = try temporaryRoot("DeepSeekHarnessInvalidArchive")
        let capability = try archiveCapability()
        let manifestEntries = try XCTUnwrap(capability.manifestEntries)
        let archiveUnit = try XCTUnwrap(capability.archiveUnit)

        let missingDirectory = root.appendingPathComponent("missing", isDirectory: true)
        try fileManager.createDirectory(at: missingDirectory, withIntermediateDirectories: true)
        let missing = missingDirectory.appendingPathComponent("session.v1.jsonl")
        XCTAssertNil(archiveUnit(missing))
        XCTAssertNil(manifestEntries(missingDirectory, missing.lastPathComponent))

        let symlinkDirectory = root.appendingPathComponent("symlink", isDirectory: true)
        try fileManager.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let target = symlinkDirectory.appendingPathComponent("target.jsonl")
        try write(Data("target\n".utf8), to: target)
        let symlink = symlinkDirectory.appendingPathComponent("session.v1.jsonl")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertNil(archiveUnit(symlink))
        XCTAssertNil(manifestEntries(symlinkDirectory, symlink.lastPathComponent))

        let nonregularDirectory = root.appendingPathComponent("nonregular", isDirectory: true)
        try fileManager.createDirectory(at: nonregularDirectory, withIntermediateDirectories: true)
        let nonregular = nonregularDirectory.appendingPathComponent("session.v1.jsonl", isDirectory: true)
        try fileManager.createDirectory(at: nonregular, withIntermediateDirectories: true)
        XCTAssertNil(archiveUnit(nonregular))
        XCTAssertNil(manifestEntries(nonregularDirectory, nonregular.lastPathComponent))

        let unsupported = try writeGeneration(root: root, id: "unsupported", version: 4)
        XCTAssertNil(archiveUnit(unsupported))
        XCTAssertNil(manifestEntries(unsupported.deletingLastPathComponent(), unsupported.lastPathComponent))

        let validDirectory = root.appendingPathComponent("invalid-relative", isDirectory: true)
        try fileManager.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try write(Data("valid\n".utf8), to: validDirectory.appendingPathComponent("session.v1.jsonl"))
        XCTAssertNil(manifestEntries(validDirectory, "../session.v1.jsonl"))
    }

    func testArchiveSyncCopiesOnlyEligibleFilesPreservesPrimaryAndFullParses() throws {
        let upstreamRoot = try temporaryRoot("DeepSeekHarnessArchiveSyncUpstream")
        let appSupport = try temporaryRoot("DeepSeekHarnessArchiveSyncSupport")
        let id = "archive-sync"
        let primary = try writeGeneration(
            root: upstreamRoot,
            id: id,
            version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        _ = try writeGeneration(root: upstreamRoot, id: id, version: 0, data: Data("generation-zero\n".utf8))
        _ = try writeGeneration(root: upstreamRoot, id: id, version: 1, data: Data("generation-one\n".utf8))
        _ = try writeGeneration(root: upstreamRoot, id: id, version: 3, data: Data("future\n".utf8))
        _ = try writeGeneration(root: upstreamRoot, id: id, version: 1, compression: .zstd, data: Data("opposite\n".utf8))
        let sessionDirectory = primary.deletingLastPathComponent()
        try write(Data("unrelated\n".utf8), to: sessionDirectory.appendingPathComponent("workspace.json"))
        let nested = sessionDirectory.appendingPathComponent("nested", isDirectory: true)
        try write(Data("nested\n".utf8), to: nested.appendingPathComponent("session.v0.jsonl"))

        let session = Session(
            id: id,
            source: .deepseekHarness,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: primary.path,
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )

        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider }

        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(session)
        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))
        XCTAssertNil(info.lastError, info.lastError ?? "")
        XCTAssertEqual(info.upstreamPath, sessionDirectory.path)
        XCTAssertTrue(info.upstreamIsDirectory)
        XCTAssertEqual(info.primaryRelativePath, primary.lastPathComponent)

        let dataRoot = appSupport
            .appendingPathComponent("AgentSessions/Archives/deepseek-harness/\(id)/data", isDirectory: true)
        let copied = try fileManager.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(copied, ["session.jsonl", "session.v1.jsonl", "session.v2.jsonl"])

        let manifestURL = dataRoot.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            SessionArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.entries.map(\.relativePath), copied)
        let copiedSize = try copied.reduce(Int64(0)) { total, name in
            let values = try dataRoot.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
            return total + Int64(values.fileSize ?? 0)
        }
        XCTAssertEqual(info.archiveSizeBytes, copiedSize)

        let archivedPrimary = dataRoot.appendingPathComponent(primary.lastPathComponent)
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(at: archivedPrimary)?.id, id)
    }

    func testArchiveSyncAdvancesSelectedGenerationWithoutChangingPinnedAt() throws {
        let upstreamRoot = try temporaryRoot("DeepSeekHarnessArchiveAdvanceUpstream")
        let appSupport = try temporaryRoot("DeepSeekHarnessArchiveAdvanceSupport")
        let id = "archive-advance"
        let v2 = try writeGeneration(
            root: upstreamRoot, id: id, version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        let previousRoot = UserDefaults.standard.object(forKey: DeepSeekHarnessSettings.Keys.rootOverride)
        let previousFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        let previousStarPins = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions)
        UserDefaults.standard.set(upstreamRoot.path, forKey: DeepSeekHarnessSettings.Keys.rootOverride)
        UserDefaults.standard.set(true, forKey: PreferencesKey.Archives.starPinsSessions)
        UserDefaults.standard.set([StarredSessionKey(source: .deepseekHarness, id: id).persistedString],
                                  forKey: StarredSessionsStore.defaultsKey)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: DeepSeekHarnessSettings.Keys.rootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: DeepSeekHarnessSettings.Keys.rootOverride)
            }
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            if let previousStarPins {
                UserDefaults.standard.set(previousStarPins, forKey: PreferencesKey.Archives.starPinsSessions)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Archives.starPinsSessions)
            }
        }

        let manager = SessionArchiveManager.shared
        let v2Session = try XCTUnwrap(DeepSeekHarnessSessionParser.parseFile(at: v2))
        manager.syncSessionForTesting(v2Session)
        let first = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))
        XCTAssertEqual(first.primaryRelativePath, "session.v2.jsonl")

        let v3 = try writeGeneration(
            root: upstreamRoot, id: id, version: 3,
            data: try validGenerationData(version: 3, id: id)
        )
        let archivedV3 = appSupport.appendingPathComponent(
            "AgentSessions/Archives/deepseek-harness/\(id)/data/session.v3.jsonl"
        )
        manager.syncPinnedSessionsForTesting()
        let advanced = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))

        XCTAssertEqual(advanced.pinnedAt, first.pinnedAt)
        XCTAssertEqual(URL(fileURLWithPath: advanced.upstreamPath).lastPathComponent,
                       v3.deletingLastPathComponent().lastPathComponent)
        XCTAssertEqual(advanced.primaryRelativePath, "session.v3.jsonl")
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(at: archivedV3)?.id, id)

        // A later clean scan sees only v2 after v3 disappears. Saved is
        // monotonic: it must retain the already copied v3, never resnapshot
        // the older generation over it.
        try fileManager.removeItem(at: v3)
        manager.syncPinnedSessionsForTesting()
        XCTAssertEqual(manager.archiveInfoForTesting(source: .deepseekHarness, id: id)?.primaryRelativePath,
                       "session.v3.jsonl")
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(at: archivedV3)?.id, id)

        // Re-starring the now-visible v2 goes through writePinPlaceholder and
        // ensureArchiveExistsAndSync, not the periodic guard above.
        manager.pinSessionForTesting(v2Session)
        let afterRepin = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))
        XCTAssertEqual(afterRepin.primaryRelativePath, "session.v3.jsonl")
        XCTAssertEqual(afterRepin.pinnedAt, first.pinnedAt)
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(at: archivedV3)?.id, id)
    }

    func testArchiveOnlyFallbackHydratesAndProducesPhysicalSearchFileRef() throws {
        let upstreamRoot = try temporaryRoot("DeepSeekHarnessArchiveFallbackUpstream")
        let appSupport = try temporaryRoot("DeepSeekHarnessArchiveFallbackSupport")
        let id = "archive-fallback"
        let primary = try writeGeneration(
            root: upstreamRoot, id: id, version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        let previousFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        UserDefaults.standard.set([StarredSessionKey(source: .deepseekHarness, id: id).persistedString],
                                  forKey: StarredSessionsStore.defaultsKey)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
        }

        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(try XCTUnwrap(DeepSeekHarnessSessionParser.parseFile(at: primary)))
        try fileManager.removeItem(at: primary.deletingLastPathComponent())

        let fallbacks = manager.mergePinnedArchiveFallbacks(into: [], source: .deepseekHarness)
        let fallback = try XCTUnwrap(fallbacks.first)
        XCTAssertEqual(fallback.id, id)
        XCTAssertTrue(fallback.filePath.contains("/Archives/deepseek-harness/\(id)/data/"))
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(
            at: URL(fileURLWithPath: fallback.filePath)
        )?.id, id)

        let refs = UnifiedSessionIndexer.searchFileRefs(for: fallbacks)
        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(ref.path, fallback.filePath)
        XCTAssertNil(ref.manifestRevision)
        XCTAssertGreaterThan(ref.size, 0)

        let unowned = Session(
            id: "not-the-saved-session", source: .deepseekHarness,
            startTime: nil, endTime: nil, model: nil,
            filePath: fallback.filePath, eventCount: 0, events: [],
            cwd: cwd, repoName: nil, lightweightTitle: nil
        )
        XCTAssertTrue(UnifiedSessionIndexer.searchFileRefs(for: [unowned]).isEmpty,
                      "a failed live resolver must not turn arbitrary paths into archive authority")
    }

    func testIndexerListsAndReloadsArchiveOnlySavedSession() throws {
        let upstreamRoot = try temporaryRoot("DeepSeekHarnessArchiveIndexerUpstream")
        let appSupport = try temporaryRoot("DeepSeekHarnessArchiveIndexerSupport")
        let id = "archive-indexer"
        let primary = try writeGeneration(
            root: upstreamRoot, id: id, version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        let rootKey = DeepSeekHarnessSettings.Keys.rootOverride
        let previousRoot = UserDefaults.standard.object(forKey: rootKey)
        let previousFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        UserDefaults.standard.set(upstreamRoot.path, forKey: rootKey)
        UserDefaults.standard.set([StarredSessionKey(source: .deepseekHarness, id: id).persistedString],
                                  forKey: StarredSessionsStore.defaultsKey)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider
            if let previousRoot { UserDefaults.standard.set(previousRoot, forKey: rootKey) }
            else { UserDefaults.standard.removeObject(forKey: rootKey) }
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
        }

        SessionArchiveManager.shared.syncSessionForTesting(
            try XCTUnwrap(DeepSeekHarnessSessionParser.parseFile(at: primary))
        )
        try fileManager.removeItem(at: primary.deletingLastPathComponent())

        let indexer = DeepSeekHarnessSessionIndexer()
        indexer.refresh()
        waitUntil("archive-only refresh should finish") { !indexer.isIndexing }
        let fallback = try XCTUnwrap(indexer.allSessions.first(where: { $0.id == id }))
        XCTAssertTrue(fallback.events.isEmpty)
        XCTAssertTrue(fallback.filePath.contains("/Archives/deepseek-harness/\(id)/data/"))
        XCTAssertEqual(indexer.searchLivePathSnapshot, [],
                       "archive paths must not enter authoritative live-path membership")

        indexer.reloadSession(id: id, force: true, reason: .manualRefresh)
        waitUntil("archive-only row should hydrate directly") {
            indexer.allSessions.first(where: { $0.id == id })?.events.isEmpty == false
        }
        XCTAssertEqual(indexer.allSessions.first(where: { $0.id == id })?.id, id)
    }

    func testUnstableUpstreamFailsClosedAndPreservesHealthyArchive() throws {
        let upstreamRoot = try temporaryRoot("DeepSeekHarnessArchiveUnstableUpstream")
        let appSupport = try temporaryRoot("DeepSeekHarnessArchiveUnstableSupport")
        let id = "archive-unstable"
        let primary = try writeGeneration(
            root: upstreamRoot,
            id: id,
            version: 2,
            data: try validGenerationData(version: 2, id: id)
        )
        _ = try writeGeneration(root: upstreamRoot, id: id, version: 1, data: Data("generation-one\n".utf8))

        let session = Session(
            id: id,
            source: .deepseekHarness,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: primary.path,
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )

        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider }

        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(session)
        let healthy = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))
        XCTAssertNil(healthy.lastError, healthy.lastError ?? "")
        XCTAssertNotEqual(healthy.status, .error)

        let sessionDir = appSupport
            .appendingPathComponent("AgentSessions/Archives/deepseek-harness/\(id)", isDirectory: true)
        let manifestURL = sessionDir.appendingPathComponent("manifest.json")
        let dataRoot = sessionDir.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)

        // Break the sync noop gate so the retry loop actually runs: one
        // upstream write before the sync, then a hook mutation after every
        // attempt copy so no stability check can ever pass.
        try appendLine("pre-sync-churn\n", to: primary)
        var postCopyCount = 0
        SessionArchiveManagerTestHooks.postCopyHook = {
            postCopyCount += 1
            try? self.appendLine("churn-\(postCopyCount)\n", to: primary)
        }
        defer { SessionArchiveManagerTestHooks.postCopyHook = nil }

        manager.syncSessionForTesting(session)

        XCTAssertEqual(postCopyCount, 4, "exactly the four retry attempts may copy; no fifth best-effort copy")
        let failed = try XCTUnwrap(manager.archiveInfoForTesting(source: .deepseekHarness, id: id))
        XCTAssertEqual(failed.status, .error)
        let lastError = try XCTUnwrap(failed.lastError)
        XCTAssertTrue(lastError.contains("updating continuously"), lastError)
        XCTAssertFalse(lastError.contains("best-effort"), lastError)

        // The healthy archive is untouched: same manifest, same data bytes.
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        var data = try Data(contentsOf: url)
        data.append(contentsOf: Data(line.utf8))
        try data.write(to: url, options: .atomic)
    }

    private func regularFileBytes(in directory: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }
}
