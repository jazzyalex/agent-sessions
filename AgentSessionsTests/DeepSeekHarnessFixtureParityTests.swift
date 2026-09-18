import CryptoKit
import Foundation
import XCTest
@testable import AgentSessions

/// Differential parity tests for the checked-in, pinned DSH stage-0 corpus.
///
/// The expected JSON is the canonical output captured from the pinned DSH
/// catalog. These tests deliberately exercise only the production Swift
/// reader and historical normalizer; they never invoke the generator or a
/// sibling checkout.
final class DeepSeekHarnessFixtureParityTests: XCTestCase {
    private static let expectedCommit = "ddefc45fbc7f8e46dd73185e68295696d1297887"
    private static let acceptedFiles = [
        "v0_minimal_session.jsonl",
        "v1_minimal_session.jsonl",
        "v2_minimal_session.jsonl",
        "v3_minimal_session.jsonl",
        "unknown_ignorable_event.jsonl",
    ]

    private func fixtureDir() throws -> URL {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/stage0/agents/deepseek-harness", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        return dir
    }

    private func readUTF8(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
                as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private func manifest(in dir: URL) throws -> [String: Any] {
        try jsonObject(try readUTF8(dir.appendingPathComponent("manifest.json")))
    }

    private func manifestEntries(_ manifest: [String: Any]) throws -> [[String: Any]] {
        guard let entries = manifest["fixtures"] as? [[String: Any]], !entries.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return entries
    }

    private func manifestEntry(_ file: String, in entries: [[String: Any]]) throws -> [String: Any] {
        guard let entry = entries.first(where: { $0["file"] as? String == file }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectedEntry(_ file: String, in expected: [String: Any]) throws -> [String: Any] {
        guard let fixtures = expected["fixtures"] as? [String: Any],
              let entry = fixtures[file] as? [String: Any] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return entry
    }

    private func stableRepresentation(
        result: DeepSeekHarnessParseResult,
        events: [DeepSeekHarnessNormalizedEvent]
    ) throws -> Data {
        let header = DeepSeekHarnessHistoricalNormalizer.normalizedHeader(result.header)
        var headerObject: [String: Any] = [
            "version": header.version,
            "id": header.id,
            "createdAt": header.createdAtMilliseconds,
            "isSeeded": header.isSeeded,
            "delegationDepth": header.delegationDepth,
        ]
        if let cwd = header.cwd { headerObject["cwd"] = cwd }
        if let parent = header.parentSessionID { headerObject["parentSession"] = parent }
        if let origin = header.origin { headerObject["origin"] = origin }
        if let preset = header.agentPreset { headerObject["agentPreset"] = preset }

        let eventObjects: [[String: Any]] = events.map { item in
            let envelope = item.envelope
            var object: [String: Any] = [
                "type": envelope.type,
                "seq": envelope.sequence,
                "time": envelope.timeMilliseconds,
                "data": envelope.data,
            ]
            if envelope.ignorable { object["ignorable"] = true }
            if let sourceEventSeqs = envelope.sourceEventSeqs {
                object["sourceEventSeqs"] = sourceEventSeqs
            }
            if let surfaceOp = envelope.surfaceOp {
                object["surfaceOp"] = surfaceOp.canonicalV3().rawValue()
            }
            return object
        }

        let representation: [String: Any] = [
            "header": headerObject,
            "events": eventObjects,
            "inheritedEventCount": result.inheritedEventCount,
        ]
        guard let canonical = DeepSeekHarnessJSON.canonicalString(representation) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Data(canonical.utf8)
    }

    func testManifestPinsSourceCommitAndEveryCorpusHash() throws {
        let dir = try fixtureDir()
        let manifest = try manifest(in: dir)
        XCTAssertEqual(manifest["sourceCommit"] as? String, Self.expectedCommit)

        let entries = try manifestEntries(manifest)
        let listedFixtures = Set(entries.compactMap { $0["file"] as? String })
        let onDiskFixtures = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".jsonl") })
        XCTAssertEqual(listedFixtures, onDiskFixtures, "manifest inventory must match committed JSONL fixtures")

        guard let expectedDescriptor = manifest["expectedNormalizedV3"] as? [String: Any],
              let expectedFile = expectedDescriptor["file"] as? String,
              let expectedHash = expectedDescriptor["sha256"] as? String else {
            return XCTFail("manifest is missing normalized_v3_expected metadata")
        }
        let expectedURL = dir.appendingPathComponent(expectedFile)
        let expectedData = try Data(contentsOf: expectedURL)
        XCTAssertEqual(sha256Hex(expectedData), expectedHash.lowercased(), expectedFile)
        let expected = try jsonObject(String(decoding: expectedData, as: UTF8.self))
        XCTAssertEqual(expected["sourceCommit"] as? String, Self.expectedCommit)

        for entry in entries {
            guard let file = entry["file"] as? String,
                  let hash = entry["sha256"] as? String,
                  let outcome = entry["expectedOutcome"] as? String else {
                return XCTFail("manifest entry is missing file/hash/outcome: \(entry)")
            }
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            XCTAssertEqual(sha256Hex(data), hash.lowercased(), file)

            if outcome.hasPrefix("accept:") {
                XCTAssertEqual(entry["expectedNormalizedV3"] as? String, expectedFile, file)
            } else {
                XCTAssertNil(entry["expectedNormalizedV3"], file)
            }
        }
    }

    func testAcceptedFixturesMatchCanonicalNormalizedV3AndRepeatDeterministically() throws {
        let dir = try fixtureDir()
        let manifest = try manifest(in: dir)
        let entries = try manifestEntries(manifest)
        let expectedFile = try XCTUnwrap((manifest["expectedNormalizedV3"] as? [String: Any])?["file"] as? String)
        let expectedData = try Data(contentsOf: dir.appendingPathComponent(expectedFile))
        let expected = try jsonObject(String(decoding: expectedData, as: UTF8.self))

        for file in Self.acceptedFiles {
            let entry = try manifestEntry(file, in: entries)
            let outcome = try XCTUnwrap(entry["expectedOutcome"] as? String, file)
            XCTAssertTrue(outcome.hasPrefix("accept:"), file)
            let version = try XCTUnwrap(entry["physicalFormatVersion"] as? Int, file)

            let url = dir.appendingPathComponent(file)
            let result = try DeepSeekHarnessArtifactReader.read(url: url, compression: .plain)
            XCTAssertEqual(result.header.version, version, file)

            let first = try DeepSeekHarnessHistoricalNormalizer.normalize(result)
            let second = try DeepSeekHarnessHistoricalNormalizer.normalize(result)
            let firstBytes = try stableRepresentation(result: result, events: first)
            let secondBytes = try stableRepresentation(result: result, events: second)
            XCTAssertEqual(firstBytes, secondBytes, "normalization must be byte-deterministic: \(file)")

            let expectedObject = try expectedEntry(file, in: expected)
            let expectedCanonical = try XCTUnwrap(
                DeepSeekHarnessJSON.canonicalString(expectedObject),
                file
            )
            XCTAssertEqual(String(decoding: firstBytes, as: UTF8.self), expectedCanonical, file)
        }
    }

    func testUnknownIgnorableEventIsAcceptedWithExplicitDiagnosticDisposition() throws {
        let dir = try fixtureDir()
        let manifest = try manifest(in: dir)
        let entries = try manifestEntries(manifest)
        let entry = try manifestEntry("unknown_ignorable_event.jsonl", in: entries)
        let outcome = try XCTUnwrap(entry["expectedOutcome"] as? String)
        XCTAssertTrue(outcome.localizedCaseInsensitiveContains("retain"))
        XCTAssertTrue(outcome.localizedCaseInsensitiveContains("non-rendered"))

        let result = try DeepSeekHarnessArtifactReader.read(
            url: dir.appendingPathComponent("unknown_ignorable_event.jsonl"),
            compression: .plain
        )
        XCTAssertEqual(result.skippedIgnorableTypes, ["x-synth/unknown-ignorable"])

        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result)
        let retained = normalized.filter { $0.canonicalType == "x-synth/unknown-ignorable" }
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(retained[0].envelope.ignorable)
        XCTAssertTrue(retained[0].diagnosticOnly)
    }

    func testFutureVersionRejectsAtPhysicalRead() throws {
        let dir = try fixtureDir()
        do {
            _ = try DeepSeekHarnessArtifactReader.read(
                url: dir.appendingPathComponent("future_v4_header.jsonl"),
                compression: .plain
            )
            XCTFail("future v4 must be rejected")
        } catch let error as DeepSeekHarnessFormatError {
            XCTAssertEqual(error, .unsupportedVersion(4))
        }
    }

    func testTornTailRejectsAtPhysicalRead() throws {
        let dir = try fixtureDir()
        do {
            _ = try DeepSeekHarnessArtifactReader.read(
                url: dir.appendingPathComponent("malformed_torn_tail.jsonl"),
                compression: .plain
            )
            XCTFail("torn tail must be rejected")
        } catch let error as DeepSeekHarnessFormatError {
            guard case .tornLine = error else {
                return XCTFail("unexpected torn-tail error: \(error)")
            }
        }
    }

    func testSequenceGapRejectsAtPhysicalRead() throws {
        let dir = try fixtureDir()
        do {
            _ = try DeepSeekHarnessArtifactReader.read(
                url: dir.appendingPathComponent("malformed_seq_gap.jsonl"),
                compression: .plain
            )
            XCTFail("sequence gap must be rejected")
        } catch let error as DeepSeekHarnessFormatError {
            XCTAssertEqual(error, .sequence(expected: 3, actual: 4))
        }
    }

    func testUnknownRequiredEventRejectsDuringNormalization() throws {
        let dir = try fixtureDir()
        let result = try DeepSeekHarnessArtifactReader.read(
            url: dir.appendingPathComponent("unknown_required_event.jsonl"),
            compression: .plain
        )
        do {
            _ = try DeepSeekHarnessHistoricalNormalizer.normalize(result)
            XCTFail("unknown required event must be rejected")
        } catch let error as DeepSeekHarnessFormatError {
            XCTAssertEqual(error, .unknownRequiredEvent("x-synth/unknown-required"))
        }
    }
}
