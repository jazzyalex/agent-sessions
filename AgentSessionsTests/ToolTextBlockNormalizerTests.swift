import XCTest
import Foundation
@testable import AgentSessions

final class ToolTextBlockNormalizerTests: XCTestCase {
    private func makeEvent(id: String = "e1",
                           kind: SessionEventKind,
                           toolName: String? = nil,
                           toolInput: String? = nil,
                           toolOutput: String? = nil,
                           text: String? = nil,
                           rawJSON: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: toolName,
                     toolInput: toolInput,
                     toolOutput: toolOutput,
                     messageID: "call_1",
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON)
    }

    func testCodexShellCommandCallIncludesCommandAndMeta() {
        let input = #"{"command":"ls -la","cwd":"/tmp","timeout_ms":1000}"#
        let event = makeEvent(kind: .tool_call,
                              toolName: "shell_command",
                              toolInput: input,
                              rawJSON: "{}")
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.toolLabel, "bash")
        XCTAssertEqual(block?.lines, ["ls -la", "cwd: /tmp   timeout: 1000ms"])
    }

    func testCodexToolResultStdoutStderrExit() {
        let output = #"{"stdout":"file1\n","stderr":"err\n","exitCode":1}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "bash",
                              toolOutput: output,
                              rawJSON: output)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.toolLabel, "bash")
        XCTAssertEqual(block?.lines, ["file1", "err", "exit: 1"])
    }

    func testClaudeToolUseResultPrefersStdoutOverOk() {
        let raw = #"{"toolUseResult":{"stdout":"hi\n","stderr":"","is_error":false},"message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "bash",
                              toolOutput: "ok",
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .claude)
        XCTAssertEqual(block?.lines, ["hi"])
    }

    func testDroidToolResultStringValue() {
        let raw = #"{"type":"tool_result","value":"ls: /nope"}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "Shell",
                              toolOutput: nil,
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .droid)
        XCTAssertEqual(block?.lines, ["ls: /nope"])
    }

    func testCopilotExecutionCompleteContentToLines() {
        let raw = #"{"type":"tool.execution_complete","data":{"result":{"content":"file1\nfile2\n"}}}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "bash",
                              toolOutput: nil,
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .copilot)
        XCTAssertEqual(block?.lines, ["file1", "file2"])
    }

    func testUpdatePlanChecklistLines() {
        let input = #"{"plan":[{"step":"Update onboarding","status":"completed"},{"step":"Rebuild schema","status":"in_progress"},{"step":"Commit","status":"pending"},{"step":"Notify","status":"unknown"}]}"#
        let event = makeEvent(kind: .tool_call,
                              toolName: "update_plan",
                              toolInput: input,
                              rawJSON: "{}")
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.toolLabel, "plan")
        XCTAssertEqual(block?.lines, ["[x] Update onboarding", "[>] Rebuild schema", "[ ] Commit", "- Notify"])
    }

    func testEmptyOutputEnvelopeShowsNoOutput() {
        let event = makeEvent(kind: .tool_result,
                              toolName: "bash",
                              toolOutput: "{}",
                              rawJSON: "{}")
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.lines, ["(no output)"])
    }

    func testShellOutputShowsNoOutputWithExitCode() {
        let raw = #"{"exitCode":0}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "bash",
                              toolOutput: nil,
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.lines, ["(no output)", "exit: 0"])
    }

    func testFileOperationCallFormatting() {
        let readEvent = makeEvent(kind: .tool_call,
                                  toolName: "read_file",
                                  toolInput: #"{"file_path":"/tmp/a.txt"}"#,
                                  rawJSON: "{}")
        let listEvent = makeEvent(kind: .tool_call,
                                  toolName: "list_dir",
                                  toolInput: #"{"directoryPath":"/tmp"}"#,
                                  rawJSON: "{}")
        let globEvent = makeEvent(kind: .tool_call,
                                  toolName: "glob",
                                  toolInput: #"{"folder":"/tmp","patterns":["*.md","*.txt"]}"#,
                                  rawJSON: "{}")

        let readBlock = ToolTextBlockNormalizer.normalize(event: readEvent, source: .codex)
        XCTAssertEqual(readBlock?.toolLabel, "read")
        XCTAssertEqual(readBlock?.lines, ["/tmp/a.txt"])

        let listBlock = ToolTextBlockNormalizer.normalize(event: listEvent, source: .codex)
        XCTAssertEqual(listBlock?.toolLabel, "list")
        XCTAssertEqual(listBlock?.lines, ["/tmp"])

        let globBlock = ToolTextBlockNormalizer.normalize(event: globEvent, source: .codex)
        XCTAssertEqual(globBlock?.toolLabel, "glob")
        XCTAssertEqual(globBlock?.lines, ["folder: /tmp", "patterns: [\"*.md\",\"*.txt\"]"])
    }

    func testOpenCodeToolCallQueryFormatting() {
        let input = #"{"numResults":8,"query":"\"neo-classical techno\" \"high energy\" artists similar to Max Cooper Apple Music 2024 2025"}"#
        let event = makeEvent(kind: .tool_call,
                              toolName: "tool",
                              toolInput: input,
                              rawJSON: "{}")
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .opencode)
        XCTAssertEqual(block?.lines, [
            "query: \"neo-classical techno\" \"high energy\" artists similar to Max Cooper Apple Music 2024 2025",
            "numResults: 8"
        ])
    }

    func testOpenCodeMarkdownUrlOutput() {
        let raw = #"{"type":"tool","state":{"output":{"format":"markdown","url":"https://github.com/aome510/spotify-player"}}}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "tool",
                              toolOutput: nil,
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .opencode)
        XCTAssertEqual(block?.lines, ["https://github.com/aome510/spotify-player"])
    }

    func testGroupKeyFallsBackToRawJSONCallID() {
        let raw = #"{"tool_call_id":"call_123","stdout":"ok"}"#
        let event = SessionEvent(id: "e2",
                                 timestamp: nil,
                                 kind: .tool_result,
                                 role: nil,
                                 text: nil,
                                 toolName: "bash",
                                 toolInput: nil,
                                 toolOutput: nil,
                                 messageID: nil,
                                 parentID: nil,
                                 isDelta: false,
                                 rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .codex)
        XCTAssertEqual(block?.groupKey, "call_123")
    }

    func testOpenClawExecToolCallUsesYieldMsAsTimeoutMeta() {
        let input = #"{"command":"ls -la","yieldMs":10000}"#
        let event = makeEvent(kind: .tool_call,
                              toolName: "exec",
                              toolInput: input,
                              rawJSON: "{}")
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .openclaw)
        XCTAssertEqual(block?.toolLabel, "bash")
        XCTAssertEqual(block?.lines, ["ls -la", "timeout: 10000ms"])
    }

    func testOpenClawExecToolResultFromBase64RawJSONIncludesExitCode() throws {
        let rawObject: [String: Any] = [
            "type": "message",
            "message": [
                "role": "toolResult",
                "toolName": "exec",
                "details": [
                    "status": "completed",
                    "exitCode": 0
                ]
            ]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: rawObject, options: [])
        let rawBase64 = rawData.base64EncodedString()

        let event = makeEvent(kind: .tool_result,
                              toolName: "exec",
                              toolOutput: "file1\n",
                              rawJSON: rawBase64)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .openclaw)
        XCTAssertEqual(block?.toolLabel, "bash")
        XCTAssertEqual(block?.lines, ["file1", "exit: 0"])
    }

    func testOpenClawExecToolResultTextBlocksWithLiteralNewlinesRendersAsPlainText() {
        // Non-strict JSON output observed from some tool runners: newline characters inside string literals.
        let output = "[{\"text\":\"line1\nline2\",\"type\":\"text\"}]"
        let raw = #"{"exitCode":0}"#
        let event = makeEvent(kind: .tool_result,
                              toolName: "exec",
                              toolOutput: output,
                              rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .openclaw)
        XCTAssertEqual(block?.toolLabel, "bash")
        XCTAssertEqual(block?.lines, ["line1", "line2", "exit: 0"])
    }

    func testOpenClawParserDropsMediaAttachedHintWhenImagePresent() throws {
        let jsonl = """
        {\"type\":\"session\",\"version\":3,\"id\":\"s1\",\"timestamp\":\"2026-02-04T00:00:00Z\",\"cwd\":\"/tmp\"}
        {\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2026-02-04T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"[media attached: /tmp/a.jpg (image/jpeg) | /tmp/a.jpg]\\nTo send an image back, prefer the message tool (media/path/filePath).\"},{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/jpeg\"}]}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (jsonl + "\n").write(to: url, atomically: true, encoding: .utf8)

        let session = OpenClawSessionParser.parseFileFull(at: url)
        let user = session?.events.first(where: { $0.kind == .user })
        XCTAssertEqual(user?.text, "Image attached")
    }
}
