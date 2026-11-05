import XCTest
@testable import AgentSessions

/// Task 9: `ToolInvocationBuilder` turns a paired invocation into actions (category, verb, object,
/// context, command, decoded output, plain text) and into the cheap L1 row summary.
final class ToolInvocationBuilderTests: XCTestCase {
    private typealias F = TranscriptTestFixtures
    private typealias Block = SessionTranscriptBuilder.LogicalBlock

    /// A built session: the full block stream and its pairing index.
    private struct Built {
        var blocks: [Block]
        var index: ToolInvocationIndex
        var source: SessionSource

        func ref(at block: Int) -> ToolInvocationRef {
            let id = index.invocationIDByBlock[block] ?? -1
            return index.invocations.first { $0.id == id }
                ?? ToolInvocationRef(id: -1, callBlockIndex: nil, outputBlockIndices: [], status: .unknown)
        }

        func invocation(at block: Int, duration: Double? = nil) -> ToolInvocation {
            ToolInvocationBuilder.build(ref(at: block), blocks: blocks, index: index, source: source, duration: duration)
        }

        func summary(at block: Int) -> ToolRowSummary {
            ToolInvocationBuilder.rowSummary(ref(at: block), blocks: blocks, index: index, source: source)
        }
    }

    private func session(_ blocks: [Block], source: SessionSource) -> Built {
        let stream = F.sequence(blocks)
        return Built(blocks: stream, index: ToolInvocationIndex.build(blocks: stream, source: source), source: source)
    }

    private func json(_ object: [String: Any]) -> String {
        ToolJSON.string(from: object, pretty: false) ?? "{}"
    }

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

    /// A Codex code-mode output block: content items as the value, joined text as the block text.
    private func codeModeOutput(id: String, _ texts: [String]) -> Block {
        var out = F.block(.toolOut, id: id, text: texts.joined(), toolName: "exec")
        out.toolOutputValue = items(texts)
        return out
    }

    private let scriptHeader = "Script completed\nWall time 1.2 seconds\nOutput:\n"

    // MARK: - Q1 objects

    func testClaudeBashUsesDescriptionAsObject() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash", toolInput: json(["command": "ls", "description": "List files"])),
            F.block(.toolOut, id: "t1", text: "a\nb", toolName: "Bash"),
        ], source: .claude)
        let invocation = s.invocation(at: 1)
        XCTAssertEqual(invocation.actions.count, 1)
        let action = invocation.actions[0]
        XCTAssertEqual(action.category, .shell)
        XCTAssertEqual(action.verbKey, "tool.verb.ran")
        XCTAssertEqual(action.object, "List files")
        XCTAssertTrue(action.objectIsAgentLabel)
        XCTAssertEqual(action.command, "ls")
        XCTAssertEqual(action.exactCommand, "ls")
        XCTAssertEqual(action.output?.text, "a\nb")
        XCTAssertEqual(action.status, .success)
        XCTAssertEqual(action.plainText, "$ ls\na\nb", "plainText keeps the command, never the label")
        XCTAssertEqual(invocation.displayToolName, "Bash")
        XCTAssertEqual(s.summary(at: 1).actions, [
            ToolRowAction(category: .shell, verbKey: "tool.verb.ran", object: "List files",
                          objectIsAgentLabel: true, objectDetail: nil, status: .success, chips: []),
        ])

        // A ready-made label: the call's sidecar wins over an output's; `description` wins over both.
        let labelled = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "bash", toolInput: json(["command": "npm test"]),
                    sidecar: ToolSidecar(agentLabel: "Run the tests")),
            F.block(.toolOut, id: "t1", text: "ok", toolName: "bash", sidecar: ToolSidecar(agentLabel: "Output label")),
            F.block(.toolCall, id: "t2", toolName: "bash", toolInput: json(["command": "npm run lint"])),
            F.block(.toolOut, id: "t2", text: "ok", toolName: "bash", sidecar: ToolSidecar(agentLabel: "Lint")),
            F.block(.toolCall, id: "t3", toolName: "bash", toolInput: json(["command": "make", "description": "Build"]),
                    sidecar: ToolSidecar(agentLabel: "Title")),
            F.block(.toolOut, id: "t3", text: "ok", toolName: "bash"),
        ], source: .opencode)
        XCTAssertEqual(labelled.invocation(at: 1).actions[0].object, "Run the tests")
        XCTAssertTrue(labelled.invocation(at: 1).actions[0].objectIsAgentLabel)
        XCTAssertEqual(labelled.invocation(at: 1).actions[0].command, "npm test")
        XCTAssertEqual(labelled.invocation(at: 3).actions[0].object, "Lint")
        XCTAssertEqual(labelled.summary(at: 3).actions.first?.object, "Lint")
        XCTAssertEqual(labelled.invocation(at: 5).actions[0].object, "Build")
    }

    func testCodexExecCommandObjectIsCommand() {
        let output = "Chunk ID: a1\nWall time: 0.1 seconds\nProcess exited with code 0\nOriginal token count: 3\nOutput:\nclean\n"
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "git status", "workdir": "/repo"])),
            F.block(.toolOut, id: "t1", text: output, toolName: "exec_command"),
        ], source: .codex)
        let action = s.invocation(at: 1).actions[0]
        XCTAssertEqual(action.object, "git status")
        XCTAssertFalse(action.objectIsAgentLabel)
        XCTAssertEqual(action.command, "git status")
        XCTAssertEqual(action.context, [ToolContextItem(key: "cwd", value: "/repo")])
        XCTAssertTrue(action.inputFields.isEmpty, "the shell renderer shows the command, not a field list")
        XCTAssertEqual(action.output?.text, "clean")
        XCTAssertEqual(action.facts.map(\.kind), [.exitCode(0), .wallTime(0.1)])
        XCTAssertEqual(action.plainText, "$ git status\n[exit 0 · 0.1s]\nclean")
        XCTAssertEqual(s.summary(at: 1).actions.first?.object, "git status")
        XCTAssertEqual(s.summary(at: 1).chips, [])
    }

    // MARK: - Shell context

    func testWrapperLiftedToContext() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "shell", toolInput: json(["command": ["bash", "-lc", "cd /x && make"]])),
            F.block(.toolOut, id: "t1", text: "done"),
            F.block(.toolCall, id: "t2", toolName: "exec_command", toolInput: json(["cmd": "cd sub && make test", "workdir": "/repo"])),
            F.block(.toolOut, id: "t2", text: "done", toolName: "exec_command"),
            F.block(.toolCall, id: "t3", toolName: "exec_command", toolInput: json(["cmd": "cd /x"])),
            F.block(.toolOut, id: "t3", text: "", toolName: "exec_command"),
            F.block(.toolCall, id: "t4", toolName: "shell", toolInput: json(["command": ["git", "commit", "-m", "fix it"]])),
            F.block(.toolOut, id: "t4", text: "done"),
        ], source: .codex)
        let wrapped = s.invocation(at: 1).actions[0]
        XCTAssertEqual(wrapped.command, "make")
        XCTAssertEqual(wrapped.object, "make")
        XCTAssertEqual(wrapped.context, [ToolContextItem(key: "cwd", value: "/x"), ToolContextItem(key: "shell", value: "bash -lc")])
        XCTAssertEqual(wrapped.exactCommand, "bash -lc 'cd /x && make'", "the exact command keeps the wrapper and cd")
        XCTAssertEqual(wrapped.plainText, "$ bash -lc 'cd /x && make'\ndone", "plainText and Copy use the exact command")

        let relative = s.invocation(at: 3).actions[0]
        XCTAssertEqual(relative.command, "make test")
        XCTAssertEqual(relative.context, [ToolContextItem(key: "cwd", value: "/repo/sub")])
        XCTAssertEqual(relative.exactCommand, "cd sub && make test")
        XCTAssertTrue(relative.plainText.hasPrefix("$ cd sub && make test\n"))

        XCTAssertEqual(s.invocation(at: 5).actions[0].command, "cd /x", "a bare cd is the whole command")
        XCTAssertEqual(s.invocation(at: 7).actions[0].command, "git commit -m 'fix it'", "argv joins with shell quoting")

        // A string wrapper with one quoted script lifts too (Claude, OpenCode).
        let claude = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash", toolInput: json(["command": "bash -lc 'cd \"/my dir\"; make test'", "timeout": 120000])),
            F.block(.toolOut, id: "t1", text: "ok", toolName: "Bash"),
        ], source: .claude)
        let lifted = claude.invocation(at: 1).actions[0]
        XCTAssertEqual(lifted.command, "make test")
        XCTAssertEqual(lifted.object, "make test")
        XCTAssertEqual(lifted.context, [ToolContextItem(key: "cwd", value: "/my dir"),
                                        ToolContextItem(key: "shell", value: "bash -lc"),
                                        ToolContextItem(key: "timeout", value: "120000")])
        XCTAssertEqual(lifted.plainText, "$ bash -lc 'cd \"/my dir\"; make test'\nok")
    }

    func testHeredocSplitsBody() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash", toolInput: json(["command": "cat > f.sh <<'EOF'\n#!/bin/zsh\nls\nEOF"])),
            F.block(.toolOut, id: "t1", text: "", toolName: "Bash"),
            F.block(.toolCall, id: "t2", toolName: "Bash", toolInput: json(["command": "cat > f.sh <<EOF\nx\nEOF\nchmod +x f.sh"])),
            F.block(.toolOut, id: "t2", text: "", toolName: "Bash"),
            F.block(.toolCall, id: "t3", toolName: "Bash", toolInput: json(["command": "cat <<-END > g\n\tx\n\tEND\n"])),
            F.block(.toolOut, id: "t3", text: "", toolName: "Bash"),
            F.block(.toolCall, id: "t4", toolName: "Bash", toolInput: json(["command": "cat <<< \"x\"\necho y"])),
            F.block(.toolOut, id: "t4", text: "", toolName: "Bash"),
        ], source: .claude)
        let split = s.invocation(at: 1).actions[0]
        XCTAssertEqual(split.verbKey, "tool.verb.ran")
        XCTAssertEqual(split.command, "cat > f.sh <<'EOF'")
        XCTAssertEqual(split.heredoc?.text, "#!/bin/zsh\nls")
        XCTAssertEqual(split.object, "cat > f.sh <<'EOF'")
        XCTAssertEqual(split.plainText, "$ cat > f.sh <<'EOF'\n#!/bin/zsh\nls\nEOF", "plainText keeps the whole command")

        let trailing = s.invocation(at: 3).actions[0]
        XCTAssertNil(trailing.heredoc, "text after the terminator: no split, nothing is lost")
        XCTAssertEqual(trailing.command, "cat > f.sh <<EOF\nx\nEOF\nchmod +x f.sh")

        let dashed = s.invocation(at: 5).actions[0]
        XCTAssertEqual(dashed.command, "cat <<-END > g")
        XCTAssertEqual(dashed.heredoc?.text, "\tx")

        XCTAssertNil(s.invocation(at: 7).actions[0].heredoc, "a here-string is not a heredoc")
    }

    // MARK: - Codex code mode

    func testCodexScriptFlattensToTwoActions() {
        let script = """
        const a = await tools.exec_command({cmd: "false"});
        const b = await tools.exec_command({cmd: "true", workdir: "/repo"});
        """
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: script),
            codeModeOutput(id: "t1", [scriptHeader, chunk("a", exit: 1, output: "boom\n"), chunk("b", exit: 0, output: "fine\n")]),
        ], source: .codex)
        let invocation = s.invocation(at: 1)
        XCTAssertEqual(invocation.actions.count, 2)
        XCTAssertEqual(invocation.displayToolName, "exec")
        XCTAssertEqual(invocation.scriptSource, script)
        XCTAssertEqual(invocation.durationSeconds, 1.2, "the script header's wall time when no duration is given")
        XCTAssertEqual(invocation.actions.map(\.category), [.shell, .shell])
        XCTAssertEqual(invocation.actions.map(\.verbKey), ["tool.verb.ran", "tool.verb.ran"])
        XCTAssertEqual(invocation.actions.map(\.command), ["false", "true"])
        XCTAssertEqual(invocation.actions.map(\.object), ["false", "true"])
        XCTAssertEqual(invocation.actions[0].context, [ToolContextItem(key: "script", value: "exec script · command 1 of 2")])
        XCTAssertEqual(invocation.actions[1].context, [ToolContextItem(key: "script", value: "exec script · command 2 of 2"),
                                                       ToolContextItem(key: "cwd", value: "/repo")])
        XCTAssertEqual(invocation.actions.map { $0.output?.text }, ["boom", "fine"])
        XCTAssertEqual(invocation.actions.map(\.status), [.failed(exitCode: 1), .success])
        XCTAssertEqual(invocation.actions[0].plainText, "$ false\n[exit 1 · 0.5s]\nboom")
        XCTAssertNil(invocation.scriptOutput)
        XCTAssertEqual(invocation.plainText, invocation.actions[0].plainText + "\n\n" + invocation.actions[1].plainText)

        // L1: each command has its own chunk's status, read from chunk metadata only.
        let row = s.summary(at: 1)
        XCTAssertEqual(row.actions.map(\.object), ["false", "true"])
        XCTAssertEqual(row.actions.map(\.status), [.failed(exitCode: 1), .success])
        XCTAssertEqual(row.actions.map(\.chips), [["exit 1"], []])
        XCTAssertEqual(row.chips, ["exit 1"], "the invocation's chips stay invocation-level")
        XCTAssertEqual(row.actions.map(\.verbKey), invocation.actions.map(\.verbKey))
        XCTAssertEqual(row.actions.map(\.status), invocation.actions.map(\.status), "build and rowSummary agree")
    }

    func testUnassignedScriptOutputShowsUnderTheScript() {
        // Promise.all with custom printing: one chunk for three commands, so nothing maps by order.
        let script = """
        const r = await Promise.all([
          tools.exec_command({cmd: "a"}), tools.exec_command({cmd: "b"}), tools.exec_command({cmd: "c"})]);
        for (let i = 0; i < 3; i++) text(`---${i}---`);
        """
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: script),
            codeModeOutput(id: "t1", [scriptHeader, "---0---\n", chunk("a", exit: 0, output: "x"), "---1---\n", "---2---\n"]),
        ], source: .codex)
        let invocation = s.invocation(at: 1)
        XCTAssertEqual(invocation.actions.map(\.command), ["a", "b", "c"], "the three commands only, no extra action")
        XCTAssertTrue(invocation.actions.allSatisfy { $0.output == nil }, "children show their commands only")
        let scriptOutput = invocation.scriptOutput
        XCTAssertNotNil(scriptOutput)
        XCTAssertTrue(scriptOutput?.text.contains("x") ?? false)
        XCTAssertTrue(scriptOutput?.text.contains("---0---") ?? false)
        XCTAssertTrue(invocation.plainText.hasSuffix("\n\n" + (scriptOutput?.text ?? "∅")), "plainText ends with the script output")

        let row = s.summary(at: 1)
        XCTAssertEqual(row.actions.count, invocation.actions.count)
        XCTAssertEqual(row.actions.map(\.object), invocation.actions.map(\.object))
        XCTAssertEqual(row.actions.map(\.status), [.success, .success, .success], "unmapped commands take the invocation's status")
    }

    func testScriptParseFailureIsRanScript() {
        let script = "const x = 1;\nconsole.log(x)"
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: script),
            codeModeOutput(id: "t1", [scriptHeader, "1\n"]),
        ], source: .codex)
        let invocation = s.invocation(at: 1)
        XCTAssertEqual(invocation.actions.count, 1)
        let action = invocation.actions[0]
        XCTAssertEqual(action.category, .shell)
        XCTAssertEqual(action.verbKey, "tool.verb.ranScript")
        XCTAssertEqual(action.command, script)
        XCTAssertEqual(action.object, "const x = 1;")
        XCTAssertFalse(action.objectIsAgentLabel)
        XCTAssertEqual(action.output?.text, "1")
        XCTAssertEqual(invocation.scriptSource, script)
        XCTAssertEqual(s.summary(at: 1).actions.map(\.verbKey), ["tool.verb.ranScript"])
    }

    // MARK: - Polls

    func testPollVerb() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "write_stdin", toolInput: json(["session_id": 42437, "chars": ""])),
            F.block(.toolOut, id: "t1", text: "", toolName: "write_stdin"),
            F.block(.toolCall, id: "t2", toolName: "write_stdin", toolInput: json(["session_id": 42437, "chars": "y\n"])),
            F.block(.toolOut, id: "t2", text: "", toolName: "write_stdin"),
            F.block(.toolCall, id: "t3", toolName: "wait", toolInput: json(["cell_id": "41"])),
            F.block(.toolOut, id: "t3", text: "", toolName: "wait"),
            F.block(.toolCall, id: "t4", toolName: "exec", toolInput: "await tools.write_stdin({session_id: 42437, chars: \"\"})"),
            codeModeOutput(id: "t4", [scriptHeader]),
        ], source: .codex)
        XCTAssertEqual(s.invocation(at: 1).actions[0].verbKey, "tool.verb.polled")
        XCTAssertEqual(s.invocation(at: 1).actions[0].category, .shell)
        XCTAssertEqual(s.invocation(at: 3).actions[0].verbKey, "tool.verb.sentInput")
        XCTAssertEqual(s.invocation(at: 3).actions[0].inputFields, [ToolField(key: "chars", value: .string("y\n"))])
        XCTAssertEqual(s.invocation(at: 5).actions[0].verbKey, "tool.verb.polled")
        XCTAssertEqual(s.invocation(at: 7).actions[0].verbKey, "tool.verb.polled")
        XCTAssertEqual(s.summary(at: 1).actions.map(\.verbKey), ["tool.verb.polled"])
    }

    func testPollObjectResolvesOriginatingCommand() {
        let running = "Chunk ID: ab12\nWall time: 10.0 seconds\nProcess running with session ID 42437\n"
            + "Original token count: 0\nOutput:\n"
        let s = session([
            F.block(.user, text: "start the dev server"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "npm run dev"])),            // 1
            F.block(.toolOut, id: "t1", text: running, toolName: "exec_command"),                                    // 2
            F.block(.toolCall, id: "t2", toolName: "write_stdin", toolInput: json(["session_id": 42437, "chars": ""])), // 3
            F.block(.toolOut, id: "t2", text: running, toolName: "write_stdin"),                                     // 4
            F.block(.toolCall, id: "t3", toolName: "write_stdin", toolInput: json(["session_id": 999, "chars": ""])),   // 5
            F.block(.toolOut, id: "t3", text: "", toolName: "write_stdin"),                                          // 6
        ], source: .codex)
        let poll = s.invocation(at: 3).actions[0]
        XCTAssertEqual(poll.object, "npm run dev")
        XCTAssertEqual(poll.objectDetail, "session 42437")
        XCTAssertFalse(poll.objectIsAgentLabel)
        XCTAssertEqual(poll.plainText, "Polled npm run dev\n[10s]", "the poll's own output has a 10 s wall time and no body")
        XCTAssertEqual(s.summary(at: 3).actions, [
            ToolRowAction(category: .shell, verbKey: "tool.verb.polled", object: "npm run dev",
                          objectIsAgentLabel: false, objectDetail: "session 42437",
                          status: .pending, chips: ["no result yet"]),
        ])
        let unresolved = s.invocation(at: 5).actions[0]
        XCTAssertEqual(unresolved.object, "session 999")
        XCTAssertNil(unresolved.objectDetail)

        // A code-mode owner: the poll resolves to the command of the chunk that holds the session id.
        let owner = """
        await tools.exec_command({cmd: "make build"});
        await tools.exec_command({cmd: "npm run dev"});
        """
        let codeMode = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: owner),                                         // 1
            codeModeOutput(id: "t1", [scriptHeader, chunk("a", exit: 0, output: "built"),
                                      chunk("b", exit: nil, output: "ready", session: 777)]),                       // 2
            F.block(.toolCall, id: "t2", toolName: "exec", toolInput: "await tools.write_stdin({session_id: 777, chars: \"\"})"), // 3
            codeModeOutput(id: "t2", [scriptHeader]),                                                               // 4
            F.block(.toolCall, id: "t3", toolName: "write_stdin", toolInput: json(["session_id": 777, "chars": ""])),   // 5
            F.block(.toolOut, id: "t3", text: "", toolName: "write_stdin"),                                          // 6
            F.block(.toolCall, id: "t4", toolName: "exec", toolInput: "await tools.exec_command({cmd: \"sleep 100\"})"), // 7
            F.block(.toolOut, id: "t4", text: "Script running with cell ID 41\nWall time 10.0 seconds\nOutput:\n", toolName: "exec"), // 8
            F.block(.toolCall, id: "t5", toolName: "wait", toolInput: json(["cell_id": "41"])),                       // 9
            F.block(.toolOut, id: "t5", text: "", toolName: "wait"),                                                 // 10
        ], source: .codex)
        XCTAssertEqual(codeMode.index.processOwnerBySessionID["777"], 1)
        XCTAssertEqual(codeMode.invocation(at: 3).actions[0].object, "npm run dev")
        XCTAssertEqual(codeMode.invocation(at: 3).actions[0].objectDetail, "session 777")
        XCTAssertEqual(codeMode.summary(at: 3).actions.first?.object, "npm run dev")
        XCTAssertEqual(codeMode.invocation(at: 5).actions[0].object, "npm run dev")
        XCTAssertEqual(codeMode.invocation(at: 9).actions[0].object, "sleep 100")
        XCTAssertEqual(codeMode.invocation(at: 9).actions[0].objectDetail, "cell 41")

        // Chunk items stored as JSON-encoded strings resolve the same way.
        func encoded(_ item: String) -> String {
            "\"" + item.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let encodedOwner = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: owner),                                         // 1
            codeModeOutput(id: "t1", [scriptHeader, encoded(chunk("a", exit: 0, output: "built")),
                                      encoded(chunk("b", exit: nil, output: "ready", session: 888))]),             // 2
            F.block(.toolCall, id: "t2", toolName: "write_stdin", toolInput: json(["session_id": 888, "chars": ""])),   // 3
            F.block(.toolOut, id: "t2", text: "", toolName: "write_stdin"),                                          // 4
        ], source: .codex)
        XCTAssertEqual(encodedOwner.index.processOwnerBySessionID["888"], 1)
        XCTAssertEqual(encodedOwner.invocation(at: 3).actions[0].object, "npm run dev")
    }

    // MARK: - Ciphertext

    func testCiphertextNeverAppears() {
        let cipher = "gAAAAAB" + String(repeating: "Qx9_-", count: 30)
        var call = F.block(.toolCall, id: "t1", toolName: "send_message",
                           toolInput: json(["target": "/root", "message": cipher, "nested": ["items": [cipher]]]))
        call.toolNamespace = "collaboration"
        var output = F.block(.toolOut, id: "t1", text: json(["delivered": true, "echo": cipher]), toolName: "send_message")
        output.toolNamespace = "collaboration"
        let s = session([F.block(.user, text: "go"), call, output], source: .codex)
        let invocation = s.invocation(at: 1)
        let action = invocation.actions[0]
        XCTAssertEqual(action.category, .subagent)
        XCTAssertEqual(invocation.displayToolName, "collaboration › send_message")
        XCTAssertFalse(action.plainText.contains("gAAAAA"))
        XCTAssertFalse(action.object.contains("gAAAAA"))
        XCTAssertFalse(String(describing: action.inputFields).contains("gAAAAA"))
        XCTAssertFalse(action.output?.text.contains("gAAAAA") ?? true)
        XCTAssertTrue(action.inputFields.contains(ToolField(key: "message", value: .string("message encrypted in the log (157 chars)"))))
        XCTAssertTrue(action.output?.text.contains("message encrypted in the log (157 chars)") ?? false)
        XCTAssertFalse(s.summary(at: 1).actions.contains { $0.object.contains("gAAAAA") })
    }

    // MARK: - Plain text

    func testPlainTextForm() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash", toolInput: json(["command": "make"])),
            F.block(.toolOut, id: "t1", text: "Exit code 2\nboom", toolName: "Bash"),
            F.block(.toolCall, id: "t2", toolName: "Read", toolInput: json(["file_path": "/a/Foo.swift"])),
            F.block(.toolOut, id: "t2", text: "let x = 1", toolName: "Read"),
        ], source: .claude)
        let invocation = s.invocation(at: 1, duration: 1.2)
        XCTAssertEqual(invocation.durationSeconds, 1.2)
        XCTAssertEqual(invocation.actions[0].status, .failed(exitCode: 2))
        XCTAssertEqual(invocation.actions[0].plainText, "$ make\n[exit 2 · 1.2s]\nboom")
        // Non-shell actions list their input fields; durations use TranscriptTurnTiming.formatDuration.
        XCTAssertEqual(s.invocation(at: 3).actions[0].plainText, "Read Foo.swift\nfile_path: /a/Foo.swift\nlet x = 1")
        XCTAssertEqual(s.invocation(at: 3, duration: 48).actions[0].plainText,
                       "Read Foo.swift\nfile_path: /a/Foo.swift\n[48s]\nlet x = 1")
        XCTAssertEqual(s.invocation(at: 3, duration: 65).actions[0].plainText,
                       "Read Foo.swift\nfile_path: /a/Foo.swift\n[1m 5s]\nlet x = 1")
    }

    func testGenericPlainTextListsInputs() {
        let patch = "*** Begin Patch\n*** Update File: A.swift\n@@\n-x\n+y\n*** End Patch"
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "mcp__github__create_pull_request",
                    toolInput: json(["owner": "a", "draft": true, "options": ["x": 1], "body": "line 1\nline 2"])),  // 1
            F.block(.toolOut, id: "t1", text: "ok", toolName: "mcp__github__create_pull_request"),
            F.block(.toolCall, id: "t2", toolName: "write_stdin", toolInput: json(["session_id": 7, "chars": "y\n"])), // 3
            F.block(.toolOut, id: "t2", text: "", toolName: "write_stdin"),
        ], source: .claude)
        let mcp = s.invocation(at: 1).actions[0].plainText
        XCTAssertTrue(mcp.hasPrefix("github › create_pull_request line 1\nbody: "), "verb, object, then fields in order: \(mcp)")
        XCTAssertTrue(mcp.contains("\nowner: a\n"), mcp)
        XCTAssertTrue(mcp.contains("\ndraft: true\n"), mcp)
        XCTAssertTrue(mcp.contains(#"options: {"x":1}"#), mcp)
        XCTAssertTrue(mcp.contains("\nbody: line 1\nline 2\n"), "strings are unescaped, newlines kept")
        XCTAssertTrue(mcp.hasSuffix("\nok"))
        XCTAssertEqual(s.invocation(at: 3).actions[0].plainText, "Sent input session 7\nchars: y\n", "the typed input")

        let codex = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "apply_patch", toolInput: patch),
            F.block(.toolOut, id: "t1", text: "Done", toolName: "apply_patch"),
        ], source: .codex)
        XCTAssertEqual(codex.invocation(at: 1).actions[0].plainText, "Edited A.swift\ninput: \(patch)\nDone",
                       "the patch is in the plain text")
    }

    func testOutputPipelineLiftsBeforeShapeDetection() {
        // A trailing <system-reminder> must not defeat line-number stripping (Task 7 ruling).
        let read = "     1→let a = 1\n     2→let b = 2\n\n<system-reminder>\nBe careful.\n</system-reminder>\n"
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Read", toolInput: json(["file_path": "/a/b.swift"])),
            F.block(.toolOut, id: "t1", text: read, toolName: "Read"),
        ], source: .claude)
        let action = s.invocation(at: 1).actions[0]
        XCTAssertEqual(action.output?.text, "let a = 1\nlet b = 2")
        XCTAssertEqual(action.output?.shape, .lineNumbered(gutter: [1, 2]))
        XCTAssertEqual(action.hiddenNotes, ["Be careful."])
        XCTAssertEqual(action.plainText, "Read b.swift\nfile_path: /a/b.swift\nlet a = 1\nlet b = 2", "no gutter in plain text")
    }

    func testOrphanOutputIsOutputRow() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolOut, id: "t9", text: "hello", toolName: "shell"),
        ], source: .codex)
        let invocation = s.invocation(at: 1)
        XCTAssertNil(invocation.ref.callBlockIndex)
        XCTAssertEqual(invocation.actions.count, 1)
        XCTAssertEqual(invocation.actions[0].verbKey, "tool.verb.output")
        XCTAssertEqual(invocation.actions[0].object, "shell")
        XCTAssertEqual(invocation.actions[0].output?.text, "hello")
        XCTAssertEqual(invocation.actions[0].plainText, "Output shell\nhello")
    }

    // MARK: - Generic tools

    func testGenericToolsKeepTheirVerbAndFields() {
        let patch = "*** Begin Patch\n*** Update File: Sources/A.swift\n@@\n-x\n+y\n*** Add File: Sources/B.swift\n+z\n*** End Patch"
        let claude = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Read", toolInput: json(["file_path": "/a/b/Foo.swift", "offset": 10])),       // 1
            F.block(.toolOut, id: "t1", text: "x", toolName: "Read"),
            F.block(.toolCall, id: "t2", toolName: "Grep", toolInput: json(["pattern": "TODO", "path": "src", "-n": true])),      // 3
            F.block(.toolOut, id: "t2", text: "x", toolName: "Grep"),
            F.block(.toolCall, id: "t3", toolName: "mcp__github__create_pull_request",
                    toolInput: json(["title": "Fix", "owner": "a", "draft": true])),                                          // 5
            F.block(.toolOut, id: "t3", text: "x", toolName: "mcp__github__create_pull_request"),
            F.block(.toolCall, id: "t4", toolName: "mcp__x__y",
                    toolInput: json(["zeta": 1, "pattern": "p", "alpha": "x", "command": "c", "description": "d"])),          // 7
            F.block(.toolOut, id: "t4", text: "x", toolName: "mcp__x__y"),
            F.block(.toolCall, id: "t5", toolName: "WebSearch", toolInput: json(["query": "swift macros"])),                   // 9
            F.block(.toolOut, id: "t5", text: "x", toolName: "WebSearch"),
            F.block(.toolCall, id: "t6", toolName: "WebFetch", toolInput: json(["url": "https://x.dev", "prompt": "p"])),     // 11
            F.block(.toolOut, id: "t6", text: "x", toolName: "WebFetch"),
        ], source: .claude)

        let read = claude.invocation(at: 1).actions[0]
        XCTAssertEqual(read.category, .read)
        XCTAssertEqual(read.verbKey, "tool.verb.read")
        XCTAssertEqual(read.object, "Foo.swift")
        XCTAssertNil(read.command)
        XCTAssertEqual(read.inputFields, [ToolField(key: "file_path", value: .string("/a/b/Foo.swift")),
                                          ToolField(key: "offset", value: .number(10))])

        let grep = claude.invocation(at: 3).actions[0]
        XCTAssertEqual(grep.category, .search)
        XCTAssertEqual(grep.verbKey, "tool.verb.searched")
        XCTAssertEqual(grep.object, "TODO")
        XCTAssertEqual(grep.inputFields.map(\.key), ["pattern", "path", "-n"])

        let mcp = claude.invocation(at: 5)
        XCTAssertEqual(mcp.displayToolName, "github › create_pull_request")
        XCTAssertEqual(mcp.actions[0].category, .structured)
        XCTAssertEqual(mcp.actions[0].verbKey, "github › create_pull_request")
        XCTAssertEqual(mcp.actions[0].object, "Fix")
        XCTAssertEqual(mcp.actions[0].inputFields.map(\.key), ["draft", "owner", "title"])

        XCTAssertEqual(claude.invocation(at: 7).actions[0].inputFields.map(\.key),
                       ["command", "pattern", "description", "alpha", "zeta"])

        XCTAssertEqual(claude.invocation(at: 9).actions[0].verbKey, "tool.verb.searchedWeb")
        XCTAssertEqual(claude.invocation(at: 9).actions[0].object, "swift macros")
        XCTAssertEqual(claude.invocation(at: 11).actions[0].verbKey, "tool.verb.fetched")
        XCTAssertEqual(claude.invocation(at: 11).actions[0].object, "https://x.dev")

        let codex = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "apply_patch", toolInput: patch),
            F.block(.toolOut, id: "t1", text: "Success.", toolName: "apply_patch"),
        ], source: .codex)
        let edit = codex.invocation(at: 1).actions[0]
        XCTAssertEqual(edit.category, .edit)
        XCTAssertEqual(edit.verbKey, "tool.verb.edited")
        XCTAssertEqual(edit.object, "A.swift")
        XCTAssertEqual(edit.objectDetail, "+1")
        XCTAssertEqual(edit.inputFields, [ToolField(key: "input", value: .string(patch))])
    }

    // MARK: - Row summary

    func testRowSummaryChipsComeFromStatus() {
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "make"])),                  // 1
            F.block(.toolOut, id: "t1", text: "Process exited with code 65\nOutput:\nboom", toolName: "exec_command"),
            F.block(.toolCall, id: "t2", toolName: "exec_command", toolInput: json(["cmd": "true"])),                  // 3
            F.block(.toolOut, id: "t2", text: "Process exited with code 0\nOutput:\n", toolName: "exec_command"),
            F.block(.toolCall, id: "t3", toolName: "exec_command", toolInput: json(["cmd": "x"])),                     // 5
            F.block(.toolOut, id: "t3", text: "bad", toolName: "exec_command", isError: true),
            F.block(.toolCall, id: "t4", toolName: "exec_command", toolInput: json(["cmd": "rm -rf /"])),              // 7
            F.block(.toolOut, id: "t4", text: "no", toolName: "exec_command", disposition: .rejected),
            F.block(.toolCall, id: "t5", toolName: "exec_command", toolInput: json(["cmd": "never answered"])),        // 9
            F.block(.user, text: "next"),
            F.block(.toolCall, id: "t6", toolName: "exec_command", toolInput: json(["cmd": "still running"])),         // 11
        ], source: .codex)
        XCTAssertEqual(s.summary(at: 1).chips, ["exit 65"])
        XCTAssertEqual(s.summary(at: 3).chips, [])
        XCTAssertEqual(s.summary(at: 5).chips, ["error"])
        XCTAssertEqual(s.summary(at: 7).chips, ["rejected by you"])
        XCTAssertEqual(s.summary(at: 9).chips, ["no result recorded"])
        XCTAssertEqual(s.summary(at: 11).chips, ["no result yet"])
        XCTAssertEqual(s.invocation(at: 9).actions[0].output, nil)

        // Exit 1 with no output is "no matches" only for a grep-family command (spec §6.3).
        let empty = "Process exited with code 1\nOutput:\n"
        let grep = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "rg -n nothing src"])),     // 1
            F.block(.toolOut, id: "t1", text: empty, toolName: "exec_command"),
            F.block(.toolCall, id: "t2", toolName: "exec_command", toolInput: json(["cmd": "test -f missing.txt"])),   // 3
            F.block(.toolOut, id: "t2", text: empty, toolName: "exec_command"),
            F.block(.toolCall, id: "t3", toolName: "exec_command",
                    toolInput: json(["cmd": "bash -lc 'cd /x && grep -r nothing .'"])),                               // 5
            F.block(.toolOut, id: "t3", text: empty, toolName: "exec_command"),
        ], source: .codex)
        XCTAssertEqual(grep.invocation(at: 1).actions[0].status, .success)
        XCTAssertEqual(grep.summary(at: 1).chips, [])
        XCTAssertEqual(grep.invocation(at: 3).actions[0].status, .failed(exitCode: 1))
        XCTAssertEqual(grep.summary(at: 3).actions.first?.chips, ["exit 1"])
        XCTAssertEqual(grep.invocation(at: 5).actions[0].status, .success, "a wrapped grep is still grep-family")
    }

    func testRowSummaryDoesNotDecodeOutput() {
        // ~2 MB of JSON lines: decoding parses every line, so any decode blows the budget.
        let line = #"{"path":"Sources/App/File.swift","line":12,"text":"let value = compute(input)"}"#
        let body = String(repeating: line + "\n", count: (2 * 1024 * 1024) / (line.utf8.count + 1))
        let s = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "rg --json value"])),
            F.block(.toolOut, id: "t1", text: body, toolName: "exec_command"),
        ], source: .codex)
        XCTAssertGreaterThan(body.utf8.count, 2_000_000)
        let ref = s.ref(at: 1)
        _ = ToolInvocationBuilder.rowSummary(ref, blocks: s.blocks, index: s.index, source: .codex)

        let runs = 10
        let start = DispatchTime.now().uptimeNanoseconds
        var summary = ToolRowSummary(actions: [], chips: [])
        for _ in 0..<runs {
            summary = ToolInvocationBuilder.rowSummary(ref, blocks: s.blocks, index: s.index, source: .codex)
        }
        let perCallMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(runs)
        XCTAssertEqual(summary.actions.first?.object, "rg --json value")
        XCTAssertLessThan(perCallMs, 5, "rowSummary must not touch the output body")

        // Code mode reads chunk metadata for per-command status, never the 2 MB chunk body.
        let codeMode = session([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: "await tools.exec_command({cmd: \"rg --json value\"})"),
            codeModeOutput(id: "t1", [scriptHeader, chunk("a", exit: 2, output: body)]),
        ], source: .codex)
        let codeRef = codeMode.ref(at: 1)
        _ = ToolInvocationBuilder.rowSummary(codeRef, blocks: codeMode.blocks, index: codeMode.index, source: .codex)
        let codeStart = DispatchTime.now().uptimeNanoseconds
        var codeSummary = ToolRowSummary(actions: [], chips: [])
        for _ in 0..<runs {
            codeSummary = ToolInvocationBuilder.rowSummary(codeRef, blocks: codeMode.blocks, index: codeMode.index, source: .codex)
        }
        let codePerCallMs = Double(DispatchTime.now().uptimeNanoseconds - codeStart) / 1_000_000 / Double(runs)
        XCTAssertEqual(codeSummary.actions.first?.status, .failed(exitCode: 2))
        XCTAssertLessThan(codePerCallMs, 5, "the chunk scan reads metadata only")

        // Positive control: the full build does decode the body.
        let buildStart = DispatchTime.now().uptimeNanoseconds
        _ = ToolInvocationBuilder.build(ref, blocks: s.blocks, index: s.index, source: .codex, duration: nil)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000
        print("TASK9-PERF rowSummary=\(perCallMs)ms codeModeRowSummary=\(codePerCallMs)ms build=\(buildMs)ms")
    }
}
