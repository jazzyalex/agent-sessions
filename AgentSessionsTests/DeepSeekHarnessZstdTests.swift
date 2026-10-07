import Foundation
import XCTest
@testable import AgentSessions

final class DeepSeekHarnessZstdTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DeepSeekHarnessZstdTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: directory)
        }
        return directory
    }

    private func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func headerLine(version: Int = 3, id: String = "zstd-session") throws -> Data {
        try jsonLine([
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": 1_700_000_000_000,
            "cwd": "/tmp/dsh-zstd",
            "isSeeded": false,
            "delegationDepth": 0,
        ])
    }

    private func eventLine(sequence: Int, type: String = "turn/start") throws -> Data {
        try jsonLine([
            "type": type,
            "seq": sequence,
            "time": 1_700_000_000_001 + sequence,
            "data": [:] as [String: Any],
        ])
    }

    // These frames were generated once with the official zstd 1.5.7 CLI at
    // compression level 3 and --no-check.  Keeping the compressed fixtures
    // here makes this test independent of the decompression-only vendored
    // target, which intentionally does not compile zstd's compression code.
    private static let headerFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x4D, 0x03, 0x00, 0x12, 0x07, 0x17, 0x1A, 0x70, 0x8B, 0x3A,
        0x40, 0xE2, 0x2B, 0x41, 0xB6, 0xE5, 0x02, 0xEB, 0x8F, 0xB1, 0x7A, 0xC4, 0x55, 0xBE, 0xE7, 0xF3,
        0x79, 0xD2, 0x3C, 0x4B, 0x3F, 0xF7, 0x70, 0x80, 0x87, 0xE0, 0xA2, 0x2B, 0x7A, 0xFD, 0x62, 0x64,
        0xED, 0xE8, 0xA4, 0xC3, 0xD5, 0xF7, 0x6F, 0x40, 0x55, 0xEB, 0x03, 0x29, 0xC4, 0x23, 0xE2, 0xC4,
        0x46, 0xAF, 0x56, 0x35, 0xE5, 0xDA, 0xE4, 0x7A, 0xE1, 0x81, 0x54, 0x26, 0xC4, 0x9D, 0xBB, 0x56,
        0x27, 0x36, 0x90, 0x06, 0x9D, 0x2C, 0x2B, 0x91, 0xC9, 0xD2, 0xAB, 0x17, 0x4C, 0x4D, 0x19, 0x04,
        0xAE, 0x49, 0xF0, 0x33, 0x3D, 0x62, 0xEA, 0x08, 0x03, 0x00, 0x4F, 0x89, 0xD1, 0x8A, 0xDA, 0xC6,
        0x06, 0xC0,
    ])

    private static let event0Frame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0xF1, 0x01, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x30, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x74, 0x75, 0x72, 0x6E, 0x5C, 0x2F, 0x73,
        0x74, 0x61, 0x72, 0x74, 0x22, 0x7D, 0x0A,
    ])

    private static let event1EndFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0xE1, 0x01, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x31, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x74, 0x75, 0x72, 0x6E, 0x5C, 0x2F, 0x65,
        0x6E, 0x64, 0x22, 0x7D, 0x0A,
    ])

    private static let event0UserFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x01, 0x02, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x30, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x75, 0x73, 0x65, 0x72, 0x5C, 0x2F, 0x6D,
        0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x7D, 0x0A,
    ])

    private static let event1UserFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x01, 0x02, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x31, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x75, 0x73, 0x65, 0x72, 0x5C, 0x2F, 0x6D,
        0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x7D, 0x0A,
    ])

    private static let event1AssistantFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x29, 0x02, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x31, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x61, 0x73, 0x73, 0x69, 0x73, 0x74, 0x61,
        0x6E, 0x74, 0x5C, 0x2F, 0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x7D, 0x0A,
    ])

    private static let xFrame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x09, 0x00, 0x00, 0x78])

    private static let headerAndEvent0Frame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x3D, 0x04, 0x00, 0x32, 0x89, 0x1C, 0x1B, 0x70, 0xA9, 0x3A,
        0x60, 0x10, 0x90, 0x96, 0x32, 0xBC, 0x1F, 0x70, 0x8B, 0x74, 0xB4, 0x17, 0xB1, 0x2A, 0xD8, 0xE1,
        0x2B, 0x33, 0x1B, 0x3E, 0x4B, 0x3F, 0x7D, 0x6B, 0x46, 0xE5, 0x6D, 0x6B, 0x15, 0x59, 0xA0, 0x86,
        0x58, 0xE5, 0x0F, 0xDB, 0xC3, 0xD5, 0x57, 0x51, 0xE8, 0xB5, 0x2B, 0x4D, 0x19, 0x15, 0x00, 0xDB,
        0x13, 0x46, 0x5F, 0x5A, 0xAC, 0xEF, 0xEA, 0xAC, 0x02, 0x3A, 0x9F, 0x3F, 0x41, 0x99, 0xCF, 0x50,
        0xC4, 0x54, 0xAF, 0x47, 0xAE, 0x4E, 0x46, 0x27, 0xF3, 0x25, 0xE8, 0x66, 0xA5, 0x0F, 0xA0, 0x88,
        0xED, 0x32, 0xDC, 0x79, 0xFA, 0x9C, 0xAB, 0xD3, 0xD1, 0x68, 0x22, 0x8B, 0xF4, 0x2C, 0xB2, 0x18,
        0x9D, 0x0A, 0xC6, 0x97, 0x04, 0x14, 0xF4, 0x0A, 0xF2, 0xBB, 0xDE, 0x18, 0x53, 0x01, 0x06, 0x00,
        0x49, 0x14, 0x42, 0x63, 0x92, 0xCC, 0x82, 0x84, 0xA7, 0xAE, 0xD3, 0x8A, 0xDA, 0xD1, 0x06, 0x96,
    ])

    // This is the same event frame with the standard XXH64 content checksum
    // enabled.  It is used only to prove that checksum corruption is rejected.
    private static let event0ChecksumFrame = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0xF1, 0x01, 0x00, 0x7B, 0x22, 0x64, 0x61, 0x74, 0x61, 0x22,
        0x3A, 0x7B, 0x7D, 0x2C, 0x22, 0x73, 0x65, 0x71, 0x22, 0x3A, 0x30, 0x2C, 0x22, 0x74, 0x69, 0x6D,
        0x65, 0x22, 0x3A, 0x31, 0x37, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31,
        0x2C, 0x22, 0x74, 0x79, 0x70, 0x65, 0x22, 0x3A, 0x22, 0x74, 0x75, 0x72, 0x6E, 0x5C, 0x2F, 0x73,
        0x74, 0x61, 0x72, 0x74, 0x22, 0x7D, 0x0A, 0x10, 0x32, 0xF2, 0xAA,
    ])

    private static let exactLimitHeaderFrame = Data(
        base64Encoded: """
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
""",
        options: .ignoreUnknownCharacters
    )!

    private static let overLimitHeaderFrame = Data(
        base64Encoded: """
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
""",
        options: .ignoreUnknownCharacters
    )!

    private func zstdFrame(_ data: Data) throws -> Data {
        if data == (try headerLine()) { return Self.headerFrame }
        if data == (try eventLine(sequence: 0)) { return Self.event0Frame }
        if data == (try eventLine(sequence: 1, type: "turn/end")) { return Self.event1EndFrame }
        if data == (try eventLine(sequence: 0, type: "user/message")) { return Self.event0UserFrame }
        if data == (try eventLine(sequence: 1, type: "user/message")) { return Self.event1UserFrame }
        if data == (try eventLine(sequence: 1, type: "assistant/message")) { return Self.event1AssistantFrame }
        if data == Data("x".utf8) { return Self.xFrame }
        if data == (try headerLine()) + (try eventLine(sequence: 0)) { return Self.headerAndEvent0Frame }
        throw NSError(domain: "DeepSeekHarnessZstdTests", code: 1)
    }

    private func artifactURL(in directory: URL, name: String = "session.jsonl.zstd") -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func paddedHeaderLine(jsonBytes: Int) throws -> Data {
        var id = ""
        while true {
            let data = try jsonLine([
                "type": "session",
                "version": 3,
                "id": id,
                "createdAt": 1_700_000_000_000,
                "cwd": "/tmp/dsh-zstd",
                "isSeeded": false,
                "delegationDepth": 0,
            ])
            let delta = (jsonBytes + 1) - data.count
            if delta == 0 { return data }
            if delta > 0 {
                id.append(contentsOf: String(repeating: "x", count: delta))
            } else {
                id.removeLast(-delta)
            }
        }
    }

    private func rowCanonicalValues(_ result: DeepSeekHarnessParseResult) throws -> [String] {
        try result.rows.map { row in
            switch row {
            case .event(let envelope):
                return try XCTUnwrap(DeepSeekHarnessJSON.canonicalString(envelope.rawObject))
            case .packed(let run):
                return try XCTUnwrap(DeepSeekHarnessJSON.canonicalString(run.rawObject))
            }
        }
    }

    func testConcatenatedFramesDecodeAtIndependentFrameBoundaries() throws {
        let first = try zstdFrame(headerLine())
        let second = try zstdFrame(eventLine(sequence: 0))
        let third = try zstdFrame(eventLine(sequence: 1, type: "turn/end"))
        var bytes = Data()
        bytes.append(first)
        bytes.append(second)
        bytes.append(third)

        let frames = try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.index), [0, 1, 2])
        XCTAssertEqual(frames[0].decoded, try headerLine())
        XCTAssertEqual(frames[1].decoded, try eventLine(sequence: 0))
        XCTAssertEqual(frames[2].decoded, try eventLine(sequence: 1, type: "turn/end"))
        XCTAssertEqual(frames[1].compressedOffset, first.count)
        XCTAssertEqual(frames[2].compressedOffset, first.count + second.count)
    }

    func testFirstFrameMustContainExactlyOneHeaderRecord() throws {
        var firstFramePayload = try headerLine()
        firstFramePayload.append(try eventLine(sequence: 0))
        var bytes = try zstdFrame(firstFramePayload)
        bytes.append(try zstdFrame(eventLine(sequence: 1, type: "turn/end")))
        let url = artifactURL(in: try temporaryDirectory())
        try write(bytes, to: url)

        XCTAssertThrowsError(try DeepSeekHarnessArtifactReader.read(url: url, compression: .zstd)) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError, .firstFrameHeaderViolation)
        }
    }

    func testExactAndOverHeaderLimitsApplyToHeaderAndFullReads() throws {
        let directory = try temporaryDirectory()
        let exactPlain = artifactURL(in: directory, name: "exact.jsonl")
        let overPlain = artifactURL(in: directory, name: "over.jsonl")
        try write(try paddedHeaderLine(jsonBytes: 1 * 1024 * 1024), to: exactPlain)
        try write(try paddedHeaderLine(jsonBytes: 1 * 1024 * 1024 + 1), to: overPlain)

        let exactZstd = artifactURL(in: directory, name: "exact.jsonl.zstd")
        let overZstd = artifactURL(in: directory, name: "over.jsonl.zstd")
        try write(Self.exactLimitHeaderFrame, to: exactZstd)
        try write(Self.overLimitHeaderFrame, to: overZstd)

        for (compression, exactURL, overURL) in [
            (DeepSeekHarnessCompression.plain, exactPlain, overPlain),
            (.zstd, exactZstd, overZstd),
        ] {
            XCTAssertNoThrow(try DeepSeekHarnessArtifactReader.readHeader(
                url: exactURL, compression: compression))
            XCTAssertNoThrow(try DeepSeekHarnessArtifactReader.read(
                url: exactURL, compression: compression))
            XCTAssertThrowsError(try DeepSeekHarnessArtifactReader.readHeader(
                url: overURL, compression: compression))
            XCTAssertThrowsError(try DeepSeekHarnessArtifactReader.read(
                url: overURL, compression: compression))
        }
    }

    func testPlainAndZstandardHeaderLimitsFailClosed() throws {
        let directory = try temporaryDirectory()
        let plainURL = artifactURL(in: directory, name: "oversized.jsonl")
        var oversizedHeader = Data(repeating: 0x20, count: 1 * 1024 * 1024 + 1)
        oversizedHeader.append(0x0A)
        try write(oversizedHeader, to: plainURL)

        XCTAssertThrowsError(
            try DeepSeekHarnessArtifactReader.readHeader(url: plainURL, compression: .plain)
        ) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError,
                           .limitsExceeded("header bytes"))
        }

        let zstdURL = artifactURL(in: directory, name: "header.jsonl.zstd")
        try write(Self.headerFrame, to: zstdURL)
        XCTAssertThrowsError(
            try DeepSeekHarnessZstdFrameReader.readFirstFrame(
                from: zstdURL, decodedByteLimit: 1)
        ) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError,
                           .limitsExceeded("decoded header"))
        }
    }

    func testPlainReadRejectsDescriptorABAReplacementInsteadOfPublishingWrongBytes() throws {
        let directory = try temporaryDirectory()
        let url = artifactURL(in: directory, name: "aba.jsonl")
        let original = try headerLine(id: "original")
        let replacement = try headerLine(id: "replacement")
        try write(original, to: url)

        var didReplace = false
        var didRestore = false
        DeepSeekHarnessArtifactReader.testBeforeReadOpenObserver = {
            guard !didReplace else { return }
            didReplace = true
            try? replacement.write(to: url, options: .atomic)
        }
        DeepSeekHarnessArtifactReader.testAfterReadOpenObserver = {
            guard didReplace, !didRestore else { return }
            didRestore = true
            try? original.write(to: url, options: .atomic)
        }
        defer {
            DeepSeekHarnessArtifactReader.testBeforeReadOpenObserver = nil
            DeepSeekHarnessArtifactReader.testAfterReadOpenObserver = nil
        }

        let result = try DeepSeekHarnessArtifactReader.read(url: url, compression: .plain)
        XCTAssertEqual(result.header.id, "original")
        XCTAssertTrue(didReplace)
        XCTAssertTrue(didRestore)
    }

    func testFullPlainReadCanBeCancelledAfterChunkAcquisitionBegins() async throws {
        let url = artifactURL(in: try temporaryDirectory(), name: "cancel.jsonl")
        var bytes = Data(repeating: 0x20, count: 256 * 1024)
        bytes.append(0x0A)
        try write(bytes, to: url)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DeepSeekHarnessArtifactReader.testReadChunkObserver = {
            entered.signal()
            release.wait()
        }
        let task = Task { () -> Bool in
            do {
                _ = try DeepSeekHarnessArtifactReader.read(url: url, compression: .plain)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        task.cancel()
        release.signal()
        let cancelled = await task.value
        DeepSeekHarnessArtifactReader.testReadChunkObserver = nil
        XCTAssertTrue(cancelled)
    }

    func testCorruptedCompleteFrameIsRefused() throws {
        let first = try zstdFrame(headerLine())
        var corrupted = try zstdFrame(eventLine(sequence: 0))
        XCTAssertGreaterThan(corrupted.count, 4)
        corrupted[0] ^= 0x01
        var bytes = Data(first)
        bytes.append(corrupted)

        XCTAssertThrowsError(try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)) { error in
            XCTAssertEqual(
                error as? DeepSeekHarnessFormatError,
                .corruptFrame(frame: 1, offset: first.count, reason: "missing Zstandard frame header")
            )
        }
    }

    func testChecksumCorruptionIsRefused() throws {
        let valid = try DeepSeekHarnessZstdFrameReader.readFrames(from: Self.event0ChecksumFrame)
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(valid[0].decoded, try eventLine(sequence: 0))

        var corrupted = Self.event0ChecksumFrame
        corrupted[corrupted.count - 1] ^= 0x01

        XCTAssertThrowsError(try DeepSeekHarnessZstdFrameReader.readFrames(from: corrupted)) { error in
            guard case .corruptFrame(let frame, _, let reason) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("Expected checksum corruption to be rejected, got \(error)")
            }
            XCTAssertEqual(frame, 0)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testIncompleteFinalFrameIsRefused() throws {
        let first = try zstdFrame(headerLine())
        var torn = try zstdFrame(eventLine(sequence: 0))
        torn.removeLast()
        var bytes = Data(first)
        bytes.append(torn)

        XCTAssertThrowsError(try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)) { error in
            XCTAssertEqual(
                error as? DeepSeekHarnessFormatError,
                .incompleteFrame(frame: 1, offset: first.count)
            )
        }
    }

    func testShortFinalMagicTailIsClassifiedAsIncompleteFrame() throws {
        let first = try zstdFrame(headerLine())
        let magicPrefix: [UInt8] = [0x28, 0xB5, 0x2F]

        for byteCount in 1...3 {
            var bytes = Data(first)
            bytes.append(contentsOf: magicPrefix.prefix(byteCount))

            XCTAssertThrowsError(try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)) { error in
                XCTAssertEqual(
                    error as? DeepSeekHarnessFormatError,
                    .incompleteFrame(frame: 1, offset: first.count),
                    "a (byteCount)-byte final magic prefix is an incomplete next frame"
                )
            }
        }
    }

    func testFrameCountLimitIsEnforced() throws {
        let frame = try zstdFrame(Data("x".utf8))
        var bytes = Data(capacity: frame.count * (DeepSeekHarnessZstdFrameReader.maxFrames + 1))
        for _ in 0...DeepSeekHarnessZstdFrameReader.maxFrames {
            bytes.append(frame)
        }

        XCTAssertThrowsError(try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError, .limitsExceeded("frame count"))
        }
    }

    func testPlainAndZstandardArtifactsHaveSemanticParity() throws {
        let directory = try temporaryDirectory()
        let plainURL = artifactURL(in: directory, name: "plain.jsonl")
        let zstdURL = artifactURL(in: directory, name: "compressed.jsonl.zstd")

        let lines = [
            try headerLine(),
            try eventLine(sequence: 0, type: "user/message"),
            try eventLine(sequence: 1, type: "assistant/message"),
        ]
        var plainBytes = Data()
        var compressedBytes = Data()
        for line in lines {
            plainBytes.append(line)
            compressedBytes.append(try zstdFrame(line))
        }
        try write(plainBytes, to: plainURL)
        try write(compressedBytes, to: zstdURL)

        let plain = try DeepSeekHarnessArtifactReader.read(url: plainURL, compression: .plain)
        let compressed = try DeepSeekHarnessArtifactReader.read(url: zstdURL, compression: .zstd)
        XCTAssertEqual(compressed.header, plain.header)
        XCTAssertEqual(compressed.inheritedEventCount, plain.inheritedEventCount)
        XCTAssertEqual(compressed.skippedIgnorableTypes, plain.skippedIgnorableTypes)
        XCTAssertEqual(compressed.incompleteTurn, plain.incompleteTurn)
        XCTAssertEqual(try rowCanonicalValues(compressed), try rowCanonicalValues(plain))
    }
}
