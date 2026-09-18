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
}
