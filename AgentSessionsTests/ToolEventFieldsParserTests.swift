import XCTest
@testable import AgentSessions

/// Parser contract for the tool fields on `SessionEvent` (call id, structured output value,
/// sidecar, disposition). One pairing test per source; sidecar shapes follow spec §7.3/§7.4.
final class ToolEventFieldsParserTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    // MARK: - Helpers

    private func parseCodexLine(_ line: String) throws -> SessionEvent {
        SessionIndexer.parseLine(line, eventID: "e-\(UUID().uuidString)").0
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolEventFieldsParserTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func parseClaudeLines(_ lines: [String]) throws -> Session {
        let url = try makeTempDir("claude").appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url))
    }

    private func claudeToolUseLine(id: String, name: String = "Bash", command: String = "ls") -> String {
        #"{"type":"assistant","sessionId":"s1","version":"2.0.71","uuid":"a-\#(id)","timestamp":"2026-11-04T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"command":"\#(command)","description":"List files"}}]}}"#
    }

    private func claudeSession(_ events: [SessionEvent]) -> Session {
        Session(id: "toolFields-\(UUID().uuidString)", source: .claude, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/x.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    // MARK: - Codex

    func testCodexCallAndOutputShareCallID() throws {
        let call = try parseCodexLine(#"{"timestamp":"2026-11-04T00:00:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls\"}","call_id":"call_A"}}"#)
        let out = try parseCodexLine(#"{"timestamp":"2026-11-04T00:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_A","output":"Process exited with code 0\nOutput:\nfile\n"}}"#)
        XCTAssertEqual(call.kind, .tool_call)
        XCTAssertEqual(out.kind, .tool_result)
        XCTAssertNotNil(call.toolCallID)
        XCTAssertEqual(call.toolCallID, out.toolCallID)

        let customCall = try parseCodexLine(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"tools.exec_command({cmd:\"ls\"})","call_id":"call_B"}}"#)
        let customOut = try parseCodexLine(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_B","output":[{"type":"input_text","text":"Script completed\n"}]}}"#)
        XCTAssertEqual(customCall.kind, .tool_call)
        XCTAssertEqual(customOut.kind, .tool_result)
        XCTAssertEqual(customCall.toolCallID, "call_B")
        XCTAssertEqual(customCall.toolCallID, customOut.toolCallID)
    }

    func testCodexOutputValueKeptForArrays() throws {
        let arrayOut = try parseCodexLine(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\n"},{"type":"input_text","text":"hello\n"}]}}"#)
        guard case .array(let items)? = arrayOut.toolOutputValue else {
            return XCTFail("expected .array, got \(String(describing: arrayOut.toolOutputValue))")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first, .object(["type": .string("input_text"), "text": .string("Script completed\n")]))
        // The text form is unchanged.
        XCTAssertEqual(arrayOut.toolOutput, "Script completed\nhello\n")

        let objectOut = try parseCodexLine(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c2","output":{"exit_code":0,"ok":true}}}"#)
        XCTAssertEqual(objectOut.toolOutputValue, .object(["exit_code": .number(0), "ok": .bool(true)]))

        let stringOut = try parseCodexLine(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c3","output":"plain text"}}"#)
        XCTAssertNil(stringOut.toolOutputValue)
        XCTAssertEqual(stringOut.toolOutput, "plain text")

        let call = try parseCodexLine(#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls\"}","call_id":"c3"}}"#)
        XCTAssertNil(call.toolOutputValue)
    }

    func testLargeOutputValueDropped() throws {
        let big = String(repeating: "x", count: 300 * 1024)
        let line = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c-big","output":[{"type":"input_text","text":"\#(big)"}]}}"#
        let e = try parseCodexLine(line)
        XCTAssertNil(e.toolOutputValue)
        XCTAssertEqual(e.toolOutput, big)
        XCTAssertEqual(e.toolCallID, "c-big")
    }

    func testOutputValueBudgetCountsTheOutputNotTheLine() throws {
        // The line is over 256 KB, but the output itself is small: it is measured with ToolJSON and kept.
        let padding = String(repeating: "p", count: 300 * 1024)
        let line = #"{"type":"response_item","pad":"\#(padding)","payload":{"type":"custom_tool_call_output","call_id":"c-pad","output":[{"type":"input_text","text":"ok"}]}}"#
        XCTAssertGreaterThan(line.utf8.count, ToolPayloadValue.outputValueMaxBytes)
        let e = try parseCodexLine(line)
        XCTAssertEqual(e.toolOutputValue, .array([.object(["type": .string("input_text"), "text": .string("ok")])]))
    }

    func testCodexLargeLineStubKeepsCallID() throws {
        let dir = try makeTempDir("codex-stub")
        let url = dir.appendingPathComponent("rollout-2026-11-04T00-00-00-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let base64 = String(repeating: "A", count: 5_200_000)
        let lines = [
            #"{"timestamp":"2026-11-04T00:00:00.000Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2026-11-04T00:00:00.000Z","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.73.0"}}"#,
            #"{"timestamp":"2026-11-04T00:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"view_image","arguments":"{\"path\":\"/tmp/a.png\"}","call_id":"call_big"}}"#,
            #"{"timestamp":"2026-11-04T00:00:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_big","output":[{"type":"input_image","image_url":"data:image/png;base64,\#(base64)"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = try XCTUnwrap(SessionIndexer().parseFileFull(at: url))
        let stub = try XCTUnwrap(session.events.first { ($0.text ?? "").contains("Large event omitted") })
        XCTAssertEqual(stub.text, "[Large event omitted - 5MB]")
        XCTAssertEqual(stub.toolCallID, "call_big")
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        XCTAssertEqual(call.toolCallID, stub.toolCallID)
    }

    // MARK: - Claude

    func testClaudeCallAndResultShareCallID() throws {
        let session = try parseClaudeLines([
            claudeToolUseLine(id: "toolu_01"),
            #"{"type":"user","sessionId":"s1","version":"2.0.71","uuid":"u2","timestamp":"2026-11-04T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"file1\nfile2"}]}}"#
        ])
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(call.toolCallID, "toolu_01")
        XCTAssertEqual(call.toolCallID, result.toolCallID)
        XCTAssertEqual(result.toolOutput, "file1\nfile2")
        // No toolUseResult object and no is_error flag: no sidecar, no disposition.
        XCTAssertNil(result.toolSidecar)
        XCTAssertNil(result.toolDisposition)
        XCTAssertNil(result.toolOutputValue)
        XCTAssertNil(call.toolSidecar)
        XCTAssertNil(call.toolDisposition)
    }

    func testClaudeBashSidecarSplitsStdoutStderr() throws {
        let session = try parseClaudeLines([
            claudeToolUseLine(id: "toolu_02"),
            #"{"type":"user","sessionId":"s1","version":"2.0.71","uuid":"u3","timestamp":"2026-11-04T00:00:02.000Z","toolUseResult":{"stdout":"a","stderr":"b","interrupted":false,"isImage":false},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"a\nb","is_error":false}]}}"#
        ])
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        let sidecar = try XCTUnwrap(result.toolSidecar)
        XCTAssertEqual(sidecar.stdout, "a")
        XCTAssertEqual(sidecar.stderr, "b")
        XCTAssertEqual(sidecar.interrupted, false)
        XCTAssertEqual(sidecar.isError, false)
        XCTAssertNil(sidecar.exitCode)
        XCTAssertNil(sidecar.agentLabel)
        XCTAssertEqual(result.toolCallID, "toolu_02")
        XCTAssertNil(result.toolDisposition)
        // Existing text form is unchanged.
        XCTAssertEqual(result.toolOutput, "a\nb")
    }

    func testClaudeSidecarKeepsEmptyStderr() throws {
        let session = try parseClaudeLines([
            claudeToolUseLine(id: "toolu_03"),
            #"{"type":"user","sessionId":"s1","version":"2.0.71","uuid":"u4","timestamp":"2026-11-04T00:00:02.000Z","toolUseResult":{"stdout":"only out","stderr":"","interrupted":true},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_03","content":"only out"}]}}"#
        ])
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.toolSidecar, ToolSidecar(stdout: "only out", stderr: "", interrupted: true))
    }

    func testClaudeRejectionRecordsDisposition() throws {
        let rejection = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
        let session = try parseClaudeLines([
            claudeToolUseLine(id: "toolu_04"),
            #"{"type":"user","sessionId":"s1","version":"2.0.71","uuid":"u5","timestamp":"2026-11-04T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_04","content":"\#(rejection)","is_error":true}]}}"#
        ])
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        let result = try XCTUnwrap(session.events.first { $0.text?.hasPrefix("Rejected tool use: ") == true })
        XCTAssertEqual(result.kind, .meta)
        XCTAssertEqual(result.text, "Rejected tool use: " + rejection)
        XCTAssertEqual(result.toolDisposition, .rejected)
        XCTAssertEqual(result.toolCallID, "toolu_04")
        XCTAssertEqual(result.toolCallID, call.toolCallID)
        XCTAssertEqual(result.toolSidecar, ToolSidecar(isError: true))
    }

    func testClaudeRuntimeErrorKeepsCallID() throws {
        let session = try parseClaudeLines([
            claudeToolUseLine(id: "toolu_05"),
            #"{"type":"user","sessionId":"s1","version":"2.0.71","uuid":"u6","timestamp":"2026-11-04T00:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_05","content":"Error: boom","is_error":true}]}}"#
        ])
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        let error = try XCTUnwrap(session.events.first { $0.kind == .error })
        XCTAssertEqual(error.text, "Error: boom")
        XCTAssertEqual(error.toolDisposition, .runtimeError)
        XCTAssertEqual(error.toolCallID, "toolu_05")
        XCTAssertEqual(error.toolCallID, call.toolCallID)
        XCTAssertEqual(error.toolSidecar, ToolSidecar(isError: true))

        // The error block keeps the id and disposition, so pairing can treat it as the call's output.
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let errorBlock = try XCTUnwrap(blocks.first { $0.kind == .error })
        XCTAssertEqual(errorBlock.toolCallID, "toolu_05")
        XCTAssertEqual(errorBlock.toolDisposition, .runtimeError)
        XCTAssertEqual(errorBlock.toolSidecar, ToolSidecar(isError: true))
    }

    // MARK: - Other sources: helpers

    private func fixtureURL(_ relative: String) -> URL {
        FixturePaths.stage0FixtureURL("agents/" + relative)
    }

    private func writeLines(_ lines: [String], name: String = "session.jsonl", dir: String = "other") throws -> URL {
        let url = try makeTempDir(dir).appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// At least one call with an id, and one result whose id matches a call. With
    /// `sameAsMessageID`, every event that has a `toolCallID` carries the same value in `messageID`
    /// (the parser's existing pairing field), proving the new field is read from the same source.
    private func assertPairs(_ events: [SessionEvent], _ label: String, sameAsMessageID: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) {
        let callIDs = Set(events.filter { $0.kind == .tool_call }.compactMap(\.toolCallID))
        XCTAssertFalse(callIDs.isEmpty, "\(label): no tool_call carries a toolCallID", file: file, line: line)
        let results = events.filter { ($0.kind == .tool_result || $0.kind == .error) && $0.toolCallID != nil }
        XCTAssertFalse(results.isEmpty, "\(label): no tool result carries a toolCallID", file: file, line: line)
        XCTAssertTrue(results.contains { callIDs.contains($0.toolCallID ?? "") },
                      "\(label): no result id matches a call id", file: file, line: line)
        if sameAsMessageID {
            for event in events where event.toolCallID != nil {
                XCTAssertEqual(event.toolCallID, event.messageID, "\(label): \(event.id)", file: file, line: line)
            }
        }
    }

    // MARK: - OpenCode

    func testOpenCodeCallAndResultShareCallID() throws {
        for name in ["storage_v2/session/proj_test/ses_s_stage0_small.json",
                     "storage_v2/session/proj_test/ses_s_stage0_large.json"] {
            let session = try XCTUnwrap(OpenCodeSessionParser.parseFileFull(at: fixtureURL("opencode/" + name)))
            assertPairs(session.events, name)
        }
    }

    func testOpenCodeBashSidecarHasExitAndTitle() throws {
        let part = #"{"id":"prt_1","type":"tool","tool":"bash","callID":"call_oc1","state":{"status":"completed","input":{"command":"ls"},"output":"a\nb","title":"List files","metadata":{"exit":2},"time":{"start":1776370001100,"end":1776370001200}}}"#

        // JSON-file path (storage/session, message, part).
        let storage = try makeTempDir("opencode").appendingPathComponent("storage", isDirectory: true)
        let fm = FileManager.default
        let sessionDir = storage.appendingPathComponent("session/proj", isDirectory: true)
        let messageDir = storage.appendingPathComponent("message/ses_t", isDirectory: true)
        let partDir = storage.appendingPathComponent("part/msg_1", isDirectory: true)
        for dir in [sessionDir, messageDir, partDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try #"{"id":"ses_t"}"#.write(to: sessionDir.appendingPathComponent("ses_t.json"), atomically: true, encoding: .utf8)
        try #"{"id":"msg_1","sessionID":"ses_t","role":"assistant","time":{"created":1776370001000}}"#
            .write(to: messageDir.appendingPathComponent("msg_1.json"), atomically: true, encoding: .utf8)
        try part.write(to: partDir.appendingPathComponent("prt_1.json"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(OpenCodeSessionParser.parseFileFull(at: sessionDir.appendingPathComponent("ses_t.json")))
        let fileResult = try XCTUnwrap(session.events.first { $0.kind == .error })
        XCTAssertEqual(fileResult.toolCallID, "call_oc1")
        XCTAssertEqual(fileResult.toolSidecar, ToolSidecar(exitCode: 2, agentLabel: "List files"))
        let fileCall = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        XCTAssertEqual(fileCall.toolCallID, "call_oc1")
        XCTAssertEqual(fileCall.messageID, "call_oc1")

        // Shared builder (SQLite and v2 adapter path).
        let msg = try JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self,
                                           from: Data(#"{"id":"msg_1","role":"assistant"}"#.utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any])
        let built = OpenCodeSessionParser.buildPartEvents(for: msg, parts: [(id: "prt_1", dict: dict, rawJSON: part)],
                                                          fallbackTimestamp: nil)
        let builtResult = try XCTUnwrap(built.tool.first { $0.kind == .error })
        XCTAssertEqual(builtResult.toolCallID, "call_oc1")
        XCTAssertEqual(builtResult.toolSidecar, ToolSidecar(exitCode: 2, agentLabel: "List files"))
        XCTAssertEqual(built.tool.first { $0.kind == .tool_call }?.toolCallID, "call_oc1")

        // No exit and no title: no sidecar.
        let plain = #"{"id":"prt_2","type":"tool","tool":"read","callID":"call_oc2","state":{"status":"completed","input":{},"output":"x"}}"#
        let plainDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
        let plainBuilt = OpenCodeSessionParser.buildPartEvents(for: msg, parts: [(id: "prt_2", dict: plainDict, rawJSON: plain)],
                                                               fallbackTimestamp: nil)
        XCTAssertNil(plainBuilt.tool.first { $0.kind == .tool_result }?.toolSidecar)
    }

    // MARK: - Hermes

    func testHermesCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(HermesSessionParser.parseFileFull(at: fixtureURL("hermes/large.json")))
        assertPairs(session.events, "hermes")
    }

    // MARK: - Copilot

    func testCopilotCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(CopilotSessionParser.parseFileFull(at: fixtureURL("copilot/small.jsonl")))
        assertPairs(session.events, "copilot")
    }

    func testCopilotSidecarHasExitCodeAndTitle() throws {
        let url = try writeLines([
            #"{"type":"session.start","data":{"sessionId":"cp1","version":1,"producer":"copilot-agent","copilotVersion":"1.0.89","startTime":"2026-11-04T00:00:00.000Z","selectedModel":"gpt-5-mini"},"id":"e1","timestamp":"2026-11-04T00:00:00.000Z"}"#,
            #"{"type":"user.message","data":{"content":"Run it","interactionId":"i1"},"id":"e2","timestamp":"2026-11-04T00:00:01.000Z","parentId":"e1"}"#,
            #"{"type":"assistant.message","data":{"content":"ok","toolRequests":[{"type":"function","toolCallId":"call-9","name":"bash","arguments":{"command":"false"},"toolTitle":"Running command"}],"messageId":"m1"},"id":"e3","timestamp":"2026-11-04T00:00:02.000Z","parentId":"e2"}"#,
            #"{"type":"tool.execution_start","data":{"toolCallId":"call-9","toolName":"bash","arguments":{"command":"false"},"toolTitle":"Running command"},"id":"e4","timestamp":"2026-11-04T00:00:03.000Z","parentId":"e3"}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call-9","success":false,"result":{"content":"boom"},"shellExecution":{"exitCode":2}},"id":"e5","timestamp":"2026-11-04T00:00:04.000Z","parentId":"e4"}"#
        ], name: "events.jsonl", dir: "copilot")
        let session = try XCTUnwrap(CopilotSessionParser.parseFileFull(at: url))
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        let result = try XCTUnwrap(session.events.first { $0.kind == .error })
        XCTAssertEqual(call.toolCallID, "call-9")
        XCTAssertEqual(result.toolCallID, "call-9")
        XCTAssertEqual(result.toolSidecar, ToolSidecar(exitCode: 2, agentLabel: "Running command"))

        // Backfilled call (no toolRequests entry): the id is still set.
        let backfill = try writeLines([
            #"{"type":"session.start","data":{"sessionId":"cp2","version":1,"producer":"copilot-agent","copilotVersion":"1.0.89","startTime":"2026-11-04T00:00:00.000Z","selectedModel":"gpt-5-mini"},"id":"e1","timestamp":"2026-11-04T00:00:00.000Z"}"#,
            #"{"type":"tool.execution_start","data":{"toolCallId":"call-8","toolName":"bash","arguments":{"command":"ls"}},"id":"e2","timestamp":"2026-11-04T00:00:03.000Z"}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call-8","success":true,"result":{"content":"x"}},"id":"e3","timestamp":"2026-11-04T00:00:04.000Z"}"#
        ], name: "events.jsonl", dir: "copilot2")
        let plain = try XCTUnwrap(CopilotSessionParser.parseFileFull(at: backfill))
        XCTAssertEqual(plain.events.first { $0.kind == .tool_call }?.toolCallID, "call-8")
        let plainResult = try XCTUnwrap(plain.events.first { $0.kind == .tool_result })
        XCTAssertEqual(plainResult.toolCallID, "call-8")
        XCTAssertNil(plainResult.toolSidecar)
    }

    // MARK: - Droid

    func testDroidCallAndResultShareCallID() throws {
        for name in ["droid/session_store_small.jsonl", "droid/stream_json_small.jsonl"] {
            let session = try XCTUnwrap(DroidSessionParser.parseFileFull(at: fixtureURL(name)))
            assertPairs(session.events, name)
        }
    }

    func testDroidIsErrorSidecar() throws {
        let store = try writeLines([
            #"{"type":"session_start","id":"s1","title":"T","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","timestamp":"2025-12-26T23:50:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"ls /nope"}}]}}"#,
            #"{"type":"message","id":"m2","timestamp":"2025-12-26T23:50:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Error: Command failed (exit code: 1)","is_error":true}]}}"#,
            #"{"type":"message","id":"m3","timestamp":"2025-12-26T23:50:03.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Execute","input":{"command":"ls"}}]}}"#,
            #"{"type":"message","id":"m4","timestamp":"2025-12-26T23:50:04.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu2","content":"a"}]}}"#
        ], dir: "droid")
        let session = try XCTUnwrap(DroidSessionParser.parseFileFull(at: store))
        let results = session.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.map(\.toolCallID), ["tu1", "tu2"])
        XCTAssertEqual(results[0].toolSidecar, ToolSidecar(isError: true))
        XCTAssertNil(results[1].toolSidecar)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.map(\.toolCallID), ["tu1", "tu2"])

        let stream = try writeLines([
            #"{"type":"message","session_id":"sid1","timestamp":"2025-12-26T00:00:00.000Z","role":"user","text":"Do thing"}"#,
            #"{"type":"tool_call","session_id":"sid1","timestamp":"2025-12-26T00:00:01.000Z","toolCallId":"c1","toolName":"Shell","parameters":{"command":"false"}}"#,
            #"{"type":"tool_result","session_id":"sid1","timestamp":"2025-12-26T00:00:02.000Z","toolCallId":"c1","isError":true,"value":{"stdout":"","exitCode":0}}"#
        ], dir: "droid2")
        let streamSession = try XCTUnwrap(DroidSessionParser.parseFileFull(at: stream))
        let streamResult = try XCTUnwrap(streamSession.events.first { $0.kind == .error })
        XCTAssertEqual(streamResult.toolCallID, "c1")
        XCTAssertEqual(streamResult.toolSidecar, ToolSidecar(isError: true))
        XCTAssertEqual(streamSession.events.first { $0.kind == .tool_call }?.toolCallID, "c1")
    }

    // MARK: - OpenClaw

    func testOpenClawCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(OpenClawSessionParser.parseFileFull(at: fixtureURL("openclaw/small.jsonl")))
        assertPairs(session.events, "openclaw")
    }

    // MARK: - Cursor

    func testCursorHasNoCallID() throws {
        let session = try XCTUnwrap(CursorSessionParser.parseFileFull(at: fixtureURL("cursor/small.jsonl")))
        let calls = session.events.filter { $0.kind == .tool_call }
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(session.events.allSatisfy { $0.toolCallID == nil && $0.toolSidecar == nil })
    }

    // MARK: - Pi

    func testPiCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: fixtureURL("pi/small.jsonl")))
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call && $0.toolCallID == "call-pi-fixture" })
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result && $0.toolCallID == "call-pi-fixture" })
        XCTAssertEqual(call.toolName, "ls")
        XCTAssertEqual(result.toolName, "ls")
        XCTAssertNil(result.toolSidecar)
    }

    func testPiBashExecutionSidecarHasExitCode() throws {
        let url = try writeLines([
            #"{"type":"session","version":3,"id":"pi-1","timestamp":"2026-05-12T01:02:27.657Z","cwd":"/tmp"}"#,
            #"{"type":"message","id":"b1","parentId":null,"timestamp":"2026-05-12T01:02:28.000Z","message":{"role":"bashExecution","command":"false","output":"nope\n","exitCode":3}}"#,
            #"{"type":"message","id":"b2","parentId":"b1","timestamp":"2026-05-12T01:02:29.000Z","message":{"role":"bashExecution","command":"pwd","output":"/tmp\n","exitCode":0}}"#
        ], dir: "pi")
        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: url))
        let calls = session.events.filter { $0.kind == .tool_call }
        let results = session.events.filter { $0.kind == .tool_result || $0.kind == .error }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(calls[0].toolCallID, "b1-cmd")
        XCTAssertEqual(results[0].toolCallID, "b1-cmd")
        XCTAssertEqual(results[0].toolSidecar, ToolSidecar(exitCode: 3))
        XCTAssertEqual(results[1].toolSidecar, ToolSidecar(exitCode: 0))
        XCTAssertNil(calls[0].toolSidecar)
    }

    // MARK: - Kimi

    private func stagedKimiWire() throws -> URL {
        let sessionDir = try makeTempDir("kimi")
            .appendingPathComponent("sessions/wd_project_ac3bb318f98e/session_1bcbe023-4f7e-4971-9dc9-43b8756045b0", isDirectory: true)
        let mainDir = sessionDir.appendingPathComponent("agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        let fixtures = fixtureURL("kimi")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("assistant_tools.jsonl"),
                                         to: mainDir.appendingPathComponent("wire.jsonl"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("assistant_tools.state.json"),
                                         to: sessionDir.appendingPathComponent("state.json"))
        return mainDir.appendingPathComponent("wire.jsonl")
    }

    func testKimiCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedKimiWire()))
        assertPairs(session.events, "kimi")
        // The display summary Kimi writes next to the call is the agent label.
        let bash = try XCTUnwrap(session.events.first { $0.kind == .tool_call && $0.toolCallID == "Bash_0" })
        XCTAssertEqual(bash.toolSidecar, ToolSidecar(agentLabel: "Running: ls"))
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result && $0.toolCallID == "Bash_0" })
        XCTAssertNil(result.toolSidecar)
    }

    // MARK: - Grok

    func testGrokCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: fixtureURL("grok/chat_history.jsonl")))
        assertPairs(session.events, "grok")
    }

    // MARK: - Qwen

    func testQwenCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(
            at: fixtureURL("qwen/019f0000-0000-7000-8000-000000000001.jsonl")))
        assertPairs(session.events, "qwen")
    }

    // MARK: - Devin

    func testDevinCallAndResultShareCallID() throws {
        let assistant = #"{"role":"assistant","message_id":"m3","content":"Reading.","tool_calls":[{"id":"call_1","index":0,"kind":"function","name":"read_file","arguments":{"path":"hello.py"}}]}"#
        let tool = #"{"role":"tool","message_id":"m4","tool_call_id":"call_1","content":"print(1)"}"#
        let events = DevinSessionParser.events(fromChatMessage: assistant, nodeID: 3, time: nil)
            + DevinSessionParser.events(fromChatMessage: tool, nodeID: 4, time: nil)
        assertPairs(events, "devin")
        XCTAssertEqual(events.first { $0.kind == .tool_call }?.toolCallID, "call_1")
        XCTAssertEqual(events.first { $0.kind == .tool_result }?.toolCallID, "call_1")
    }

    // MARK: - fx

    func testFxCallAndResultShareCallID() throws {
        let turn: [String: Any] = [
            "kind": "assistant",
            "user": ["text": "go"],
            "execution": [
                "tool_steps": [[
                    "assistant": "",
                    "tool_calls": [["id": "c1", "name": "run", "arguments_json": "{}"],
                                   ["id": "c2", "name": "run", "arguments_json": "{}"]],
                    "tool_results": [
                        ["tool_call_id": "c1", "tool_name": "run", "status": "success", "output": "a",
                         "command_process_presentation": ["kind": "exit_code", "value": 2],
                         "created_at_ms": 1787261100000],
                        ["tool_call_id": "c2", "tool_name": "run", "status": "success", "output": "b",
                         "command_process_presentation": ["exit_code": 0],
                         "created_at_ms": 1787261100000]
                    ]
                ]]
            ]
        ]
        let events = FxSessionParser.events(forTurn: turn, turnIndex: 0)
        assertPairs(events, "fx")
        let results = events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.map(\.toolCallID), ["c1", "c2"])
        XCTAssertEqual(results[0].toolSidecar, ToolSidecar(exitCode: 2))
        XCTAssertEqual(results[1].toolSidecar, ToolSidecar(exitCode: 0))
        XCTAssertNil(events.first { $0.kind == .tool_call }?.toolSidecar)
    }

    func testFxEventLogCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(FxSessionParser.parseFileFull(
            at: fixtureURL("fx/schema4/events.jsonl"), allowLargeFile: false))
        assertPairs(session.events, "fx schema4")
    }

    // MARK: - Cline

    func testClineCallAndResultShareCallID() throws {
        let session = try XCTUnwrap(ClineSessionParser.parseFileFull(at: fixtureURL("cline/cli_tool/cline-cli-tool.json")))
        assertPairs(session.events, "cline")
    }

    // MARK: - DeepSeek Harness

    func testDeepSeekHarnessCallAndResultShareCallID() throws {
        let rows = [
            #"{"type":"session","version":3,"id":"dsh-ids","createdAt":1700000000000,"isSeeded":false,"delegationDepth":0,"cwd":"/tmp/x"}"#,
            #"{"type":"turn/start","seq":0,"time":1700000000000,"data":{"turn":1}}"#,
            #"{"type":"step/start","seq":1,"time":1700000001000,"data":{"turn":1,"step":1}}"#,
            #"{"type":"user/message","seq":2,"time":1700000002000,"surfaceOp":"append","data":{"id":"u-1","role":"user","content":[{"type":"text","text":"Read it"}],"source":{"kind":"user"}}}"#,
            #"{"type":"assistant/message","seq":3,"time":1700000003000,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"id":"a-1","role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool-call","id":"call-7","name":"read","arguments":"{\"path\":\"p.swift\"}"}],"source":{"kind":"model","provider":"deepseek","model":"deepseek-chat"}}}}"#,
            #"{"type":"tool/call","seq":4,"time":1700000004000,"data":{"turn":1,"step":1,"callId":"call-7","name":"read","arguments":"{\"path\":\"p.swift\"}"}}"#,
            #"{"type":"tool/result","seq":5,"time":1700000005000,"surfaceOp":"append","data":{"turn":1,"step":1,"message":{"id":"r-1","role":"user","content":[{"type":"tool-result","toolCallId":"call-7","content":[{"type":"text","text":"file body"}],"isError":false}],"source":{"kind":"tool","callId":"call-7"}}}}"#,
            #"{"type":"step/end","seq":6,"time":1700000006000,"data":{"turn":1,"step":1}}"#
        ]
        let url = try writeLines(rows, name: "session.v3.jsonl", dir: "dsh")
        let session = try XCTUnwrap(DeepSeekHarnessSessionParser.parseFileFull(at: url))
        assertPairs(session.events, "dsh")
        XCTAssertEqual(session.events.first { $0.kind == .tool_call }?.toolCallID, "call-7")
        XCTAssertEqual(session.events.first { $0.kind == .tool_result }?.toolCallID, "call-7")
    }

    // MARK: - Antigravity

    func testAntigravityCallAndResultShareSyntheticID() throws {
        let url = try writeLines([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nlist\n</USER_REQUEST>"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"x","tool_calls":[{"name":"list_dir","args":{"DirectoryPath":"\"/tmp\""}},{"name":"view_file","args":{"AbsolutePath":"\"/tmp/a\""}}]}"#,
            #"{"step_index":3,"source":"MODEL","type":"LIST_DIRECTORY","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"a\nb"}"#,
            #"{"step_index":4,"source":"MODEL","type":"VIEW_FILE","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"body"}"#,
            #"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:20Z","thinking":"y","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"date\""}}]}"#,
            #"{"step_index":6,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-06-26T21:16:21Z","content":"now"}"#
        ], name: "transcript.jsonl", dir: "ag/conv-1/.system_generated/logs")
        let session = try XCTUnwrap(AntigravityTranscriptParser.parse(at: url, forcedID: "conv-1", includeEvents: true))
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.map(\.toolCallID),
                       ["ag:2:0", "ag:2:1", "ag:5:0"])
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.map(\.toolCallID),
                       ["ag:2:0", "ag:2:1", "ag:5:0"])
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.map(\.toolName),
                       ["list_dir", "view_file", "run_command"])
        // No toolSummary: no label, no sidecar.
        XCTAssertTrue(session.events.allSatisfy { $0.toolSidecar == nil })
    }

    func testAntigravityToolSummaryDecodedOnce() throws {
        let url = try writeLines([
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"x","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"date\"","toolSummary":"\"Run date command\""}}]}"#,
            #"{"step_index":3,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"now"}"#
        ], name: "transcript.jsonl", dir: "ag2/conv-2/.system_generated/logs")
        let session = try XCTUnwrap(AntigravityTranscriptParser.parse(at: url, forcedID: "conv-2", includeEvents: true))
        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(call.toolSidecar, ToolSidecar(agentLabel: "Run date command"))
        XCTAssertEqual(result.toolSidecar, ToolSidecar(agentLabel: "Run date command"))
        XCTAssertEqual(call.toolCallID, "ag:2:0")
        XCTAssertEqual(result.toolCallID, "ag:2:0")
        // The raw argument text is unchanged.
        XCTAssertTrue((call.toolInput ?? "").contains("\\\"Run date command\\\""))
    }

    // MARK: - LogicalBlock

    func testBlocksCarryToolFieldsAndMergeKeepsFirstNonNil() throws {
        func result(_ id: String, _ output: String, value: ToolPayloadValue?, sidecar: ToolSidecar?, disposition: ToolDisposition?) -> SessionEvent {
            SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                         toolName: "Bash", toolInput: nil, toolOutput: output,
                         toolCallID: "t1", toolOutputValue: value, toolSidecar: sidecar, toolDisposition: disposition,
                         messageID: nil, parentID: nil, isDelta: true, rawJSON: "{}")
        }
        let first = result("r1", "on", value: nil, sidecar: nil, disposition: nil)
        let second = result("r2", "e", value: .array([.string("x")]), sidecar: ToolSidecar(stdout: "one"), disposition: .runtimeError)
        let third = result("r3", "!", value: .string("late"), sidecar: ToolSidecar(stdout: "late"), disposition: .rejected)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: claudeSession([first, second, third]), includeMeta: false)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.text, "one!")
        XCTAssertEqual(block.toolOutputValue, .array([.string("x")]))
        XCTAssertEqual(block.toolSidecar, ToolSidecar(stdout: "one"))
        XCTAssertEqual(block.toolDisposition, .runtimeError)
    }
}
