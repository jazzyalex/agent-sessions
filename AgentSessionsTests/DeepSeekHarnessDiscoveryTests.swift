import Foundation
import XCTest
@testable import AgentSessions

final class DeepSeekHarnessDiscoveryTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporarySessionsRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DeepSeekHarnessDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: root)
        }
        return root
    }

    private func headerObject(version: Int, id: String, cwd: String? = "/tmp/dsh-project") -> [String: Any] {
        var object: [String: Any] = [
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": 1_700_000_000_000,
            "delegationDepth": 0,
        ]
        if version >= 2 { object["isSeeded"] = false }
        if let cwd { object["cwd"] = cwd }
        return object
    }

    @discardableResult
    private func writeJSONLine(_ object: [String: Any], at url: URL) throws -> URL {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    private func writeGeneration(
        root: URL,
        cwd: String?,
        id: String,
        version: Int
    ) throws -> URL {
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: cwd,
            id: id,
            version: version,
            compression: .plain
        )
        return try writeJSONLine(headerObject(version: version, id: id, cwd: cwd), at: url)
    }

    private func discover(at root: URL) -> DeepSeekHarnessDiscoveryResult {
        DeepSeekHarnessDiscovery(customRoot: root.path).discover()
    }

    func testRootEnumerationFailureIsReportedInsteadOfAuthoritativeEmpty() throws {
        let root = try temporarySessionsRoot()
        let discovery = DeepSeekHarnessDiscovery(
            customRoot: root.path,
            directoryContents: { url in
                if url.standardizedFileURL == root.standardizedFileURL {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try self.fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: []
                )
            }
        )

        let result = discovery.discover()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.issues, [.filesystemAccess(root.path)])
    }

    func testChildStatFailureIsReportedInsteadOfSilentlyDroppingCandidate() throws {
        let root = try temporarySessionsRoot()
        let generation = try writeGeneration(
            root: root, cwd: "/tmp/dsh-stat-failure", id: "stat-failure", version: 2
        )
        let project = generation.deletingLastPathComponent().deletingLastPathComponent()
        let discovery = DeepSeekHarnessDiscovery(
            customRoot: root.path,
            itemAttributes: { path in
                if URL(fileURLWithPath: path).lastPathComponent == project.lastPathComponent {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try self.fileManager.attributesOfItem(atPath: path)
            }
        )

        let result = discovery.discover()
        XCTAssertTrue(result.candidates.isEmpty)
        guard case .filesystemAccess(let failedPath) = result.issues.first else {
            return XCTFail("expected filesystem access issue")
        }
        XCTAssertEqual(URL(fileURLWithPath: failedPath).lastPathComponent, project.lastPathComponent)
    }

    func testRecognizesOnlyExactCanonicalGenerationFilenames() {
        let accepted: [(String, Int, DeepSeekHarnessCompression)] = [
            ("session.jsonl", 0, .plain),
            ("session.jsonl.zstd", 0, .zstd),
            ("session.v1.jsonl", 1, .plain),
            ("session.v1.jsonl.zstd", 1, .zstd),
            ("session.v999.jsonl", 999, .plain),
        ]
        for (filename, generation, compression) in accepted {
            let parsed = DeepSeekHarnessDiscovery.parseGenerationFilename(filename)
            XCTAssertEqual(parsed?.generation, generation, filename)
            XCTAssertEqual(parsed?.compression, compression, filename)
        }

        let rejected = [
            "session.v0.jsonl",
            "session.v00.jsonl",
            "session.v01.jsonl",
            "session.v-1.jsonl",
            "session.v1.JSONL",
            "session.v1.jsonl.zst",
            "session.v1.jsonl.tmp",
            "session.jsonl.tmp",
        ]
        for filename in rejected {
            XCTAssertNil(
                DeepSeekHarnessDiscovery.parseGenerationFilename(filename),
                "non-canonical filename must not be selected: \(filename)"
            )
        }
    }

    func testHighestGenerationWinsAndGenerationZeroHasNoExplicitV0Name() throws {
        let root = try temporarySessionsRoot()
        let id = "generation-selection"
        let cwd = "/tmp/dsh-generation-selection"
        let generationZero = try writeGeneration(root: root, cwd: cwd, id: id, version: 0)
        let generationTwo = try writeGeneration(root: root, cwd: cwd, id: id, version: 2)

        let result = discover(at: root)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.id, id)
        XCTAssertEqual(candidate.generation, 2)
        XCTAssertEqual(candidate.selectedURL.standardizedFileURL, generationTwo.standardizedFileURL)
        XCTAssertTrue(candidate.siblings.contains {
            $0.standardizedFileURL == generationZero.standardizedFileURL
        })
        XCTAssertFalse(candidate.siblings.contains {
            $0.lastPathComponent == "session.v0.jsonl"
        })

        XCTAssertNil(DeepSeekHarnessDiscovery.parseGenerationFilename("session.v0.jsonl"))
    }

    func testSameRootPlainAndZstandardArtifactsAreRejectedAsEncodingMismatch() throws {
        let root = try temporarySessionsRoot()
        _ = try writeGeneration(root: root, cwd: "/tmp/plain", id: "plain", version: 0)

        let zstdURL = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: "/tmp/compressed",
            id: "compressed",
            version: 0,
            compression: .zstd
        )
        try fileManager.createDirectory(
            at: zstdURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x28, 0xB5, 0x2F, 0xFD]).write(to: zstdURL)

        let result = discover(at: root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.encoding, nil)
        XCTAssertEqual(result.issues, [.encodingMismatch])
    }

    func testFlatLegacyArtifactIsRefusedWithAnExplicitIssue() throws {
        let root = try temporarySessionsRoot()
        let cwd = "/tmp/dsh-flat-legacy"
        let project = root.appendingPathComponent(DeepSeekHarnessDiscovery.projectKey(cwd), isDirectory: true)
        let legacyURL = project.appendingPathComponent(
            DeepSeekHarnessDiscovery.encodeSegment("legacy-session") + ".jsonl",
            isDirectory: false
        )
        try writeJSONLine(headerObject(version: 0, id: "legacy-session", cwd: cwd), at: legacyURL)

        let result = discover(at: root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(
            result.issues.contains { error in
                guard case .legacyLayout(let url) = error else { return false }
                return url.standardizedFileURL == legacyURL.standardizedFileURL
            },
            "flat legacy layout must be reported, not silently ignored"
        )
    }

    func testHeaderIdentityMustMatchCanonicalPath() throws {
        let root = try temporarySessionsRoot()
        let cwd = "/tmp/dsh-identity"
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: cwd,
            id: "path-id",
            version: 0,
            compression: .plain
        )
        try writeJSONLine(headerObject(version: 0, id: "header-id", cwd: cwd), at: url)

        let result = discover(at: root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.issues.contains(.canonicalPathMismatch))
    }

    func testDuplicateOpaqueIDAcrossProjectsIsAmbiguous() throws {
        let root = try temporarySessionsRoot()
        let id = "same-opaque-id"
        _ = try writeGeneration(root: root, cwd: "/tmp/dsh-project-a", id: id, version: 0)
        _ = try writeGeneration(root: root, cwd: "/tmp/dsh-project-b", id: id, version: 0)

        let result = discover(at: root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.issues.contains(.ambiguousSession(id)))
    }

    func testSymlinkDirectoriesSymlinkFilesAndNonregularArtifactsAreRejected() throws {
        let root = try temporarySessionsRoot()

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("DeepSeekHarnessDiscoveryOutside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: outside)
        }
        let outsideProject = outside.appendingPathComponent("outside-project", isDirectory: true)
        let outsideSession = outsideProject.appendingPathComponent("outside-session", isDirectory: true)
        let outsideArtifact = outsideSession.appendingPathComponent("session.jsonl", isDirectory: false)
        _ = try writeJSONLine(
            headerObject(version: 0, id: "outside-session", cwd: "/tmp/outside"),
            at: outsideArtifact
        )

        let linkedProject = root.appendingPathComponent("linked-project", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedProject, withDestinationURL: outsideProject)

        let project = root.appendingPathComponent("real-project", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let linkedSession = project.appendingPathComponent("linked-session", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedSession, withDestinationURL: outsideSession)

        let nonregularSession = project.appendingPathComponent("nonregular-session", isDirectory: true)
        try fileManager.createDirectory(at: nonregularSession, withIntermediateDirectories: true)
        let directoryArtifact = nonregularSession.appendingPathComponent("session.jsonl", isDirectory: true)
        try fileManager.createDirectory(at: directoryArtifact, withIntermediateDirectories: true)

        let symlinkArtifactSession = project.appendingPathComponent("symlink-artifact-session", isDirectory: true)
        try fileManager.createDirectory(at: symlinkArtifactSession, withIntermediateDirectories: true)
        let symlinkArtifact = symlinkArtifactSession.appendingPathComponent("session.jsonl", isDirectory: false)
        try fileManager.createSymbolicLink(at: symlinkArtifact, withDestinationURL: outsideArtifact)

        let result = discover(at: root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testManifestRevisionIsDeterministicAndChangesForSiblingAndSuccessor() throws {
        let root = try temporarySessionsRoot()
        let cwd = "/tmp/dsh-revisions"
        let id = "revision-session"
        let generationZero = try writeGeneration(root: root, cwd: cwd, id: id, version: 0)
        let generationOne = try writeGeneration(root: root, cwd: cwd, id: id, version: 1)

        let first = try XCTUnwrap(discover(at: root).candidates.first)
        let repeatResult = try XCTUnwrap(discover(at: root).candidates.first)
        XCTAssertEqual(first.manifestRevision, repeatResult.manifestRevision)
        XCTAssertEqual(first.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)

        var changedSibling = try Data(contentsOf: generationZero)
        changedSibling.append(contentsOf: Data("\n".utf8))
        try changedSibling.write(to: generationZero, options: .atomic)

        let afterSiblingChange = try XCTUnwrap(discover(at: root).candidates.first)
        XCTAssertNotEqual(first.manifestRevision, afterSiblingChange.manifestRevision)
        XCTAssertEqual(afterSiblingChange.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)

        let generationTwo = try writeGeneration(root: root, cwd: cwd, id: id, version: 2)
        let afterSuccessor = try XCTUnwrap(discover(at: root).candidates.first)
        XCTAssertEqual(afterSuccessor.generation, 2)
        XCTAssertEqual(afterSuccessor.selectedURL.standardizedFileURL, generationTwo.standardizedFileURL)
        XCTAssertNotEqual(afterSiblingChange.manifestRevision, afterSuccessor.manifestRevision)
    }

    // MARK: - Sessions-root boundary

    /// Full valid generation: the indexer lightweight-parses candidates, so
    /// fixtures carry the same header plus turn/step/user lines the archive
    /// contract test proves parseable. Header fields stay version-aware
    /// (no `isSeeded` below v2), matching discovery's proven shapes.
    private func fullGenerationData(version: Int, id: String, cwd: String) throws -> Data {
        var header: [String: Any] = [
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": 1_700_000_000_000,
            "cwd": cwd,
            "delegationDepth": 0,
        ]
        if version >= 2 { header["isSeeded"] = false }
        var data = try jsonLineForIndexer(header)
        data.append(try jsonLineForIndexer([
            "type": "turn/start",
            "seq": 0,
            "time": 1_700_000_000_001,
            "data": ["turn": 1],
        ]))
        data.append(try jsonLineForIndexer([
            "type": "step/start",
            "seq": 1,
            "time": 1_700_000_000_002,
            "data": ["turn": 1, "step": 1],
        ]))
        data.append(try jsonLineForIndexer([
            "type": "user/message",
            "seq": 2,
            "time": 1_700_000_000_003,
            "surfaceOp": "append",
            "data": [
                "id": "user-1",
                "role": "user",
                "content": [["type": "text", "text": "root boundary"]],
                "source": ["kind": "user"],
            ],
        ]))
        return data
    }

    private func jsonLineForIndexer(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    @discardableResult
    private func writeFullGeneration(root: URL, cwd: String, id: String, version: Int) throws -> URL {
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: cwd,
            id: id,
            version: version,
            compression: .plain
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fullGenerationData(version: version, id: id, cwd: cwd).write(to: url, options: .atomic)
        return url
    }

    /// Waits until the indexer has been continuously idle long enough that a
    /// `UserDefaults`-observer-triggered follow-up refresh (same runloop
    /// neighborhood) cannot still be in flight.
    private func waitForIndexerQuiescence(_ indexer: DeepSeekHarnessSessionIndexer, timeout: TimeInterval = 15) {
        let exp = expectation(description: "indexer quiescent")
        var idleTicks = 0
        func poll() {
            if indexer.isIndexing {
                idleTicks = 0
            } else {
                idleTicks += 1
                if idleTicks >= 10 { exp.fulfill(); return }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [exp], timeout: timeout)
    }

    private func indexerSessionIDs(_ indexer: DeepSeekHarnessSessionIndexer) -> Set<String> {
        Set(indexer.allSessions.map(\.id))
    }

    func testRootChangeFromDefaultToCustomDropsPriorProjection() throws {
        // The "default" side is simulated with a temp root: the boundary
        // under test is root identity, and the real ~/.dsh is never touched.
        let defaultRoot = try temporarySessionsRoot()
        _ = try writeFullGeneration(root: defaultRoot, cwd: "/tmp/dsh-root-default", id: "session-default", version: 2)
        let customRoot = try temporarySessionsRoot()
        _ = try writeFullGeneration(root: customRoot, cwd: "/tmp/dsh-root-custom", id: "session-custom", version: 2)

        let key = DeepSeekHarnessSettings.Keys.rootOverride
        UserDefaults.standard.set(defaultRoot.path, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let indexer = DeepSeekHarnessSessionIndexer()
        indexer.refresh()
        XCTAssertTrue(indexer.isIndexing, "refresh must set isIndexing synchronously")
        waitForIndexerQuiescence(indexer)
        XCTAssertEqual(indexerSessionIDs(indexer), ["session-default"])
        XCTAssertEqual(indexer.searchLivePathSnapshot, Set(indexer.allSessions.map(\.filePath)),
                       "a clean stable pass must publish its selected live generation paths")

        UserDefaults.standard.set(customRoot.path, forKey: key)
        waitForIndexerQuiescence(indexer)
        XCTAssertEqual(indexerSessionIDs(indexer), ["session-custom"])
        XCTAssertEqual(indexer.searchLivePathSnapshot, Set(indexer.allSessions.map(\.filePath)),
                       "a clean root transition must replace live-path authority")
    }

    func testCustomRootChangeWithPartialFailurePreservesOnlySameRootRows() throws {
        let rootA = try temporarySessionsRoot()
        _ = try writeFullGeneration(root: rootA, cwd: "/tmp/dsh-a", id: "session-a", version: 2)

        let rootB = try temporarySessionsRoot()
        _ = try writeFullGeneration(root: rootB, cwd: "/tmp/dsh-b-keep", id: "session-b", version: 2)
        // Partial failure in B: the same opaque id under two projects is
        // ambiguous, so B publishes one issue plus one healthy row.
        _ = try writeFullGeneration(root: rootB, cwd: "/tmp/dsh-b-dupe-one", id: "dupe", version: 0)
        _ = try writeFullGeneration(root: rootB, cwd: "/tmp/dsh-b-dupe-two", id: "dupe", version: 0)

        let key = DeepSeekHarnessSettings.Keys.rootOverride
        UserDefaults.standard.set(rootA.path, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let indexer = DeepSeekHarnessSessionIndexer()
        indexer.refresh()
        waitForIndexerQuiescence(indexer)
        XCTAssertEqual(indexerSessionIDs(indexer), ["session-a"])

        UserDefaults.standard.set(rootB.path, forKey: key)
        waitForIndexerQuiescence(indexer)
        XCTAssertEqual(indexerSessionIDs(indexer), ["session-b"])
        XCTAssertFalse(indexerSessionIDs(indexer).contains("session-a"), "prior-root rows must not survive a root change")
        XCTAssertNotNil(indexer.indexingError, "B's ambiguity issue must still surface")
        XCTAssertNil(indexer.searchLivePathSnapshot,
                     "a partial new-root result must remain unknown and cannot authorize search deletion")
    }

    func testCleanEmptyRootPublishesAuthoritativeEmptyLivePaths() throws {
        let populatedRoot = try temporarySessionsRoot()
        _ = try writeFullGeneration(root: populatedRoot, cwd: "/tmp/dsh-populated", id: "session-populated", version: 2)
        let emptyRoot = try temporarySessionsRoot()

        let key = DeepSeekHarnessSettings.Keys.rootOverride
        UserDefaults.standard.set(populatedRoot.path, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let indexer = DeepSeekHarnessSessionIndexer()
        indexer.refresh()
        waitForIndexerQuiescence(indexer)
        XCTAssertEqual(indexerSessionIDs(indexer), ["session-populated"])
        XCTAssertNotNil(indexer.searchLivePathSnapshot)

        UserDefaults.standard.set(emptyRoot.path, forKey: key)
        waitForIndexerQuiescence(indexer)
        XCTAssertTrue(indexer.allSessions.isEmpty)
        XCTAssertEqual(indexer.searchLivePathSnapshot, [],
                       "a clean empty root must be authoritative so stale live search rows can be removed")
    }
}
