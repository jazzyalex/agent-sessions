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

    func testZeroByteFileIsNotAnEmptyStream() throws {
        let empty = root.appendingPathComponent("rollout-empty.jsonl.zst")
        try Data().write(to: empty)
        XCTAssertThrowsError(try CodexRolloutStorage.readAllData(for: empty)) { error in
            XCTAssertEqual(error as? ZstdStreamDecoder.DecodeError, .empty)
        }
    }

    func testConcatenatedFramesDecodeInOrder() throws {
        let frame = try Data(contentsOf: compressedFixture)
        let doubled = root.appendingPathComponent("rollout-doubled.jsonl.zst")
        try (frame + frame).write(to: doubled)
        let expected = try decodedFixtureBytes()
        XCTAssertEqual(try CodexRolloutStorage.readAllData(for: doubled), expected + expected)
    }

    func testTruncatedStreamErrorReachesTheLineReader() throws {
        let canonical = try dayDirectory().appendingPathComponent(rolloutName)
        let full = try Data(contentsOf: compressedFixture)
        try full.prefix(full.count / 2).write(to: CodexRolloutStorage.compressedSibling(of: canonical))
        let reader = try XCTUnwrap(CodexRolloutStorage.lineReader(for: canonical, propagatesReadErrors: true))
        XCTAssertThrowsError(try reader.readLines())
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

    // MARK: - Review fixes (2026-10-14)

    private var imageFixture: URL {
        compressedFixture.deletingLastPathComponent().appendingPathComponent("image.jsonl.zst")
    }

    /// Puts the image fixture on disk as a compressed-only rollout.
    private func placeCompressedImageRollout() throws -> URL {
        let canonical = try dayDirectory()
            .appendingPathComponent("rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca32.jsonl")
        try fm.copyItem(at: imageFixture, to: CodexRolloutStorage.compressedSibling(of: canonical))
        return canonical
    }

    func testConcurrentMaterializationOfOneKeyPublishesOneCopyAndNoTempFiles() throws {
        let canonical = try placeCompressedRollout()
        let expected = try decodedFixtureBytes()
        let lock = NSLock()
        var results: [Result<URL, Error>] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = Result { try CodexRolloutStorage.randomAccessURL(for: canonical) }
            lock.lock(); results.append(result); lock.unlock()
        }
        let urls = try results.map { try $0.get() }
        let copy = try XCTUnwrap(urls.first)
        defer { try? fm.removeItem(at: copy) }
        XCTAssertEqual(Set(urls.map(\.path)), [copy.path], "every caller gets the same copy")
        XCTAssertEqual(try Data(contentsOf: copy), expected)
        let key = copy.deletingPathExtension().lastPathComponent
        let leftovers = try fm.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(key) && $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "no temp file is left behind")
    }

    func testRolloutWhoseHeaderExceedsTheCacheLimitIsNotMaterialized() throws {
        // A zstd frame header (single segment, 8-byte content size) that claims
        // 2 GiB. The header alone is enough to refuse it.
        var header = Data([0x28, 0xB5, 0x2F, 0xFD, 0xE0])
        var size = UInt64(2) * 1024 * 1024 * 1024
        header.append(Data(bytes: &size, count: 8))
        let canonical = try dayDirectory().appendingPathComponent(rolloutName)
        try header.write(to: CodexRolloutStorage.compressedSibling(of: canonical))
        XCTAssertEqual(CodexRolloutStorage.frameContentSize(of: CodexRolloutStorage.compressedSibling(of: canonical)), size)
        XCTAssertThrowsError(try CodexRolloutStorage.randomAccessURL(for: canonical)) { error in
            XCTAssertEqual(error as? ZstdStreamDecoder.DecodeError, .limitExceeded)
        }
    }

    func testEvictionKeepsRecentCopiesAndRemovesStaleTempFiles() throws {
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let now = Date()
        // Sparse files: 600 MB each by size, no disk blocks.
        func sparse(_ name: String, age: TimeInterval) throws -> URL {
            let url = cache.appendingPathComponent(name)
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 600 * 1024 * 1024)
            try handle.close()
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let oldest = try sparse("a.jsonl", age: 3_000)
        let older = try sparse("b.jsonl", age: 2_000)
        let justHanded = try sparse("c.jsonl", age: 5)
        let kept = try sparse("d.jsonl", age: 1)
        let staleTemp = try sparse("e.123.tmp", age: 7_200)
        let liveTemp = try sparse("f.456.tmp", age: 10)

        CodexRolloutStorage.evictMaterializedCopies(in: cache, keeping: kept, now: now)

        XCTAssertFalse(fm.fileExists(atPath: oldest.path))
        XCTAssertFalse(fm.fileExists(atPath: older.path))
        XCTAssertTrue(fm.fileExists(atPath: justHanded.path), "a copy used in the last minute survives")
        XCTAssertTrue(fm.fileExists(atPath: kept.path))
        XCTAssertFalse(fm.fileExists(atPath: staleTemp.path), "a temp file older than an hour is removed")
        XCTAssertTrue(fm.fileExists(atPath: liveTemp.path), "an in-progress temp file is left alone")
    }

    func testImageScanSkipsACompressedRolloutWithoutImages() throws {
        let canonical = try placeCompressedRollout()
        XCTAssertNil(CodexRolloutStorage.seekableURLForImageScan(forPath: canonical.path))
        let imageRollout = try placeCompressedImageRollout()
        let scanURL = try XCTUnwrap(CodexRolloutStorage.seekableURLForImageScan(forPath: imageRollout.path))
        defer { try? fm.removeItem(at: scanURL) }
        XCTAssertNotEqual(scanURL.path, imageRollout.path)
    }

    func testInlineImagePayloadKeepsTheCanonicalPathAndSurvivesEviction() throws {
        let canonical = try placeCompressedImageRollout()
        let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
        let images = SessionInlineImageMapper.imagesByUserBlockIndex(for: session).values.flatMap { $0 }
        let image = try XCTUnwrap(images.first)
        guard case .base64(let sourceURL, _) = image.payload else { return XCTFail("expected a base64 payload") }
        XCTAssertEqual(sourceURL.path, canonical.path, "the payload names the session, not the cache copy")

        // Evict the decoded copy, as the 1 GB cap would; reading must rebuild it.
        let copy = try CodexRolloutStorage.randomAccessURL(for: canonical)
        try fm.removeItem(at: copy)
        let decoded = try CodexSessionImagePayload.decodeImageData(payload: image.payload, maxDecodedBytes: 1_000_000)
        defer { try? fm.removeItem(at: copy) }
        XCTAssertEqual(decoded.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(decoded.count, 75)
    }

    func testFileSizeIsTheExactDecodedSizeWithBlankLinesAndNoFinalNewline() throws {
        let canonical = try placeCompressedImageRollout()
        let decodedSize = try CodexRolloutStorage.readAllData(for: canonical).count
        XCTAssertEqual(decodedSize, 754)
        let indexer = SessionIndexer()
        XCTAssertEqual(try XCTUnwrap(indexer.parseFileFull(at: canonical)).fileSizeBytes, decodedSize)
        XCTAssertEqual(try XCTUnwrap(indexer.parseFile(at: canonical)).fileSizeBytes, decodedSize,
                       "the list row and the full parse agree")
    }

    func testLightweightParseReadsOnlyTheHeadOfACompressedRollout() throws {
        // Cut the stream in its second half. The head still decodes; a reader that
        // decoded the whole stream for a tail would fail on the cut.
        let canonical = try dayDirectory().appendingPathComponent(rolloutName)
        let full = try Data(contentsOf: compressedFixture)
        let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
        try full.prefix(full.count * 3 / 4).write(to: sibling)
        let mtime = Date(timeIntervalSince1970: 1_790_000_000)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: sibling.path)

        let preview = try XCTUnwrap(SessionIndexer().parseFile(at: canonical))
        XCTAssertGreaterThan(preview.eventCount, 0)
        XCTAssertEqual(preview.fileSizeBytes, 781_026, "the frame header's decoded size")
        XCTAssertEqual(preview.endTime, mtime, "Codex keeps the mtime, so it stands in for the last event")
    }

    func testReloadKeepsALoadedTranscriptWhenTheCompressedStreamIsDamaged() throws {
        let canonical = try placeCompressedRollout()
        let indexer = SessionIndexer()
        let good = try XCTUnwrap(indexer.parseFileFull(at: canonical))
        XCTAssertGreaterThan(good.events.count, 10)
        indexer.installSessionsForReloadTesting([good])

        let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
        let full = try Data(contentsOf: sibling)
        try full.prefix(full.count / 2).write(to: sibling)

        indexer.reloadSession(id: good.id, force: true, reason: .manualRefresh)
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: good.id, timeout: 10))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let current = try XCTUnwrap(indexer.allSessions.first(where: { $0.id == good.id }))
        XCTAssertEqual(current.events.count, good.events.count)
        XCTAssertEqual(current.events.last?.id, good.events.last?.id)
    }

    // MARK: - Second review fixes (2026-10-14)

    private func withIsolatedArchives(_ body: (URL, SessionArchiveManager) throws -> Void) throws {
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider }
        try body(appSupport, SessionArchiveManager.shared)
    }

    func testCompressedUpstreamWithNewerBytesReplacesAnOlderArchive() throws {
        try withIsolatedArchives { appSupport, manager in
            // Version A is pinned while plain.
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            let versionA = try CodexRolloutStorage.readAllData(for: try placeCompressedImageRollout())
            try versionA.write(to: canonical)
            let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }
            let archived = appSupport.appendingPathComponent(
                "AgentSessions/Archives/codex/\(session.id)/data/\(rolloutName)")
            XCTAssertEqual(try Data(contentsOf: archived), versionA)

            // While the app is not running, Codex resumes the session (version B) and
            // later compresses it again, deleting the plain file.
            try fm.removeItem(at: canonical)
            try fm.copyItem(at: compressedFixture, to: CodexRolloutStorage.compressedSibling(of: canonical))
            manager.syncSessionForTesting(session)

            XCTAssertEqual(try Data(contentsOf: archived), try decodedFixtureBytes(),
                           "the archive follows the compressed upstream, not the older pin")
            XCTAssertNil(manager.archiveInfoForTesting(source: .codex, id: session.id)?.lastError)
        }
    }

    func testPinningDoesNotFollowASymlinkedCompressedRollout() throws {
        try withIsolatedArchives { appSupport, manager in
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            try fm.createSymbolicLink(at: CodexRolloutStorage.compressedSibling(of: canonical),
                                      withDestinationURL: compressedFixture)
            XCTAssertTrue(CodexRolloutStorage.isStoredCompressed(canonical))
            XCTAssertThrowsError(try CodexRolloutStorage.decodedTemporaryCopy(for: canonical))

            let session = Session(id: "codex-zst-symlink-\(UUID().uuidString)", source: .codex,
                                  startTime: nil, endTime: nil, model: nil, filePath: canonical.path,
                                  eventCount: 0, events: [], cwd: nil, repoName: nil, lightweightTitle: nil)
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }
            let archived = appSupport.appendingPathComponent(
                "AgentSessions/Archives/codex/\(session.id)/data/\(rolloutName)")
            XCTAssertFalse(fm.fileExists(atPath: archived.path), "no bytes are archived through a symlink")
        }
    }

    func testOldCodexCannotLaunchACompressedSessionThatNeedsAnExplicitPath() {
        // A CLI without resume-by-ID needs a plain file for the explicit path.
        XCTAssertFalse(CodexResumeSheet.canLaunch(fileMissing: false, hasBinary: true, requiresFallback: true,
                                                  usesFallback: true, supportsResumeByID: false,
                                                  hasPlainFallbackFile: false))
        XCTAssertTrue(CodexResumeSheet.canLaunch(fileMissing: false, hasBinary: true, requiresFallback: true,
                                                 usesFallback: true, supportsResumeByID: false,
                                                 hasPlainFallbackFile: true))
        // A CLI that resumes by ID launches a compressed session; Codex restores it.
        XCTAssertTrue(CodexResumeSheet.canLaunch(fileMissing: false, hasBinary: true, requiresFallback: false,
                                                 usesFallback: false, supportsResumeByID: true,
                                                 hasPlainFallbackFile: false))
    }

    func testLightweightSizeIsMeasuredWhenTheHeaderHasNoSize() throws {
        let canonical = try dayDirectory().appendingPathComponent(rolloutName)
        let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
        try fm.copyItem(at: compressedFixture.deletingLastPathComponent()
                            .appendingPathComponent("small-nosize.jsonl.zst"),
                        to: sibling)
        XCTAssertNil(CodexRolloutStorage.frameContentSize(of: sibling))
        let preview = try XCTUnwrap(SessionIndexer().parseFile(at: canonical))
        // A small stored file is decoded to its end, so the size is exact rather than
        // a head-ratio estimate (zstd buffers input ahead, which skews that ratio).
        XCTAssertEqual(preview.fileSizeBytes, 781_026)
    }

    func testLightweightParseOfABoundedCompressedRolloutSeesALateModelSwitch() throws {
        let canonical = try dayDirectory()
            .appendingPathComponent("rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca33.jsonl")
        try fm.copyItem(at: compressedFixture.deletingLastPathComponent()
                            .appendingPathComponent("model-switch.jsonl.zst"),
                        to: CodexRolloutStorage.compressedSibling(of: canonical))
        let preview = try XCTUnwrap(SessionIndexer().parseFile(at: canonical))
        XCTAssertEqual(preview.model, "gpt-late-model")
    }

    // MARK: - Third review fixes (2026-10-14)

    private func fixture(_ name: String) -> URL {
        compressedFixture.deletingLastPathComponent().appendingPathComponent(name)
    }

    func testPlainToCompressedWithTheSameBytesIsANoOpForTheArchive() throws {
        try withIsolatedArchives { appSupport, manager in
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            let bytes = try decodedFixtureBytes()
            try bytes.write(to: canonical)
            let mtime = Date(timeIntervalSince1970: 1_789_000_000.25)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: canonical.path)
            let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }
            let before = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))

            // Codex compresses the same bytes and keeps the mtime.
            try fm.removeItem(at: canonical)
            let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
            try fm.copyItem(at: compressedFixture, to: sibling)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: sibling.path)

            var snapshotTaken = false
            SessionArchiveManagerTestHooks.preSnapshotHook = { snapshotTaken = true }
            defer { SessionArchiveManagerTestHooks.preSnapshotHook = nil }
            manager.syncSessionForTesting(session)

            XCTAssertFalse(snapshotTaken, "a matching compressed upstream needs no decode or copy")
            let after = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
            XCTAssertFalse(after.upstreamMissing)
            XCTAssertNil(after.lastError)
            XCTAssertEqual(after.lastSyncAt, before.lastSyncAt)
            XCTAssertEqual(after.lastUpstreamChangeAt, before.lastUpstreamChangeAt)
            let archived = appSupport.appendingPathComponent(
                "AgentSessions/Archives/codex/\(session.id)/data/\(rolloutName)")
            XCTAssertEqual(try Data(contentsOf: archived), bytes)
        }
    }

    func testAnExistingArchiveIsKeptWhenTheUpstreamBecomesASymlinkedZst() throws {
        try withIsolatedArchives { appSupport, manager in
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            let bytes = try CodexRolloutStorage.readAllData(for: try placeCompressedImageRollout())
            try bytes.write(to: canonical)
            let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }

            try fm.removeItem(at: canonical)
            try fm.createSymbolicLink(at: CodexRolloutStorage.compressedSibling(of: canonical),
                                      withDestinationURL: compressedFixture)
            manager.syncSessionForTesting(session)

            let archived = appSupport.appendingPathComponent(
                "AgentSessions/Archives/codex/\(session.id)/data/\(rolloutName)")
            XCTAssertEqual(try Data(contentsOf: archived), bytes, "the symlink target is never archived")
        }
    }

    func testImagePrefilterAcceptsAJSONEscapedImageURL() throws {
        let canonical = try dayDirectory()
            .appendingPathComponent("rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca32.jsonl")
        try fm.copyItem(at: fixture("image-escaped.jsonl.zst"), to: CodexRolloutStorage.compressedSibling(of: canonical))
        let scanURL = try XCTUnwrap(CodexRolloutStorage.seekableURLForImageScan(forPath: canonical.path),
                                    "data:image\\/png must pass the prefilter, as it passes the scanner")
        try? fm.removeItem(at: scanURL)
    }

    func testSmallCompressedRolloutPastTheHeadLineCapSeesTheLateModelAndLastTimestamp() throws {
        let canonical = try dayDirectory()
            .appendingPathComponent("rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca34.jsonl")
        let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
        try fm.copyItem(at: fixture("small-switch.jsonl.zst"), to: sibling)
        // A much later mtime must not replace the real last event time once the
        // whole rollout was decoded.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: sibling.path)

        let preview = try XCTUnwrap(SessionIndexer().parseFile(at: canonical))
        XCTAssertEqual(preview.model, "gpt-late-model")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(preview.endTime, formatter.date(from: "2026-09-03T14:00:01.000Z"))
    }

    func testUnknownSizeRolloutPastTheDecodeLimitReportsAtLeastTheLimit() throws {
        let canonical = try dayDirectory()
            .appendingPathComponent("rollout-2026-09-03T13-40-47-01a06900-af0b-7d53-a27e-64ee9619ca35.jsonl")
        let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
        try fm.copyItem(at: fixture("nosize-large.jsonl.zst"), to: sibling)
        XCTAssertNil(CodexRolloutStorage.frameContentSize(of: sibling))
        let preview = try XCTUnwrap(SessionIndexer().parseFile(at: canonical))
        XCTAssertGreaterThanOrEqual(preview.fileSizeBytes ?? 0, 16 * 1024 * 1024,
                                    "28.5 MB decoded from 2.6 KB stored is not reported as a small file")
    }

    func testExplicitFallbackNeedsAPlainFileEvenOnACurrentCodex() {
        XCTAssertFalse(CodexResumeSheet.canLaunch(fileMissing: false, hasBinary: true, requiresFallback: false,
                                                  usesFallback: true, supportsResumeByID: true,
                                                  hasPlainFallbackFile: false))
    }

    // MARK: - Fourth review fixes (2026-10-14)

    func testHeaderProbeRejectsSymlinksAndFIFOsWithoutOpeningThem() throws {
        let day = try dayDirectory()
        let regular = day.appendingPathComponent("rollout-regular.jsonl.zst")
        try fm.copyItem(at: compressedFixture, to: regular)
        XCTAssertEqual(CodexRolloutStorage.regularCompressedFileInfo(at: regular)?.decodedSize, 781_026)

        let link = day.appendingPathComponent("rollout-link.jsonl.zst")
        try fm.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertNil(CodexRolloutStorage.regularCompressedFileInfo(at: link), "a symlink is never followed")

        // A FIFO would block a plain open() until a writer appears; this must return.
        let fifo = day.appendingPathComponent("rollout-fifo.jsonl.zst")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(CodexRolloutStorage.regularCompressedFileInfo(at: fifo))
        let fifoTarget = day.appendingPathComponent("rollout-to-fifo.jsonl.zst")
        try fm.createSymbolicLink(at: fifoTarget, withDestinationURL: fifo)
        XCTAssertNil(CodexRolloutStorage.regularCompressedFileInfo(at: fifoTarget))
    }

    func testMatchingCompressedSyncClearsAnEarlierErrorStatus() throws {
        try withIsolatedArchives { _, manager in
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            try decodedFixtureBytes().write(to: canonical)
            let mtime = Date(timeIntervalSince1970: 1_789_000_000.5)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: canonical.path)
            let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }

            // A symlinked `.zst` is refused and leaves the archive in `.error`.
            try fm.removeItem(at: canonical)
            let sibling = CodexRolloutStorage.compressedSibling(of: canonical)
            try fm.createSymbolicLink(at: sibling, withDestinationURL: compressedFixture)
            manager.syncSessionForTesting(session)
            XCTAssertEqual(manager.archiveInfoForTesting(source: .codex, id: session.id)?.status, .error)

            // The real compressed file, same bytes and mtime: the match recovers the status.
            try fm.removeItem(at: sibling)
            try fm.copyItem(at: compressedFixture, to: sibling)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: sibling.path)
            manager.syncSessionForTesting(session)
            let recovered = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
            XCTAssertTrue(recovered.status == .syncing || recovered.status == .final, "status \(recovered.status)")
            XCTAssertNil(recovered.lastError, "the old failure message is not shown after recovery")
        }
    }

    func testPlainNoOpSyncClearsAnEarlierErrorMessage() throws {
        try withIsolatedArchives { _, manager in
            let canonical = try dayDirectory().appendingPathComponent(rolloutName)
            let bytes = try decodedFixtureBytes()
            try bytes.write(to: canonical)
            let mtime = Date(timeIntervalSince1970: 1_789_000_000.75)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: canonical.path)
            let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
            manager.pinSessionForTesting(session)
            defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }

            // A symlinked plain upstream is refused by the no-follow copy.
            let real = canonical.deletingLastPathComponent().appendingPathComponent("real-target.jsonl")
            try fm.moveItem(at: canonical, to: real)
            try fm.createSymbolicLink(at: canonical, withDestinationURL: real)
            manager.syncSessionForTesting(session)
            let failed = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
            XCTAssertEqual(failed.status, .error)
            XCTAssertNotNil(failed.lastError)

            // The regular file is back with the same bytes and mtime: an ordinary no-op.
            try fm.removeItem(at: canonical)
            try fm.moveItem(at: real, to: canonical)
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: canonical.path)
            manager.syncSessionForTesting(session)
            let recovered = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
            XCTAssertTrue(recovered.status == .syncing || recovered.status == .final, "status \(recovered.status)")
            XCTAssertNil(recovered.lastError)
        }
    }

    func testPinningACompressedOnlyRolloutArchivesItsDecodedBytes() throws {
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider }

        let canonical = try placeCompressedRollout()
        let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: canonical))
        let manager = SessionArchiveManager.shared
        manager.pinSessionForTesting(session)
        defer { manager.deleteArchiveForTesting(source: .codex, id: session.id) }

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
        XCTAssertNil(info.lastError, info.lastError ?? "")
        XCTAssertFalse(info.upstreamMissing)
        let archived = appSupport.appendingPathComponent(
            "AgentSessions/Archives/codex/\(session.id)/data/\(rolloutName)")
        XCTAssertEqual(try Data(contentsOf: archived), try decodedFixtureBytes())

        // Codex (or the user) later deletes the compressed upstream: the pin holds.
        try fm.removeItem(at: CodexRolloutStorage.compressedSibling(of: canonical))
        manager.syncSessionForTesting(session)
        let after = try XCTUnwrap(manager.archiveInfoForTesting(source: .codex, id: session.id))
        XCTAssertTrue(after.upstreamMissing)
        XCTAssertEqual(after.status, .final)
        XCTAssertEqual(try Data(contentsOf: archived), try decodedFixtureBytes())
    }
}
