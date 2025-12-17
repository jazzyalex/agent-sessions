import XCTest
@testable import AgentSessions

final class SessionParserTests: XCTestCase {
    func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "jsonl")!
    }

    func testJSONLStreamingAndDecoding() throws {
        let url = fixtureURL("session_simple")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()
        XCTAssertEqual(lines.count, 2)
        let e1 = SessionIndexer.parseLine(lines[0], eventID: "e-1").0
        XCTAssertEqual(e1.kind, .user)
        XCTAssertEqual(e1.role, "user")
        XCTAssertEqual(e1.text, "What's the weather like in SF today?")
        XCTAssertNotNil(e1.timestamp)
        XCTAssertFalse(e1.rawJSON.isEmpty)
    }

    func testBuildsSessionMetadata() throws {
        let url = fixtureURL("session_toolcall")
        let indexer = SessionIndexer()
        let session = indexer.parseFile(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }
        XCTAssertEqual(s.eventCount, 4)
        XCTAssertEqual(s.model, "gpt-4o-mini")
        XCTAssertNotNil(s.startTime)
        XCTAssertNotNil(s.endTime)
        XCTAssertLessThan((s.startTime ?? .distantPast), (s.endTime ?? .distantFuture))
    }

    func testSearchAndFilters() throws {
        // Build two sample sessions from fixtures
        let idx = SessionIndexer()
        let s1 = idx.parseFile(at: fixtureURL("session_simple"))!
        let s2 = idx.parseFile(at: fixtureURL("session_toolcall"))!
        let all = [s1, s2]
        // Query should match assistant text in s1
        var filters = Filters(query: "sunny", dateFrom: nil, dateTo: nil, model: nil, kinds: Set(SessionEventKind.allCases))
        var filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s1.id)

        // Filter by model
        filters = Filters(query: "", dateFrom: nil, dateTo: nil, model: "gpt-4o-mini", kinds: Set(SessionEventKind.allCases))
        filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s2.id)

        // Filter kinds (only tool_result)
        filters = Filters(query: "hola", dateFrom: nil, dateTo: nil, model: nil, kinds: [.tool_result])
        filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s2.id)
    }

    func testClaudeSplitsThinkingAndToolBlocks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_sample.jsonl")
        let sessionID = "ses_testClaude"

        let lines = [
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","cwd":"/tmp","message":{"role":"user","content":"Hello"},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reasoning goes here."},{"type":"text","text":"I'll list files."},{"type":"tool_use","name":"bash","input":{"command":"ls"}}]},"uuid":"a1","timestamp":"2025-12-16T00:00:01.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":{"stdout":"file1\nfile2\n","stderr":"","is_error":false},"message":{"role":"assistant","content":[{"type":"tool_result","content":"ok"}]},"uuid":"a2","timestamp":"2025-12-16T00:00:02.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"uuid":"a3","timestamp":"2025-12-16T00:00:03.000Z"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.contains("[thinking]") && $0.contains("Reasoning goes here.") }))

        let assistantTexts = parsed.events.filter { $0.kind == .assistant }.compactMap { $0.text }
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("I'll list files.") }))
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("Done.") }))

        let toolCalls = parsed.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "bash")
        XCTAssertNotNil(toolCalls.first?.toolInput)
        XCTAssertTrue(toolCalls.first?.toolInput?.contains("\"ls\"") ?? false)

        let toolResults = parsed.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(toolResults.first?.toolOutput?.contains("file1") ?? false)
    }

    func testClaudeToolResultErrorClassification() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-Errors-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_errors.jsonl")
        let sessionID = "ses_testClaudeErrors"

        // 1) Runtime-ish: exit non-zero => .error
        // 2) Not found => keep as .tool_result
        // 3) User rejected tool use => meta (hidden by default)
        // 4) Interrupted => .error
        let lines = [
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"user","content":"Start"},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: Exit code 1\nsomething failed","message":{"role":"user","content":[{"type":"tool_result","content":"x","is_error":true}]},"uuid":"u2","timestamp":"2025-12-16T00:00:01.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: File does not exist.","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>File does not exist.</tool_use_error>","is_error":true}]},"uuid":"u3","timestamp":"2025-12-16T00:00:02.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: The user doesn't want to proceed with this tool use. The tool use was rejected.","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true}]},"uuid":"u4","timestamp":"2025-12-16T00:00:03.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: [Request interrupted by user for tool use]","message":{"role":"user","content":[{"type":"tool_result","content":"interrupted","is_error":true}]},"uuid":"u5","timestamp":"2025-12-16T00:00:04.000Z"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let errorTexts = parsed.events.filter { $0.kind == .error }.compactMap { $0.text }
        XCTAssertEqual(errorTexts.count, 2)
        XCTAssertTrue(errorTexts.contains(where: { $0.contains("Exit code 1") }))
        XCTAssertTrue(errorTexts.contains(where: { $0.localizedCaseInsensitiveContains("interrupted") }))

        let toolResults = parsed.events.filter { $0.kind == .tool_result }.compactMap { $0.toolOutput }
        XCTAssertTrue(toolResults.contains(where: { $0.localizedCaseInsensitiveContains("file does not exist") }))

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.localizedCaseInsensitiveContains("Rejected tool use:") }))
    }

    func testOpenCodeParsesTextPartsIntoConversation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionID = "ses_testQuickCheckIn"
        let projectID = "global"

        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"))

        let sessionDir = storageRoot
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        let messageDir = storageRoot
            .appendingPathComponent("message", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: messageDir, withIntermediateDirectories: true)

        let createdMillis: Int64 = 1_700_000_000_000

        // Session record
        let sessionURL = sessionDir.appendingPathComponent("\(sessionID).json")
        let sessionJSON = """
        {
          "id": "\(sessionID)",
          "version": "1.0.test",
          "projectID": "\(projectID)",
          "directory": "/tmp",
          "title": "Quick check-in",
          "time": { "created": \(createdMillis), "updated": \(createdMillis + 1000) },
          "summary": { "additions": 0, "deletions": 0, "files": 0 }
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionURL)

        // User message record without summary (text lives only in part/*.json)
        let userMsgID = "msg_user_1"
        let userMsgJSON = """
        {
          "id": "\(userMsgID)",
          "sessionID": "\(sessionID)",
          "role": "user",
          "agent": "plan",
          "time": { "created": \(createdMillis + 10) }
        }
        """
        try userMsgJSON.data(using: .utf8)!.write(to: messageDir.appendingPathComponent("msg_0001.json"))

        // Assistant message record without summary (text lives only in part/*.json)
        let assistantMsgID = "msg_assistant_1"
        let assistantMsgJSON = """
        {
          "id": "\(assistantMsgID)",
          "sessionID": "\(sessionID)",
          "role": "assistant",
          "agent": "plan",
          "time": { "created": \(createdMillis + 20) },
          "providerID": "openrouter",
          "modelID": "anthropic/claude-haiku-4.5"
        }
        """
        try assistantMsgJSON.data(using: .utf8)!.write(to: messageDir.appendingPathComponent("msg_0002.json"))

        // Parts: actual user prompt + assistant response
        let partRoot = storageRoot.appendingPathComponent("part", isDirectory: true)
        let userPartDir = partRoot.appendingPathComponent(userMsgID, isDirectory: true)
        let assistantPartDir = partRoot.appendingPathComponent(assistantMsgID, isDirectory: true)
        try fm.createDirectory(at: userPartDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assistantPartDir, withIntermediateDirectories: true)

        let userPartJSON = """
        {
          "id": "prt_user_text_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(userMsgID)",
          "type": "text",
          "text": "Hello there",
          "time": { "start": \(createdMillis + 10), "end": \(createdMillis + 10) }
        }
        """
        try userPartJSON.data(using: .utf8)!.write(to: userPartDir.appendingPathComponent("prt_user_0001.json"))

        let assistantPartJSON = """
        {
          "id": "prt_assistant_text_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(assistantMsgID)",
          "type": "text",
          "text": "Hi! How can I help?",
          "time": { "start": \(createdMillis + 20), "end": \(createdMillis + 20) }
        }
        """
        try assistantPartJSON.data(using: .utf8)!.write(to: assistantPartDir.appendingPathComponent("prt_assistant_0001.json"))

        // Unknown part type should not crash import and should surface in JSON via meta events.
        let unknownPartJSON = """
        {
          "id": "prt_unknown_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(assistantMsgID)",
          "type": "new-type",
          "payload": { "hello": "world" }
        }
        """
        try unknownPartJSON.data(using: .utf8)!.write(to: assistantPartDir.appendingPathComponent("prt_unknown_0002.json"))

        let session = OpenCodeSessionParser.parseFileFull(at: sessionURL)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let userTexts = parsed.events.filter { $0.kind == .user }.compactMap { $0.text }
        let assistantTexts = parsed.events.filter { $0.kind == .assistant }.compactMap { $0.text }

        XCTAssertTrue(userTexts.contains(where: { $0.contains("Hello there") }), "Expected user text part to appear as a .user event")
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("Hi! How can I help?") }), "Expected assistant text part to appear as a .assistant event")

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.contains("OpenCode part: new-type") }), "Expected unknown OpenCode part type to be preserved as a meta event for JSON view")
    }

    func testOpenCodeDiscoveryAcceptsStorageRootOverride() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let sessionDir = storageRoot.appendingPathComponent("session", isDirectory: true).appendingPathComponent("global", isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"))

        let sessionURL = sessionDir.appendingPathComponent("ses_demo.json")
        try #"{"id":"ses_demo","time":{"created":1700000000000}}"#.data(using: .utf8)!.write(to: sessionURL)

        let discovery = OpenCodeSessionDiscovery(customRoot: storageRoot.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "ses_demo.json")
    }
}
