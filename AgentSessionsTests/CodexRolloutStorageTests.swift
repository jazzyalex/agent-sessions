import XCTest
@testable import AgentSessions

/// Codex `local_thread_store_compression` replaces a cold `rollout-….jsonl` with
/// `rollout-….jsonl.zst` (one zstd stream, level 3) and deletes the plain file.
/// The fixture is the stage0 Codex fixture compressed the same way.
final class CodexRolloutStorageTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexZst-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private var compressedFixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/stage0/agents/codex/small.jsonl.zst")
    }

    private func dayDirectory() throws -> URL {
        let day = root.appendingPathComponent("2026/09/03", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        return day
    }

    private let rolloutName = "rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca31.jsonl"

    /// Puts only the compressed form on disk and returns the canonical `.jsonl` URL.
    private func placeCompressedRollout() throws -> URL {
        let canonical = try dayDirectory().appendingPathComponent(rolloutName)
        try fm.copyItem(at: compressedFixture, to: CodexRolloutStorage.compressedSibling(of: canonical))
        return canonical
    }

    private func decodedFixtureBytes() throws -> Data {
        let temp = try dayDirectory().appendingPathComponent("rollout-decode-check.jsonl.zst")
        try fm.copyItem(at: compressedFixture, to: temp)
        defer { try? fm.removeItem(at: temp) }
        return try CodexRolloutStorage.readAllData(for: temp)
    }

    // MARK: - Decoder

    func testDecoderReadsTheWholeStreamAsJSONL() throws {
        let data = try decodedFixtureBytes()
        XCTAssertGreaterThan(data.count, 100_000)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 100)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)), "every decoded line is JSON")
        }
    }

    func testDecoderReturnsTheSameBytesForAnyReadSize() throws {
        let expected = try decodedFixtureBytes()
        for size in [1, 7, 4096, 65_536, 1_000_000] {
            let handle = try FileHandle(forReadingFrom: compressedFixture)
            defer { try? handle.close() }
            let decoder = ZstdStreamDecoder()
            var out = Data()
            while true {
                let chunk = try decoder.read(from: handle, upTo: size)
                if chunk.isEmpty { break }
                XCTAssertLessThanOrEqual(chunk.count, size)
                out.append(chunk)
            }
            XCTAssertEqual(out, expected, "read size \(size)")
        }
    }

    func testTruncatedStreamThrowsInsteadOfEndingQuietly() throws {
        let full = try Data(contentsOf: compressedFixture)
        let truncated = root.appendingPathComponent("rollout-truncated.jsonl.zst")
        try full.prefix(full.count - 64).write(to: truncated)
        XCTAssertThrowsError(try CodexRolloutStorage.readAllData(for: truncated))
    }

    // MARK: - Paths

    func testCanonicalPathDropsOnlyTheCompressedSuffix() {
        let compressed = URL(fileURLWithPath: "/x/sessions/2026/09/03/\(rolloutName).zst")
        XCTAssertEqual(CodexRolloutStorage.canonicalURL(for: compressed).lastPathComponent, rolloutName)
        let unrelated = URL(fileURLWithPath: "/x/data.jsonl.zst")
        XCTAssertEqual(CodexRolloutStorage.canonicalURL(for: unrelated), unrelated)
    }

    func testStorageResolutionPrefersThePlainFile() throws {
        let canonical = try placeCompressedRollout()
        XCTAssertEqual(CodexRolloutStorage.storageURL(for: canonical)?.lastPathComponent, rolloutName + ".zst")
        XCTAssertTrue(CodexRolloutStorage.exists(atPath: canonical.path))

        try decodedFixtureBytes().write(to: canonical)
        XCTAssertEqual(CodexRolloutStorage.storageURL(for: canonical), canonical)
    }

    // MARK: - Discovery

    func testDiscoveryListsACompressedRolloutUnderItsCanonicalPath() throws {
        let canonical = try placeCompressedRollout()
        let found = CodexSessionDiscovery(customRoot: root.path).discoverSessionFiles()
        // The enumerator reports /private/var for the /var temp directory; compare names.
        XCTAssertEqual(found.map(\.lastPathComponent), [canonical.lastPathComponent])
    }

    func testDiscoveryListsARolloutOnceWhenBothFormsExist() throws {
        let canonical = try placeCompressedRollout()
        try decodedFixtureBytes().write(to: canonical)
        let found = CodexSessionDiscovery(customRoot: root.path).discoverSessionFiles()
        XCTAssertEqual(found.map(\.lastPathComponent), [canonical.lastPathComponent])
    }

    func testFileStatFollowsTheCompressedFile() throws {
        let canonical = try placeCompressedRollout()
        let stat = try XCTUnwrap(SessionFileStat.from(canonical))
        let attrs = try fm.attributesOfItem(atPath: CodexRolloutStorage.compressedSibling(of: canonical).path)
        XCTAssertEqual(stat.size, (attrs[.size] as? NSNumber)?.int64Value)
    }

    // MARK: - Parsing

    func testCompressedRolloutParsesLikeThePlainFileWithTheSameID() throws {
        let plainDir = root.appendingPathComponent("plain", isDirectory: true)
        try fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let plain = plainDir.appendingPathComponent(rolloutName)
        let bytes = try decodedFixtureBytes()
        try bytes.write(to: plain)

        let canonical = try placeCompressedRollout()
        let indexer = SessionIndexer()

        let plainFull = try XCTUnwrap(indexer.parseFileFull(at: plain))
        let compressedFull = try XCTUnwrap(indexer.parseFileFull(at: canonical))
        XCTAssertEqual(compressedFull.filePath, canonical.path, "the session keeps its .jsonl path")
        XCTAssertEqual(compressedFull.events.count, plainFull.events.count)
        XCTAssertEqual(compressedFull.events.map(\.kind), plainFull.events.map(\.kind))
        XCTAssertEqual(compressedFull.fileSizeBytes, bytes.count, "size is the decoded size")
        XCTAssertEqual(compressedFull.codexInternalSessionIDHint, plainFull.codexInternalSessionIDHint)

        let preview = try XCTUnwrap(indexer.parseFile(at: canonical))
        XCTAssertEqual(preview.id, compressedFull.id)
        XCTAssertEqual(preview.filePath, canonical.path)
        XCTAssertEqual(preview.cwd, plainFull.cwd)
        XCTAssertGreaterThan(preview.eventCount, 0)

        // Codex restoring the plain file must not change the session's identity.
        try bytes.write(to: canonical)
        try fm.removeItem(at: CodexRolloutStorage.compressedSibling(of: canonical))
        XCTAssertEqual(try XCTUnwrap(indexer.parseFileFull(at: canonical)).id, compressedFull.id)
    }

    func testTelemetrySignatureAndLineReaderFollowTheCompressedFile() throws {
        let canonical = try placeCompressedRollout()
        XCTAssertNotNil(RunwayFileSignature.read(path: canonical.path))

        let expectedLines = String(decoding: try decodedFixtureBytes(), as: UTF8.self)
            .split(separator: "\n").count
        let reader = try XCTUnwrap(CodexRolloutStorage.lineReader(for: canonical, maximumBytes: 10))
        XCTAssertEqual(try reader.readLines().count, expectedLines,
                       "a stat-size bound must not truncate a compressed stream")
    }

    func testSideChatParentLookupFindsACompressedRollout() throws {
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/09/03", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let canonical = day.appendingPathComponent(rolloutName)
        try fm.copyItem(at: compressedFixture, to: CodexRolloutStorage.compressedSibling(of: canonical))

        let index = CodexSideChatLogReader.rolloutIndex(codexHome: home)
        XCTAssertEqual(index["01a06900-af0b-7d53-a27e-64ee9619ca31"]?.lastPathComponent, rolloutName)
    }

    func testRandomAccessCopyHasTheDecodedBytes() throws {
        let canonical = try placeCompressedRollout()
        let copy = try CodexRolloutStorage.randomAccessURL(for: canonical)
        defer { try? fm.removeItem(at: copy) }
        XCTAssertNotEqual(copy.path, canonical.path)
        XCTAssertEqual(try Data(contentsOf: copy), try decodedFixtureBytes())
        XCTAssertEqual(try CodexRolloutStorage.randomAccessURL(for: canonical), copy, "the copy is reused")
    }
}
