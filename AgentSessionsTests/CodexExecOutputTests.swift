import XCTest
@testable import AgentSessions

/// Task 8: `CodexExecOutput` — Codex code-mode content items become status, chunks and loose text.
final class CodexExecOutputTests: XCTestCase {
    private func items(_ texts: [String]) -> ToolPayloadValue {
        .array(texts.map { .object(["type": .string("input_text"), "text": .string($0)]) })
    }

    private func chunk(_ id: String, exit: Int?, output: String, session: Int? = nil) -> String {
        var fields = ["\"chunk_id\":\"\(id)\"", "\"wall_time_seconds\":0.5"]
        if let exit { fields.append("\"exit_code\":\(exit)") }
        fields.append("\"original_token_count\":12")
        if let session { fields.append("\"session_id\":\(session)") }
        let escaped = output.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        fields.append("\"output\":\"\(escaped)\"")
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func script(_ source: String) throws -> CodexExecScript {
        try XCTUnwrap(CodexExecScript.parse(source))
    }

    private let header = "Script completed\nWall time 1.2 seconds\nOutput:\n"

    func testTwoCommandsTwoChunks() throws {
        let value = items([header, chunk("a", exit: 1, output: "boom\n"), chunk("b", exit: 0, output: "fine\n")])
        let out = CodexExecOutput.parse(value: value, fallback: nil)
        XCTAssertEqual(out.status, .completed)
        XCTAssertEqual(out.wallTimeSeconds, 1.2)
        XCTAssertEqual(out.chunks.count, 2)
        XCTAssertNil(out.looseText)
        let s = try script("""
        const a = await tools.exec_command({cmd: "false"});
        const b = await tools.exec_command({cmd: "true"});
        """)
        let map = CodexExecOutput.assign(out, to: s)
        XCTAssertEqual(map[0]?.exitCode, 1)
        XCTAssertEqual(map[0]?.output.text, "boom")
        XCTAssertEqual(map[1]?.exitCode, 0)
        XCTAssertEqual(map[1]?.originalTokenCount, 12)
        XCTAssertEqual(map[1]?.wallTimeSeconds, 0.5)
    }

    func testChunkInnerTruncationLifted() {
        let inner = "Warning: truncated output (original token count: 5000)\nTotal output lines: 842\n\nline one\nline two\n"
        let out = CodexExecOutput.parse(value: items([header, chunk("a", exit: 0, output: inner)]), fallback: nil)
        XCTAssertEqual(out.chunks.count, 1)
        XCTAssertEqual(out.chunks[0].facts.map(\.kind), [.truncated(agent: "codex", originalTokens: 5000, totalLines: 842)])
        XCTAssertTrue(out.chunks[0].output.text.hasPrefix("line one"))
    }

    func testPromiseAllWithCustomPrintingDoesNotAssignChunks() throws {
        let value = items([header, "---0---\n", chunk("a", exit: 0, output: "x"), "---1---\n", "---2---\n"])
        let out = CodexExecOutput.parse(value: value, fallback: nil)
        XCTAssertNotNil(out.looseText)
        XCTAssertTrue(out.looseText?.text.contains("---0---") ?? false)
        let s = try script("""
        const r = await Promise.all([
          tools.exec_command({cmd: "a"}), tools.exec_command({cmd: "b"}), tools.exec_command({cmd: "c"})]);
        for (let i = 0; i < 3; i++) text(`---${i}---`);
        """)
        XCTAssertEqual(s.calls.count, 3)
        XCTAssertEqual(CodexExecOutput.assign(out, to: s), [:])
    }

    func testRunningScript() {
        let out = CodexExecOutput.parse(value: nil, fallback: "Script running with cell ID 7\nWall time 11.0 seconds\nOutput:\n")
        XCTAssertEqual(out.status, .running(cellID: "7"))
        XCTAssertEqual(out.wallTimeSeconds, 11.0)
        XCTAssertTrue(out.chunks.isEmpty)
        XCTAssertNil(out.looseText)
    }

    func testAbortedScript() {
        let out = CodexExecOutput.parse(value: nil, fallback: "Script failed\nWall time 20.4 seconds\nOutput:\naborted by user after 20.4s")
        XCTAssertEqual(out.status, .aborted(seconds: 20.4))
    }

    func testFailedScriptStatus() {
        let out = CodexExecOutput.parse(value: nil, fallback: "Script failed\nWall time 0.1 seconds\nOutput:\nTypeError: x")
        XCTAssertEqual(out.status, .failed)
        XCTAssertEqual(out.looseText?.text, "TypeError: x")
    }

    func testJSONEncodedStringItemUnescaped() {
        let literal = "\"" + chunk("a", exit: 0, output: "hi").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let out = CodexExecOutput.parse(value: items([header, literal]), fallback: nil)
        XCTAssertEqual(out.chunks.count, 1)
        XCTAssertEqual(out.chunks[0].output.text, "hi")

        let loose = CodexExecOutput.parse(value: items([header, "\"line1\\nline2\""]), fallback: nil)
        XCTAssertEqual(loose.looseText?.text, "line1\nline2")
    }

    func testTwoChunksJoinedOnOneLineParseAsTwoChunks() {
        let joined = chunk("a", exit: 0, output: "a") + chunk("b", exit: 3, output: "b")
        let out = CodexExecOutput.parse(value: nil, fallback: header + joined)
        XCTAssertEqual(out.chunks.count, 2)
        XCTAssertEqual(out.chunks.map(\.exitCode), [0, 3])
        XCTAssertNil(out.looseText)
        // Same through a single content item holding both.
        XCTAssertEqual(CodexExecOutput.parse(value: items([header, joined]), fallback: nil).chunks.count, 2)
    }

    func testRunningChunkHasNoExitCode() {
        let out = CodexExecOutput.parse(value: items([header, chunk("a", exit: nil, output: "tick", session: 9)]), fallback: nil)
        XCTAssertEqual(out.chunks.count, 1)
        XCTAssertNil(out.chunks[0].exitCode)
    }

    func testTopLevelTruncationHeaderIsFact() {
        let trunc = "Warning: truncated output (original token count: 900)\nTotal output lines: 40\n\n"
        let out = CodexExecOutput.parse(value: items([header, trunc + chunk("a", exit: 0, output: "x")]), fallback: nil)
        XCTAssertEqual(out.chunks.count, 1)
        XCTAssertEqual(out.facts.map(\.kind), [.truncated(agent: "codex", originalTokens: 900, totalLines: 40)])
    }

    func testMalformedJSONBecomesLooseText() {
        let out = CodexExecOutput.parse(value: items([header, "{\"chunk_id\":\"a\",\"output\":\"unterminated"]), fallback: nil)
        XCTAssertTrue(out.chunks.isEmpty)
        XCTAssertNotNil(out.looseText)
        XCTAssertEqual(CodexExecOutput.parse(value: nil, fallback: nil).chunks.count, 0)
    }

    func testAssignRequiresShellCallsOnly() throws {
        let out = CodexExecOutput.parse(value: items([header, chunk("a", exit: 0, output: "x")]), fallback: nil)
        let s = try script(#"await tools.apply_patch({input: "x"});"#)
        XCTAssertEqual(CodexExecOutput.assign(out, to: s), [:])
        let w = try script(#"await tools.write_stdin({session_id: 1, chars: ""});"#)
        XCTAssertEqual(CodexExecOutput.assign(out, to: w).count, 1)
    }
}
