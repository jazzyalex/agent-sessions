import XCTest
@testable import AgentSessions

final class BuddySessionParserTests: XCTestCase {

    private func writeTempJSONL(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("buddy_test_\(UUID().uuidString).jsonl")
        let content = lines.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: - Preview (lightweight)

    func testParseFile_preview_countsUserAssistantAndTools() throws {
        let lines = [
            #"{"type":"message","sessionId":"sess-preview-1","timestamp":1700000000000,"cwd":"/tmp/sample-repo","role":"user","content":"Ship the feature"}"#,
            #"{"type":"message","sessionId":"sess-preview-1","timestamp":1700000001000,"cwd":"/tmp/sample-repo","role":"assistant","content":"On it."}"#,
            #"{"type":"function_call","sessionId":"sess-preview-1","timestamp":1700000002000,"name":"read_file","arguments":"{\"path\":\"README.md\"}"}"#,
            #"{"type":"function_call_result","sessionId":"sess-preview-1","timestamp":1700000003000,"name":"read_file","output":"Title line"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = CodebuddySessionParser.parseFile(at: url) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.source, .codebuddy)
        XCTAssertEqual(preview.events.count, 0)
        XCTAssertEqual(preview.codexInternalSessionIDHint, "sess-preview-1")
        XCTAssertEqual(preview.cwd, "/tmp/sample-repo")
        XCTAssertEqual(preview.repoName, "sample-repo")
        XCTAssertEqual(preview.lightweightTitle, "Ship the feature")
        XCTAssertEqual(preview.lightweightCommands, 1)
        XCTAssertGreaterThanOrEqual(preview.eventCount, 3)
    }

    func testParseFile_preview_extractsModelFromProviderData() throws {
        let lines = [
            #"{"type":"message","sessionId":"m1","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"Hi","providerData":{"model":"buddy-test-model"}}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = CodebuddySessionParser.parseFile(at: url) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.model, "buddy-test-model")
    }

    func testParseFile_returnsNilWhenNoUserOrAssistantMessages() throws {
        let lines = [
            #"{"type":"function_call","sessionId":"x","timestamp":1700000000000,"name":"noop","arguments":"{}"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(CodebuddySessionParser.parseFile(at: url))
    }

    func testParseFile_previewScansPastLongMetaPreamble() throws {
        var lines = (0..<140).map { idx in
            #"{"type":"file-history-snapshot","sessionId":"long-meta","timestamp":1700000000\#(String(format: "%03d", idx))}"#
        }
        lines.append(#"{"type":"message","sessionId":"long-meta","timestamp":1700000002000,"cwd":"/tmp/long-meta","role":"user","content":"Actual request"}"#)
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = CodebuddySessionParser.parseFile(at: url) else {
            return XCTFail("preview parse should continue past meta preamble")
        }
        XCTAssertEqual(preview.lightweightTitle, "Actual request")
        XCTAssertEqual(preview.codexInternalSessionIDHint, "long-meta")
    }

    func testParseFile_respectsForcedID() throws {
        let lines = [
            #"{"type":"message","sessionId":"ignored","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"x"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = CodebuddySessionParser.parseFile(at: url, forcedID: "forced-buddy-id") else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.id, "forced-buddy-id")
    }

    // MARK: - Full parse

    func testParseFileFull_mapsMessagesAndToolEvents() throws {
        let lines = [
            #"{"type":"message","sessionId":"full-1","timestamp":1700000000000,"cwd":"/tmp/ws","role":"user","content":"Run checks"}"#,
            #"{"type":"message","sessionId":"full-1","timestamp":1700000001000,"cwd":"/tmp/ws","role":"assistant","content":"Running."}"#,
            #"{"type":"function_call","sessionId":"full-1","timestamp":1700000002000,"name":"bash","arguments":"{\"cmd\":\"true\"}"}"#,
            #"{"type":"function_call_result","sessionId":"full-1","timestamp":1700000003000,"name":"bash","output":"ok"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = CodebuddySessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(session.source, .codebuddy)
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)

        let call = session.events.first(where: { $0.kind == .tool_call })
        XCTAssertEqual(call?.toolName, "bash")
        XCTAssertTrue((call?.toolInput ?? "").contains("true"))

        let result = session.events.first(where: { $0.kind == .tool_result })
        XCTAssertEqual(result?.toolName, "bash")
        XCTAssertEqual(result?.toolOutput, "ok")
    }

    func testParseFileFull_reasoningLine_isMeta() throws {
        let lines = [
            #"{"type":"message","sessionId":"r1","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"Think"}"#,
            #"{"type":"reasoning","sessionId":"r1","timestamp":1700000001000,"rawContent":"step a"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = CodebuddySessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let meta = session.events.filter { $0.kind == .meta }
        XCTAssertTrue(meta.contains(where: { ($0.text ?? "").contains("[reasoning]") }))
    }

    func testParseFileFull_topicLine_isMeta() throws {
        let lines = [
            #"{"type":"message","sessionId":"t1","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"Go"}"#,
            #"{"type":"topic","sessionId":"t1","timestamp":1700000001000,"topic":"refactor-auth"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = CodebuddySessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertTrue(session.events.contains(where: { ($0.text ?? "").contains("[topic]") && ($0.text ?? "").contains("refactor-auth") }))
    }

    func testParseFileFull_transcriptBuildDoesNotCrash() throws {
        let lines = [
            #"{"type":"message","sessionId":"tb1","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"Hello"}"#,
            #"{"type":"message","sessionId":"tb1","timestamp":1700000001000,"cwd":"/tmp","role":"assistant","content":"World"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = CodebuddySessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let tf: TranscriptFilters = .current(showTimestamps: false, showMeta: true)
        let text = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: tf, mode: .normal)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("Hello") || text.contains("World"))
    }

    func testWorkbuddyParseFile_preview_usesWorkbuddySource() throws {
        let lines = [
            #"{"type":"message","sessionId":"wb-1","timestamp":1700000000000,"cwd":"/tmp/wb","role":"user","content":"IDE task"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = WorkbuddySessionParser.parseFile(at: url) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.source, .workbuddy)
    }

    func testBuddySessionMatchesFilterEngineFreeText() throws {
        let lines = [
            #"{"type":"message","sessionId":"fe1","timestamp":1700000000000,"cwd":"/tmp","role":"user","content":"UniqueBuddyTokenXYZ"}"#,
            #"{"type":"message","sessionId":"fe1","timestamp":1700000001000,"cwd":"/tmp","role":"assistant","content":"reply"}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = CodebuddySessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let filters = Filters(
            query: "UniqueBuddyTokenXYZ",
            dateFrom: nil,
            dateTo: nil,
            model: nil,
            kinds: Set(SessionEventKind.allCases),
            repoName: nil,
            pathContains: nil
        )
        let hits = FilterEngine.filterSessions([session], filters: filters, transcriptCache: nil, allowTranscriptGeneration: false)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, session.id)
    }
}
