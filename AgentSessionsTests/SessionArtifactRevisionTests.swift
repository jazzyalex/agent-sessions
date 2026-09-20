import Foundation
import XCTest
@testable import AgentSessions

/// Compile-intent coverage for the source-agnostic directory-artifact freshness seam.
///
/// DSH's directory is the logical artifact.  The selected generation is the physical
/// parse anchor, while the sibling manifest is part of freshness even when the selected
/// file itself did not change.  These tests deliberately keep all fixture state local and
/// never read the user's ~/.dsh directory.
final class SessionArtifactRevisionTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporarySessionsRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SessionArtifactRevisionTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: root)
        }
        return root
    }

    private func header(id: String, version: Int, cwd: String = "/tmp/dsh-revision-fixture") -> [String: Any] {
        var result: [String: Any] = [
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": 1_700_000_000_000,
            "delegationDepth": 0,
        ]
        if version >= 2 { result["isSeeded"] = false }
        result["cwd"] = cwd
        return result
    }

    @discardableResult
    private func writeJSONLine(_ object: [String: Any], at url: URL) throws -> URL {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    private func writeGeneration(root: URL,
                                cwd: String = "/tmp/dsh-revision-fixture",
                                id: String = "revision-session",
                                version: Int) throws -> URL {
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root,
            cwd: cwd,
            id: id,
            version: version,
            compression: .plain
        )
        return try writeJSONLine(header(id: id, version: version, cwd: cwd), at: url)
    }

    private func candidate(at root: URL,
                           id: String = "revision-session") throws -> DeepSeekHarnessSessionCandidate {
        try XCTUnwrap(
            DeepSeekHarnessDiscovery(customRoot: root.path)
                .discover()
                .candidates
                .first(where: { $0.id == id })
        )
    }

    private func artifactRevision(for candidate: DeepSeekHarnessSessionCandidate) throws -> SessionArtifactRevision {
        let physicalStat = try XCTUnwrap(SessionFileStat.from(candidate.selectedURL))
        return SessionArtifactRevision(
            selectedURL: candidate.selectedURL,
            manifestRevision: candidate.manifestRevision,
            physicalStat: physicalStat
        )
    }

    private func fileRef(for candidate: DeepSeekHarnessSessionCandidate) throws -> SearchIngestService.FileRef {
        let revision = try artifactRevision(for: candidate)
        return SearchIngestService.FileRef(
            path: revision.selectedURL.path,
            mtime: revision.physicalStat.mtime,
            size: revision.physicalStat.size,
            manifestRevision: revision.manifestRevision
        )
    }

    // MARK: Directory artifact revision

    func testDirectoryArtifactRevisionChangesWhenSelectedGenerationChanges() throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        let before = try artifactRevision(for: candidate(at: root))

        XCTAssertEqual(before.selectedURL.standardizedFileURL, generationZero.standardizedFileURL)
        XCTAssertEqual(before.physicalStat, SessionFileStat.from(generationZero))

        let generationOne = try writeGeneration(root: root, version: 1)
        let after = try artifactRevision(for: candidate(at: root))

        XCTAssertEqual(after.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)
        XCTAssertNotEqual(before.selectedURL.standardizedFileURL, after.selectedURL.standardizedFileURL)
        XCTAssertNotEqual(before.manifestRevision, after.manifestRevision)
        XCTAssertNotEqual(before, after)
    }

    func testDirectoryArtifactRevisionChangesWhenManifestChangesButSelectedGenerationDoesNot() throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        let generationOne = try writeGeneration(root: root, version: 1)
        let before = try artifactRevision(for: candidate(at: root))
        XCTAssertEqual(before.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)

        // The successor remains authoritative.  Only the non-selected sibling changes,
        // so a selected-file mtime/size key alone would incorrectly report no change.
        var changed = try Data(contentsOf: generationZero)
        changed.append(contentsOf: Data("manifest-change".utf8))
        try changed.write(to: generationZero, options: .atomic)

        let after = try artifactRevision(for: candidate(at: root))
        XCTAssertEqual(after.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)
        XCTAssertEqual(after.physicalStat, before.physicalStat)
        XCTAssertNotEqual(after.manifestRevision, before.manifestRevision)
        XCTAssertNotEqual(after, before)
    }

    func testDescriptorArtifactRevisionRescansTheLogicalDirectory() throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        let descriptor = SessionSource.deepseekHarness.descriptor
        let resolve = try XCTUnwrap(
            descriptor.artifactRevision,
            "directory-backed sources must expose the generic artifact revision seam"
        )

        let before = try XCTUnwrap(resolve(generationZero))
        XCTAssertEqual(before.selectedURL.standardizedFileURL, generationZero.standardizedFileURL)

        let generationOne = try writeGeneration(root: root, version: 1)
        let after = try XCTUnwrap(resolve(generationZero))
        XCTAssertEqual(after.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)
        XCTAssertNotEqual(before.manifestRevision, after.manifestRevision)
    }

    // MARK: Search freshness and transactional stale anchors

    func testStaleSearchAnchorHasAZeroWriteOutcomeAndRetryUsesTheNewGeneration() async throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        let oldCandidate = try candidate(at: root)
        let oldRef = try fileRef(for: oldCandidate)

        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: db)

        let first = try await service.ingest(
            source: .deepseekHarness,
            files: [oldRef],
            toolIOEnabled: false,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(first.processed, 1, "the initial immutable generation should ingest normally")

        let countsBefore = try await [
            db.rowCountForTesting(table: "files", source: SessionSource.deepseekHarness.rawValue),
            db.rowCountForTesting(table: "session_meta", source: SessionSource.deepseekHarness.rawValue),
            db.rowCountForTesting(table: "session_search", source: SessionSource.deepseekHarness.rawValue),
        ]

        let generationOne = try writeGeneration(root: root, version: 1)
        let stale = try await service.ingest(
            source: .deepseekHarness,
            files: [oldRef],
            toolIOEnabled: false,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )

        XCTAssertEqual(stale.processed, 0)
        XCTAssertEqual(stale.staleAnchorPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       [generationZero.standardizedFileURL.path],
                       "an anchor whose directory now selects a successor must return a distinct stale result")
        let countsAfterStale = try await [
            db.rowCountForTesting(table: "files", source: SessionSource.deepseekHarness.rawValue),
            db.rowCountForTesting(table: "session_meta", source: SessionSource.deepseekHarness.rawValue),
            db.rowCountForTesting(table: "session_search", source: SessionSource.deepseekHarness.rawValue),
        ]
        XCTAssertEqual(countsAfterStale, countsBefore,
                       "stale search must not persist the parsed old generation or mutate FTS")

        let newCandidate = try candidate(at: root)
        XCTAssertEqual(newCandidate.selectedURL.standardizedFileURL, generationOne.standardizedFileURL)
        let retry = try await service.ingest(
            source: .deepseekHarness,
            files: [try fileRef(for: newCandidate)],
            toolIOEnabled: false,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(retry.processed, 1, "the refreshed row must retry from the newly selected anchor")
        let indexedPath = try await db.fetchIndexedFiles(for: SessionSource.deepseekHarness.rawValue).first?.path
        XCTAssertEqual(indexedPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       generationOne.standardizedFileURL.path)
    }

    func testUnchangedArtifactRevisionPreservesTheExistingSearchSkipBehavior() async throws {
        let root = try temporarySessionsRoot()
        _ = try writeGeneration(root: root, version: 0)
        let ref = try fileRef(for: candidate(at: root))
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: db)

        let first = try await service.ingest(
            source: .deepseekHarness,
            files: [ref],
            toolIOEnabled: false,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(first.processed, 1)

        let second = try await service.ingest(
            source: .deepseekHarness,
            files: [ref],
            toolIOEnabled: false,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(second.processed, 0)
        XCTAssertEqual(second.skipped, 1)
        let earlyOutHitCount = await service.earlyOutHitCountForTesting
        XCTAssertEqual(earlyOutHitCount, 1,
                       "an unchanged directory revision must retain the current aggregate early-out")
    }

    // MARK: Focused monitor freshness

    func testFocusedSignatureIncludesDirectoryArtifactRevisionEvenWhenSelectedFileStatIsUnchanged() throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        _ = try writeGeneration(root: root, version: 1)

        let before = try XCTUnwrap(
            UnifiedSessionIndexer.logicalFocusedSignature(
                source: .deepseekHarness,
                path: generationZero.path
            )
        )

        // Change only the non-selected sibling.  The focused signature's physical path,
        // mtime, and size remain tied to generation one; only the directory revision can
        // make the signature differ.
        var changed = try Data(contentsOf: generationZero)
        changed.append(contentsOf: Data("focused-manifest-change".utf8))
        try changed.write(to: generationZero, options: .atomic)

        let after = try XCTUnwrap(
            UnifiedSessionIndexer.logicalFocusedSignature(
                source: .deepseekHarness,
                path: generationZero.path
            )
        )
        XCTAssertEqual(before.path, after.path)
        XCTAssertEqual(before.modifiedAt, after.modifiedAt)
        XCTAssertEqual(before.size, after.size)
        XCTAssertNotEqual(before, after,
                          "focused monitoring must include the directory artifact revision, not only the selected-file stat")
    }

    func testSearchFileRefCarriesTheDirectoryManifestRevision() throws {
        let root = try temporarySessionsRoot()
        let generationZero = try writeGeneration(root: root, version: 0)
        let session = try XCTUnwrap(DeepSeekHarnessSessionParser.parseFileFull(at: generationZero))

        let refs = UnifiedSessionIndexer.searchFileRefs(for: [session])
        let ref = try XCTUnwrap(refs.first)
        let candidate = try candidate(at: root)
        XCTAssertEqual(URL(fileURLWithPath: ref.path).standardizedFileURL,
                       generationZero.standardizedFileURL)
        XCTAssertEqual(ref.manifestRevision, candidate.manifestRevision)
    }
}
