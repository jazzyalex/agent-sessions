import XCTest
@testable import AgentSessions

final class SearchSourceScannerTests: XCTestCase {
    private func fixture(_ records: [[String: Any]], source: SessionSource = .claude) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.jsonl")
        let data = try records.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        try data.write(to: file)
        return Session(id: "synthetic", source: source, startTime: nil, endTime: nil, model: nil,
            filePath: file.path, fileSizeBytes: data.count, eventCount: records.count, events: [],
            cwd: nil, repoName: nil, lightweightTitle: "Synthetic fixture")
    }
    private func message(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }
    private func scan(_ session: Session, _ query: String) async throws -> SearchScanResult {
        let tokenizer = try SearchTokenizer()
        return await SearchSourceScanner.scan(session: session, query: try SearchQuery(query, tokenizer: tokenizer))
    }

    private func openCodeFixture(v2: Bool, unrelatedLegacyParts: Int = 0,
                                 largeForeignPartBytes: Int = 0) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = directory.appendingPathComponent("storage", isDirectory: true)
        let sessionDirectory = storage.appendingPathComponent("session/project", isDirectory: true)
        let messageDirectory = storage.appendingPathComponent("message/ses_search", isDirectory: true)
        let partDirectory = v2
            ? storage.appendingPathComponent("part/msg_search", isDirectory: true)
            : storage.appendingPathComponent("part", isDirectory: true)
        for item in [sessionDirectory, messageDirectory, partDirectory] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let sessionURL = sessionDirectory.appendingPathComponent("ses_search.json")
        try #"{"id":"ses_search","directory":"/tmp/project","title":"Search fixture"}"#
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        try #"{"id":"msg_search","sessionID":"ses_search","role":"assistant"}"#
            .write(to: messageDirectory.appendingPathComponent("msg_search.json"), atomically: true, encoding: .utf8)
        try #"{"id":"prt_search","messageID":"msg_search","type":"text","text":"splitfileuniqueneedle"}"#
            .write(to: partDirectory.appendingPathComponent("prt_search.json"), atomically: true, encoding: .utf8)
        if !v2, unrelatedLegacyParts > 0 {
            let padding = String(repeating: "x", count: 48 * 1024)
            for index in 0..<unrelatedLegacyParts {
                let foreign = "{\"id\":\"foreign_\(index)\",\"messageID\":\"foreign_message_\(index)\",\"type\":\"text\",\"text\":\"\(padding)\"}"
                try foreign.write(
                    to: partDirectory.appendingPathComponent("prt_foreign_\(index).json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        if !v2, largeForeignPartBytes > 0 {
            let foreign = "{\"id\":\"large_foreign\",\"messageID\":\"foreign_large\",\"type\":\"text\",\"text\":\"\(String(repeating: "y", count: largeForeignPartBytes))\"}"
            try foreign.write(
                to: partDirectory.appendingPathComponent("prt_large_foreign.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        if v2 {
            try "2\n".write(to: storage.appendingPathComponent("migration"), atomically: true, encoding: .utf8)
        }
        let full = try XCTUnwrap(OpenCodeSessionParser.parseFileFull(at: sessionURL))
        XCTAssertTrue(full.events.contains { $0.text == "splitfileuniqueneedle" }, v2 ? "v2 fixture" : "legacy fixture")
        return try XCTUnwrap(OpenCodeSessionParser.parseFile(at: sessionURL))
    }

    private func markerlessOpenCodeDirectFixture(includeLegacyShadow: Bool) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = directory.appendingPathComponent("storage", isDirectory: true)
        let sessionDirectory = storage.appendingPathComponent("session/project", isDirectory: true)
        let messageDirectory = storage.appendingPathComponent("message/ses_search", isDirectory: true)
        let directPartDirectory = storage.appendingPathComponent("part/msg_search", isDirectory: true)
        for item in [sessionDirectory, messageDirectory, directPartDirectory] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let sessionURL = sessionDirectory.appendingPathComponent("ses_search.json")
        try #"{"id":"ses_search","directory":"/tmp/project","title":"Search fixture"}"#
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        try #"{"id":"msg_search","sessionID":"ses_search","role":"assistant"}"#
            .write(to: messageDirectory.appendingPathComponent("msg_search.json"), atomically: true, encoding: .utf8)
        // Markerless stores still prefer the direct folder. Direct records need neither
        // a prt_ filename nor an embedded messageID.
        try #"{"id":"direct_part","type":"text","text":"markerlessdirectneedle"}"#
            .write(to: directPartDirectory.appendingPathComponent("content.json"), atomically: true, encoding: .utf8)
        if includeLegacyShadow {
            try #"{"id":"legacy_shadow","messageID":"msg_search","type":"text","text":"legacyshadowneedle"}"#
                .write(to: storage.appendingPathComponent("part/prt_shadow.json"), atomically: true, encoding: .utf8)
        }

        let full = try XCTUnwrap(OpenCodeSessionParser.parseFileFull(at: sessionURL))
        XCTAssertTrue(full.events.contains { $0.text == "markerlessdirectneedle" })
        XCTAssertFalse(full.events.contains { $0.text == "legacyshadowneedle" }, "direct parts must win over legacy fallback")
        return try XCTUnwrap(OpenCodeSessionParser.parseFile(at: sessionURL))
    }

    private func legacyOpenCodePartFixture(_ partJSON: String) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = directory.appendingPathComponent("storage", isDirectory: true)
        let sessionDirectory = storage.appendingPathComponent("session/project", isDirectory: true)
        let messageDirectory = storage.appendingPathComponent("message/ses_search", isDirectory: true)
        let partDirectory = storage.appendingPathComponent("part", isDirectory: true)
        for item in [sessionDirectory, messageDirectory, partDirectory] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = sessionDirectory.appendingPathComponent("ses_search.json")
        try #"{"id":"ses_search","directory":"/tmp/project","title":"Search fixture"}"#
            .write(to: sessionURL, atomically: true, encoding: .utf8)
        try #"{"id":"msg_search","sessionID":"ses_search","role":"assistant"}"#
            .write(to: messageDirectory.appendingPathComponent("msg_search.json"), atomically: true, encoding: .utf8)
        try partJSON.write(to: partDirectory.appendingPathComponent("prt_duplicate.json"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(OpenCodeSessionParser.parseFile(at: sessionURL))
    }

    func testAndAccumulatesAcrossEventsWhilePhraseStaysWithinField() async throws {
        let session = try fixture([message("alpha"), message("beta")])
        let and = try await scan(session, "alpha AND beta")
        XCTAssertEqual(and.truth, .yes); XCTAssertTrue(and.summary.complete)
        let phrase = try await scan(session, "\"alpha beta\"")
        XCTAssertEqual(phrase.truth, .no); XCTAssertTrue(phrase.summary.complete)
    }

    func testPreservedClaudeOutputBeyondRawJSONSanitizerAndLiteralOmissionMarker() async throws {
        let output = String(repeating: "ordinary output ", count: 900) + "needle-final [OMITTED legitimate source]"
        let session = try fixture([["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "tool-1", "content": output]
        ]]]])
        let result = try await scan(session, "\"needle final\"")
        XCTAssertEqual(result.truth, .yes); XCTAssertTrue(result.summary.complete)
        XCTAssertEqual(result.snippet?.match, "needle-final")
        XCTAssertLessThanOrEqual(result.snippet?.text.utf16.count ?? 0, 212)
        let marker = try await scan(session, "\"OMITTED legitimate\"")
        XCTAssertEqual(marker.truth, .yes)
    }

    func testVerifiedExcerptUsesSatisfyingBranchAndOriginalUnicodeBeyondTokenizerChunk() async throws {
        let accent = "Que\u{301}bec Observability"
        let text = String(repeating: "ordinary validation details ", count: 3_000) + accent + " helps diagnose timing"
        let session = try fixture([message("alpha"), message(text)])
        let result = try await scan(session, "alpha AND absent OR \"quebec observ\"*")
        XCTAssertEqual(result.truth, .yes)
        XCTAssertEqual(result.snippet?.match, accent)
        XCTAssertTrue(result.snippet?.text.hasPrefix("…") == true)
        XCTAssertTrue(result.snippet?.text.contains("helps diagnose") == true)

        let exclusion = try await scan(session, "NOT absent")
        XCTAssertEqual(exclusion.truth, .yes)
        XCTAssertNil(exclusion.snippet)
    }

    func testSearchPreviewOmitsEvidenceFromFieldsWithRecognizedCredentialKeys() async throws {
        let session = try fixture([message(#"diagnostic {"apiKey":"sample-secret"} needle"#)])
        let result = try await scan(session, "needle")
        XCTAssertEqual(result.truth, .yes)
        XCTAssertNil(result.snippet)
    }

    func testStreamSampleIndexesToolResultTextAndToolOutputWithoutDuplication() {
        let shared = "sharedtoolresultordinarytoken"
        let textOnly = "textonlytoolresultordinarytoken"
        let events = [
            SessionEvent(id: "shared", timestamp: nil, kind: .tool_result, role: "tool",
                         text: shared, toolName: nil, toolInput: nil, toolOutput: shared,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"),
            SessionEvent(id: "text-only", timestamp: nil, kind: .tool_result, role: "tool",
                         text: textOnly, toolName: nil, toolInput: nil, toolOutput: nil,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        ]

        var sample = SessionSearchTextBuilder.StreamSample()
        for event in events {
            for segment in SearchSourceText.segments(event: event, source: .codex) {
                sample.consume(segment)
            }
        }

        XCTAssertTrue(sample.ordinary.contains(shared))
        XCTAssertTrue(sample.toolIO.contains(shared))
        XCTAssertTrue(sample.ordinary.contains(textOnly))
        XCTAssertTrue(sample.toolIO.contains(textOnly))
        XCTAssertEqual(sample.toolIO.components(separatedBy: shared).count - 1, 1,
                       "text and toolOutput containing the same result should be indexed once")
    }

    func testNotRequiresCompleteCoverageAndMalformedSourceIsNotNoMatch() async throws {
        let session = try fixture([message("alpha")])
        let file = URL(fileURLWithPath: session.filePath)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
        let negative = try await scan(session, "alpha NOT beta")
        XCTAssertEqual(negative.truth, .unknown)
        XCTAssertTrue(negative.summary.reasons.contains(.malformedRecord))
        let positive = try await scan(session, "alpha")
        XCTAssertEqual(positive.truth, .yes)
        XCTAssertFalse(positive.summary.complete)
    }

    func testResourcePreflightRejectsDeepAndHighFanoutContainersBeforeDecode() throws {
        XCTAssertThrowsError(try SearchSourceScanner.validateJSON(Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)))
        let array = "[" + Array(repeating: "0", count: 70_000).joined(separator: ",") + "]"
        XCTAssertThrowsError(try SearchSourceScanner.validateJSON(Data(array.utf8)))
        let safe = try SearchSourceScanner.validateJSON(Data("{\"text\":\"synthetic\"}".utf8))
        XCTAssertLessThan(safe, SearchSourceScanner.payloadBytes)
    }

    func testMissingFileCannotProduceCompleteNegative() async throws {
        let session = try fixture([message("alpha")])
        try FileManager.default.removeItem(atPath: session.filePath)
        let result = try await scan(session, "NOT alpha")
        XCTAssertEqual(result.truth, .unknown)
        XCTAssertTrue(result.summary.reasons.contains(.unavailable))
    }

    func testLongIndivisibleTokenIsExplicitResourceLimit() throws {
        let tokenizer = try SearchTokenizer()
        XCTAssertThrowsError(try tokenizer.enumerate(String(repeating: "a", count: 65_537)) { _, _ in })
    }

    func testOversizedFieldKeepsStablePositiveWitnessesButCannotProveAbsence() async throws {
        let session = try fixture([
            message("alpha"),
            message(String(repeating: "z", count: 65_537)),
            message("omega")
        ])

        let before = try await scan(session, "alpha")
        XCTAssertEqual(before.truth, .yes)
        XCTAssertNotNil(before.summary.revision)
        XCTAssertTrue(before.summary.reasons.contains(.resourceLimit))

        let after = try await scan(session, "omega")
        XCTAssertEqual(after.truth, .yes, "scanning must continue after the oversized field")
        XCTAssertNotNil(after.summary.revision)
        XCTAssertTrue(after.summary.reasons.contains(.resourceLimit))

        let incompleteNegative = try await scan(session, "alpha NOT beta")
        XCTAssertEqual(incompleteNegative.truth, .unknown)
        XCTAssertNotNil(incompleteNegative.summary.revision)
        XCTAssertTrue(incompleteNegative.summary.reasons.contains(.resourceLimit))
    }

    func testOpenCodeSplitFileSearchSupportsV2AndLegacyLayouts() async throws {
        for v2 in [true, false] {
            let result = try await scan(openCodeFixture(v2: v2), "splitfileuniqueneedle")
            XCTAssertEqual(result.truth, .yes, v2 ? "v2" : "legacy")
            XCTAssertTrue(result.summary.complete, v2 ? "v2" : "legacy")
            XCTAssertNotNil(result.summary.revision, v2 ? "v2" : "legacy")
            XCTAssertTrue(result.summary.revision?.files.contains { $0.path.hasSuffix("prt_search.json") } == true,
                          "missing part proof: \(result.summary.revision?.files.map(\.path) ?? [])")
            XCTAssertTrue(result.summary.revision?.files.contains { $0.path.hasSuffix("msg_search.json") } == true,
                          "missing message proof: \(result.summary.revision?.files.map(\.path) ?? [])")
            if v2 {
                XCTAssertTrue(result.summary.revision?.files.contains { $0.path.hasSuffix("/migration") } == true,
                              "missing migration proof: \(result.summary.revision?.files.map(\.path) ?? [])")
            }
            XCTAssertGreaterThan(result.summary.messages, 0, "snapshot parser produced no messages")
        }
    }

    func testOpenCodeMarkerlessDirectPartsAndPrecedenceMatchTranscriptParser() async throws {
        for includeLegacyShadow in [false, true] {
            let session = try markerlessOpenCodeDirectFixture(includeLegacyShadow: includeLegacyShadow)
            let direct = try await scan(session, "markerlessdirectneedle")
            XCTAssertEqual(direct.truth, .yes)
            XCTAssertTrue(direct.summary.complete)
            XCTAssertTrue(direct.summary.revision?.files.contains { $0.path.hasSuffix("/content.json") } == true)

            let legacy = try await scan(session, "legacyshadowneedle")
            XCTAssertEqual(legacy.truth, .no)
            XCTAssertTrue(legacy.summary.complete)
        }
    }

    func testOpenCodeLegacyForeignPartsDoNotConsumeTranscriptPayloadBudget() async throws {
        // The foreign inventory exceeds the transcript payload budget under the old
        // cumulative 24x charge, but each candidate is small enough for bounded lookup.
        let result = try await scan(openCodeFixture(v2: false, unrelatedLegacyParts: 64), "splitfileuniqueneedle")
        XCTAssertEqual(result.truth, .yes)
        XCTAssertTrue(result.summary.complete)
        XCTAssertGreaterThan(result.summary.bytesRead, 3 * 1024 * 1024)
        XCTAssertLessThan(result.summary.peakPayloadCharge, SearchSourceScanner.payloadBytes)
        XCTAssertEqual(result.summary.revision?.files.filter { $0.path.contains("prt_foreign_") }.count, 0)
        XCTAssertNotNil(result.summary.revision?.logical)
    }

    func testOpenCodeLargeForeignPartDoesNotEnterSemanticAllocationBudget() async throws {
        let result = try await scan(
            openCodeFixture(v2: false, largeForeignPartBytes: 3 * 1024 * 1024),
            "splitfileuniqueneedle"
        )
        XCTAssertEqual(result.truth, .yes)
        XCTAssertTrue(result.summary.complete)
        XCTAssertGreaterThan(result.summary.bytesRead, 3 * 1024 * 1024)
        XCTAssertLessThan(result.summary.peakPayloadCharge, SearchSourceScanner.payloadBytes)
        XCTAssertEqual(result.summary.revision?.files.filter { $0.path.hasSuffix("prt_large_foreign.json") }.count, 0)
    }

    func testOpenCodeLegacyOwnerProjectionMatchesFoundationDuplicateKeyRules() async throws {
        let firstStringWins = try legacyOpenCodePartFixture(
            #"{"id":"duplicate","messageID":"msg_search","message\u0049D":"foreign","type":"text","text":"duplicateownerneedle"}"#
        )
        let positive = try await scan(firstStringWins, "duplicateownerneedle")
        XCTAssertEqual(positive.truth, .yes)
        XCTAssertTrue(positive.summary.complete)
        let presentNegation = try await scan(firstStringWins, "NOT duplicateownerneedle")
        XCTAssertEqual(presentNegation.truth, .no)
        XCTAssertTrue(presentNegation.summary.complete)

        let firstNonStringWins = try legacyOpenCodePartFixture(
            #"{"id":"duplicate","messageID":12,"messageID":"msg_search","type":"text","text":"duplicateownerneedle"}"#
        )
        let absent = try await scan(firstNonStringWins, "duplicateownerneedle")
        XCTAssertEqual(absent.truth, .no)
        XCTAssertTrue(absent.summary.complete)
        let absentNegation = try await scan(firstNonStringWins, "NOT duplicateownerneedle")
        XCTAssertEqual(absentNegation.truth, .yes)
        XCTAssertTrue(absentNegation.summary.complete)
    }

    func testMutationFromSegmentConsumerReportsSourceChanged() throws {
        let session = try fixture([message("mutation-trigger")])
        let sourceURL = URL(fileURLWithPath: session.filePath)
        var mutated = false

        let summary = SearchSourceScanner.scanSegments(session: session) { segment in
            guard !mutated, segment.kind == .message, segment.text == "mutation-trigger" else { return }
            mutated = true
            let handle = try FileHandle(forWritingTo: sourceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"assistant\"}\n".utf8))
        }

        XCTAssertTrue(mutated, "the fixture event should reach the segment consumer")
        XCTAssertTrue(summary.reasons.contains(.sourceChanged))
        XCTAssertFalse(summary.complete)
    }
}
