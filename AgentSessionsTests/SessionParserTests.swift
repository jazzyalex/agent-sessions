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
        let session = indexer.parseFileFull(at: url)
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
        let s1 = idx.parseFileFull(at: fixtureURL("session_simple"))!
        let s2 = idx.parseFileFull(at: fixtureURL("session_toolcall"))!
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

    func testCodexPayloadCwdRepoAndBranchExtraction() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex073-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repoDir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let lines = [
            #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"\#(repoDir.path)","originator":"codex_cli_rs","cli_version":"0.73.0","git":{"branch":"feature/test"},"instructions":"short"}}"#,
            #"{"timestamp":"2025-12-17T23:27:50.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}"#,
            #"{"timestamp":"2025-12-17T23:27:51.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertEqual(s.cwd, repoDir.path)
        XCTAssertEqual(s.repoName, repoDir.lastPathComponent)
        XCTAssertEqual(s.gitBranch, "feature/test")
        XCTAssertEqual(s.codexInternalSessionID, "019b2ea4-2a8d-76e2-9cd8-58208e1f2837")
    }

    func testCodexLightweightHandlesHugeFirstLine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexHugeMeta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let hugeInstructions = String(repeating: "A", count: 320_000)
        let first = #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"\#(repoDir.path)","originator":"codex_cli_rs","cli_version":"0.73.0","instructions":"\#(hugeInstructions)"}}"#
        let second = #"{"timestamp":"2025-12-17T23:27:50.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello title"}]}}"#
        try ([first, second].joined(separator: "\n")).data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFile(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertTrue(s.events.isEmpty, "Lightweight parse should not load events")
        XCTAssertEqual(s.cwd, repoDir.path)
        XCTAssertEqual(s.title, "Hello title")
    }

    func testCodexSanitizesEncryptedContentWhenHuge() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexEncrypted-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let huge = String(repeating: "B", count: 160_000)
        let lines = [
            #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.73.0"}}"#,
            #"{"timestamp":"2025-12-17T23:27:55.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null,"encrypted_content":"\#(huge)"}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        let meta = s.events.filter { $0.kind == .meta }
        XCTAssertTrue(meta.contains(where: { $0.rawJSON.contains("[ENCRYPTED_OMITTED]") }))
        XCTAssertTrue(meta.allSatisfy { $0.rawJSON.count < 50_000 }, "Sanitized rawJSON should stay reasonably small")
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(huge.prefix(100))) }))
    }

    func testCodexSanitizerHandlesDuplicateKeysWithoutCrashing() throws {
        // This guards against regressions where sanitizer loops replace multiple occurrences
        // of the same key in a single JSONL line (possible in malformed logs).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexDupKeys-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let hugeA = String(repeating: "A", count: 120_000)
        let hugeB = String(repeating: "B", count: 120_000)
        let line = #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","cwd":"/tmp","instructions":"\#(hugeA)","instructions":"\#(hugeB)"}}"#
        try (line + "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        let meta = s.events.filter { $0.kind == .meta }
        XCTAssertTrue(meta.contains(where: { $0.rawJSON.contains("[INSTRUCTIONS_OMITTED]") }))
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(hugeA.prefix(50))) }))
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(hugeB.prefix(50))) }))
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

    func testClaudeToolResultEmbeddedImageIsSummarizedAndSanitized() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-Images-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_images.jsonl")
        let sessionID = "ses_testClaudeImages"

        // Simulate Chrome MCP screenshots (tool_result content blocks with base64 image payloads).
        let bigBase64 = String(repeating: "A", count: 120_000)
        let line = #"""
{"type":"user","sessionId":"\#(sessionID)","version":"2.0.76","cwd":"/tmp","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_img","content":[{"type":"text","text":"Captured screenshot."},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(bigBase64)"}}]}]},"uuid":"u1","timestamp":"2026-01-04T20:50:23.199Z"}
"""#
        try (line + "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let toolResults = parsed.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        let output = toolResults[0].toolOutput ?? ""
        XCTAssertTrue(output.contains("Captured screenshot."))
        XCTAssertTrue(output.contains("[image omitted:"), "Expected tool output to summarize embedded image payloads")
        XCTAssertFalse(output.contains(String(bigBase64.prefix(64))), "Should not surface raw base64 image data in tool output")

        // rawJSON is base64-wrapped JSON; decode and ensure large strings were sanitized.
        let raw = toolResults[0].rawJSON
        let decoded = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(decoded.contains("[OMITTED bytes="), "Expected raw JSON to redact large embedded strings")
        XCTAssertFalse(decoded.contains(String(bigBase64.prefix(64))), "Should not keep raw base64 image payloads in raw JSON")
    }

    func testCopilotJoinsToolExecutionByToolCallId() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("copilot_sample.jsonl")
        let sessionID = "copilot_test_123"

        let lines = [
            #"{"type":"session.start","data":{"sessionId":"\#(sessionID)","version":1,"producer":"copilot-agent","copilotVersion":"0.0.372","startTime":"2025-12-18T21:32:04.182Z"},"id":"e1","timestamp":"2025-12-18T21:32:04.183Z","parentId":null}"#,
            #"{"type":"session.model_change","data":{"newModel":"gpt-5-mini"},"id":"e2","timestamp":"2025-12-18T21:32:05.000Z","parentId":"e1"}"#,
            #"{"type":"session.info","data":{"infoType":"folder_trust","message":"Folder /tmp/repo has been added to trusted folders."},"id":"e3","timestamp":"2025-12-18T21:32:06.000Z","parentId":"e2"}"#,
            #"{"type":"user.message","data":{"content":"Hello","transformedContent":"Hello","attachments":[]},"id":"e4","timestamp":"2025-12-18T21:32:07.000Z","parentId":"e3"}"#,
            #"{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash","arguments":{"command":"ls"}}]},"id":"e5","timestamp":"2025-12-18T21:32:08.000Z","parentId":"e4"}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true,"result":{"content":"file1\\n"}},"id":"e6","timestamp":"2025-12-18T21:32:09.000Z","parentId":"e5"}"#,
            #"{"type":"assistant.message","data":{"content":"Done","toolRequests":[]},"id":"e7","timestamp":"2025-12-18T21:32:10.000Z","parentId":"e6"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = CopilotSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertEqual(s.id, sessionID)
        XCTAssertEqual(s.model, "gpt-5-mini")
        XCTAssertEqual(s.cwd, "/tmp/repo")

        let assistants = s.events.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.text, "Done")

        let toolCalls = s.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "bash")
        XCTAssertTrue(toolCalls.first?.toolInput?.contains("\"ls\"") ?? false)

        let toolResults = s.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.toolName, "bash")
        XCTAssertEqual(toolResults.first?.toolOutput, "file1\n")
    }

    func testClaudeFileReadToolResultDoesNotFalsePositiveExitCode() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-FileRead-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_fileread.jsonl")
        let sessionID = "ses_testClaudeFileRead"

        // Claude read-file tool_result payloads can include line numbers like "219→ ...".
        // Previously our exit-code regex could match across the newline ("exit code\n220") and
        // mistakenly treat the next line number as a non-zero exit code, coloring the whole block red.
        let fileDump = """
             219→        // Check exit code
             220→        let exitCode = process.terminationStatus
        """
        let fileDumpEscaped = fileDump.replacingOccurrences(of: "\n", with: "\\n")
        let line = #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":{"type":"file","file":{"filePath":"/tmp/ClaudeStatusService.swift","content":"\#(fileDumpEscaped)"}},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"\#(fileDumpEscaped)"}]},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#
        try line.data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        XCTAssertTrue(parsed.events.filter { $0.kind == .error }.isEmpty)
        let toolOutputs = parsed.events.filter { $0.kind == .tool_result }.compactMap { $0.toolOutput }
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertTrue(toolOutputs.first?.contains("Check exit code") ?? false)
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

    func testClaudeTitleSkipsLocalCommandCaveatAndUsesTrailingPrompt() {
        let text = """
        Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.
        <command-name>/clear</command-name>
                    <command-message>clear</command-message>
                    <command-args></command-args>
        <local-command-stdout></local-command-stdout>
        read from docs/LettaCode - Dec18.md how to improve  Brush Cursor needs refinement
        """
        let e = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: text,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 1,
                        events: [e])
        XCTAssertEqual(s.title, "read from docs/LettaCode - Dec18.md how to improve Brush Cursor needs refinement")
    }

    func testClaudeTitleSkipsPureLocalCommandCaveatAndUsesNextPrompt() {
        let caveat = """
        Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.
        <command-name>/model</command-name>
                    <command-message>model</command-message>
                    <command-args></command-args>
        <local-command-stdout>Set model to [1mhaiku (claude-haiku-4-5-20251001)[22m</local-command-stdout>
        """
        let e1 = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: caveat,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let e2 = SessionEvent(
            id: "e2",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "Real prompt after model switch",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 2,
                        events: [e1, e2])
        XCTAssertEqual(s.title, "Real prompt after model switch")
    }

    func testClaudeTitleSkipsTranscriptOnlyUserFragments() {
        let e1 = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "<local-command-stdout></local-command-stdout>",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let e2 = SessionEvent(
            id: "e2",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "Actual user prompt",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 2,
                        events: [e1, e2])
        XCTAssertEqual(s.title, "Actual user prompt")
    }

    func testClaudeLightweightTitleDoesNotExposeLocalCommandTranscript() {
        let defaults = UserDefaults.standard
        let key = "SkipAgentsPreamble"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key) // default ON

        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 0,
                        events: [],
                        cwd: nil,
                        repoName: nil,
                        lightweightTitle: "<local-command-stdout></local-command-stdout>",
                        lightweightCommands: nil)
        XCTAssertFalse(s.title.contains("<local-command-"))
    }
}
