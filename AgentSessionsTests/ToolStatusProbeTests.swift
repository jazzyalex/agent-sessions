import XCTest
@testable import AgentSessions

/// Task 6: `ToolStatusProbe.status` — the cheap status pass (spec §6.2, §6.8, §9).
/// It reads sidecars, flags and header lines; only Codex code mode scans the whole output.
final class ToolStatusProbeTests: XCTestCase {
    private typealias F = TranscriptTestFixtures

    private func status(call: SessionTranscriptBuilder.LogicalBlock? = F.block(.toolCall),
                        outputs: [SessionTranscriptBuilder.LogicalBlock],
                        source: SessionSource = .codex) -> ToolStatus {
        ToolStatusProbe.status(call: call, outputs: outputs, source: source,
                               laterBlocksExist: true, turnAbortedAfter: false)
    }

    private func out(_ text: String, isError: Bool = false, sidecar: ToolSidecar? = nil,
                     disposition: ToolDisposition? = nil) -> SessionTranscriptBuilder.LogicalBlock {
        F.block(.toolOut, text: text, isError: isError, sidecar: sidecar, disposition: disposition)
    }

    private func codexCall(_ cmd: String) -> SessionTranscriptBuilder.LogicalBlock {
        F.block(.toolCall, toolName: "exec_command", toolInput: #"{"cmd":"\#(cmd)"}"#)
    }

    // MARK: - Codex code mode

    func testCodexExecChunkExitCodeFails() {
        let exec = F.block(.toolCall, toolName: "exec", toolInput: "await tools.exec_command({cmd: \"make\"})")
        let header = "Script completed\nWall time 0.4 seconds\nOutput:\n\n"
        let failing = header
            + #"{"chunk_id":"a","wall_time_seconds":0.1,"exit_code":0,"output":"ok"}"# + "\n"
            + #"{"chunk_id":"b","wall_time_seconds":0.2,"exit_code":2,"output":"boom"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(failing)]), .failed(exitCode: 2))

        // A chunk item that is itself a JSON-encoded string keeps escaped quotes.
        let escaped = header + #""{\"chunk_id\":\"c\",\"exit_code\":3,\"output\":\"\"}""#
        XCTAssertEqual(status(call: exec, outputs: [out(escaped)]), .failed(exitCode: 3))

        let scriptFailed = "Script failed\nWall time 0.0 seconds\nOutput:\n\nScript error:\nboom"
        XCTAssertEqual(status(call: exec, outputs: [out(scriptFailed)]), .failed(exitCode: nil))

        let allZero = header + #"{"chunk_id":"a","exit_code":0,"output":"ok"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(allZero)]), .success)

        // Not code mode outside Codex: the same text has no header exit form.
        XCTAssertEqual(status(call: exec, outputs: [out(failing)], source: .claude), .success)

        // Real shape: content items are joined with no separator, so chunk objects follow each other.
        let joined = header
            + #"{"chunk_id":"a","exit_code":0,"original_token_count":3,"output":"README.md\n"}"#
            + #"{"chunk_id":"b","exit_code":2,"original_token_count":1,"output":"boom"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(joined)]), .failed(exitCode: 2))
    }

    func testCodeModeStdoutMentioningExitCodeIsNotAFailure() {
        let exec = F.block(.toolCall, toolName: "exec", toolInput: "await tools.exec_command({cmd: \"cat x\"})")
        let header = "Script completed\nWall time 0.4 seconds\nOutput:\n"
        // Only the chunk metadata before `output` is read.
        let plain = header + #"{"chunk_id":"a","exit_code":0,"output":"{\"exit_code\":2}"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(plain)]), .success)
        // A body that starts with a chunk object is not a chunk.
        let nested = header + #"{"chunk_id":"a","exit_code":0,"output":"{\"chunk_id\":\"z\",\"exit_code\":2}"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(nested)]), .success)
        // The same inside a JSON-encoded string item.
        let encoded = header + #""{\"chunk_id\":\"a\",\"exit_code\":0,\"output\":\"{\\\"exit_code\\\":2}\"}""#
        XCTAssertEqual(status(call: exec, outputs: [out(encoded)]), .success)
    }

    func testCodeModeGrepNoMatchChunkIsSuccess() {
        let exec = F.block(.toolCall, toolName: "exec", toolInput: "await tools.exec_command({cmd: \"rg foo\"})")
        let header = "Script completed\nWall time 0.3 seconds\nOutput:\n"
        let noMatch = header
            + #"{"chunk_id":"042765","exit_code":0,"original_token_count":4,"output":"master\n"}"#
            + #"{"chunk_id":"ccdd45","wall_time_seconds":0.00003,"exit_code":1,"original_token_count":0,"output":""}"#
        XCTAssertEqual(status(call: exec, outputs: [out(noMatch)]), .success)
        let encodedNoMatch = header + #""{\"chunk_id\":\"c\",\"exit_code\":1,\"output\":\"\"}""#
        XCTAssertEqual(status(call: exec, outputs: [out(encodedNoMatch)]), .success)

        // Exit 1 with output, or another code with empty output, still fails.
        let exitOneWithOutput = header + #"{"chunk_id":"d","exit_code":1,"output":"rg: error"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(exitOneWithOutput)]), .failed(exitCode: 1))
        let exitTwoEmpty = header + #"{"chunk_id":"e","exit_code":2,"output":""}"#
        XCTAssertEqual(status(call: exec, outputs: [out(exitTwoEmpty)]), .failed(exitCode: 2))
    }

    func testCodeModeSessionChunkIsPending() {
        let exec = F.block(.toolCall, toolName: "exec", toolInput: "await tools.exec_command({cmd: \"npm run dev\"})")
        let header = "Script completed\nWall time 10.0 seconds\nOutput:\n"
        let running = header + #"{"chunk_id":"df07ab","wall_time_seconds":10.0,"session_id":90623,"output":"…"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(running)]), .pending)
        // With an exit code the process has ended.
        let ended = header + #"{"chunk_id":"df07ac","session_id":90623,"exit_code":0,"output":"done"}"#
        XCTAssertEqual(status(call: exec, outputs: [out(ended)]), .success)
    }

    // MARK: - Grep family

    func testRgExitOneEmptyIsSuccess() {
        let empty = "Process exited with code 1\nOutput:\n"
        XCTAssertEqual(status(call: codexCall("rg foo"), outputs: [out(empty)]), .success)

        // Control: another command with exit 1 fails.
        XCTAssertEqual(status(call: codexCall("make"), outputs: [out(empty)]), .failed(exitCode: 1))
        // rg with output (a real error) fails.
        XCTAssertEqual(status(call: codexCall("rg foo"), outputs: [out(empty + "rg: regex parse error")]),
                       .failed(exitCode: 1))
        // rg exit 2 fails.
        XCTAssertEqual(status(call: codexCall("rg foo"), outputs: [out("Process exited with code 2\nOutput:\n")]),
                       .failed(exitCode: 2))
    }

    func testGrepFamilyLooksPastShellWrappers() {
        let empty = "Exit code: 1\nOutput:\n"
        let argv = F.block(.toolCall, toolName: "shell",
                           toolInput: #"{"command":["bash","-lc","cd /repo && rg -n foo"]}"#)
        XCTAssertEqual(status(call: argv, outputs: [out(empty)]), .success)

        let wrappedString = F.block(.toolCall, toolName: "Bash",
                                    toolInput: #"{"command":"zsh -lc 'cd /repo; grep -R foo .'"}"#)
        XCTAssertEqual(status(call: wrappedString, outputs: [out(empty)]), .success)

        for command in ["git grep foo", "egrep foo f", "fgrep foo f", "ag foo", "ack foo", "/usr/bin/grep foo f"] {
            XCTAssertEqual(status(call: codexCall(command), outputs: [out(empty)]), .success, command)
        }
        XCTAssertEqual(status(call: codexCall("git status"), outputs: [out(empty)]), .failed(exitCode: 1))
        XCTAssertEqual(status(call: codexCall("echo rg"), outputs: [out(empty)]), .failed(exitCode: 1))

        // Claude Bash: rg with no matches is an is_error result "Error: Exit code 1".
        let claudeRg = F.block(.toolCall, toolName: "Bash", toolInput: #"{"command":"rg -n foo src"}"#)
        XCTAssertEqual(status(call: claudeRg,
                              outputs: [out("Error: Exit code 1", isError: true, disposition: .runtimeError)],
                              source: .claude),
                       .success)

        // Codex exec_command envelope around an empty rg result.
        let envelope = "Chunk ID: 0a1b\nWall time: 0.0 seconds\nProcess exited with code 1\n"
            + "Original token count: 0\nOutput:\n"
        XCTAssertEqual(status(call: codexCall("rg foo"), outputs: [out(envelope)]), .success)
    }

    // MARK: - Exit code forms

    func testFirstLineExitForms() {
        XCTAssertEqual(status(outputs: [out("Exit code 2\nboom")]), .failed(exitCode: 2))
        XCTAssertEqual(status(outputs: [out("Exit code: 3\nWall time: 0.1 seconds\nOutput:\nx")]), .failed(exitCode: 3))
        XCTAssertEqual(status(outputs: [out("Process exited with code 4\nOutput:\nx")]), .failed(exitCode: 4))
        XCTAssertEqual(status(outputs: [out("exit: 5\nx")]), .failed(exitCode: 5))
        XCTAssertEqual(status(outputs: [out("Command exited with code 6.\nx")]), .failed(exitCode: 6))
        XCTAssertEqual(status(outputs: [out("Error: Command failed (exit code: 7)\nx")]), .failed(exitCode: 7))
        XCTAssertEqual(status(outputs: [out("<status>completed</status>\n<exit_code>8</exit_code>\n<output>x")]),
                       .failed(exitCode: 8))
        // Claude keeps a failed Bash result as its `toolUseResult` string.
        XCTAssertEqual(status(outputs: [out("Error: Exit code 9\nboom", isError: true, disposition: .runtimeError)]),
                       .failed(exitCode: 9))
        XCTAssertEqual(status(outputs: [out("Exit code 0\nfine")]), .success)
        XCTAssertEqual(status(outputs: [out("Process exited with code 0\nOutput:\nfine")]), .success)

        // Only the first line is read: a later "Exit code" is body text.
        XCTAssertEqual(status(outputs: [out("hello\nExit code 2")]), .success)
        // `<exit_code>` past the first 200 characters is body text.
        XCTAssertEqual(status(outputs: [out(String(repeating: "y", count: 220) + "<exit_code>9</exit_code>")]),
                       .success)
    }

    func testCodexEnvelopeHeaderExitCode() {
        // Codex exec_command writes `Chunk ID` and `Wall time` lines before the exit line.
        let text = "Chunk ID: d21294\nWall time: 0.0000 seconds\nProcess exited with code 2\n"
            + "Original token count: 5\nOutput:\nboom"
        XCTAssertEqual(status(call: codexCall("make"), outputs: [out(text)]), .failed(exitCode: 2))
    }

    func testSidecarExitCodeWins() {
        XCTAssertEqual(status(outputs: [out("Exit code 0", sidecar: ToolSidecar(exitCode: 3))]),
                       .failed(exitCode: 3))
        XCTAssertEqual(status(outputs: [out("Exit code 2", sidecar: ToolSidecar(exitCode: 0))]), .success)
        XCTAssertEqual(status(outputs: [out("", sidecar: ToolSidecar(exitCode: 1))]), .failed(exitCode: 1))
    }

    // MARK: - Flags

    func testErrorFlagsWithoutExitCodeFail() {
        XCTAssertEqual(status(outputs: [out("error: nope", isError: true)]), .failed(exitCode: nil))
        XCTAssertEqual(status(outputs: [out("nope", disposition: .runtimeError)]), .failed(exitCode: nil))
        XCTAssertEqual(status(outputs: [out("nope", sidecar: ToolSidecar(isError: true))]), .failed(exitCode: nil))
        XCTAssertEqual(status(outputs: [out("The user doesn't want to proceed", disposition: .rejected)]), .rejected)
        XCTAssertEqual(status(outputs: [out("all good")]), .success)
    }

    func testSidecarInterruptedIsInterrupted() {
        XCTAssertEqual(status(outputs: [out("partial", sidecar: ToolSidecar(interrupted: true))]), .interrupted)
    }

    func testRunningProcessHeaderIsPending() {
        // Spec §7.4: a process or cell still running after the call returns is pending.
        let running = "Chunk ID: ab12\nWall time: 10.0 seconds\nProcess running with session ID 42437\n"
            + "Original token count: 0\nOutput:\nstarting"
        XCTAssertEqual(status(call: codexCall("npm run dev"), outputs: [out(running)]), .pending)
        let cell = F.block(.toolCall, toolName: "exec", toolInput: "await tools.exec_command({cmd: \"sleep 99\"})")
        XCTAssertEqual(status(call: cell, outputs: [out("Script running with cell ID 7\nWall time 11.0 seconds\nOutput:\n")]),
                       .pending)
    }

    // MARK: - No output

    func testNoOutputStatuses() {
        let call = F.block(.toolCall)
        func probe(source: SessionSource = .codex, later: Bool, aborted: Bool) -> ToolStatus {
            ToolStatusProbe.status(call: call, outputs: [], source: source,
                                   laterBlocksExist: later, turnAbortedAfter: aborted)
        }
        XCTAssertEqual(probe(later: false, aborted: false), .pending)
        XCTAssertEqual(probe(later: true, aborted: false), .noResult)
        XCTAssertEqual(probe(later: true, aborted: true), .interrupted)
        XCTAssertEqual(probe(later: false, aborted: true), .interrupted)
        XCTAssertEqual(probe(source: .cursor, later: false, aborted: false), .unknown)
        XCTAssertEqual(probe(source: .cursor, later: true, aborted: true), .unknown)
    }
}
