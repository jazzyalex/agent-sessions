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
