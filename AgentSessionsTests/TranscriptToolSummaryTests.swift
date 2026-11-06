import XCTest
@testable import AgentSessions

final class TranscriptToolSummaryTests: XCTestCase {
    func testShellCommandSummary() {
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["bash","-lc","ls -la /tmp"]}"#)
        XCTAssertEqual(s, "ls -la /tmp")
    }
    func testFilePathSummary() {
        let s = TranscriptToolSummary.summary(
            toolName: "Read",
            toolInput: #"{"file_path":"/Users/x/project/Sources/App/main.swift"}"#)
        XCTAssertEqual(s, "main.swift")
    }
    func testDescriptionFallback() {
        let s = TranscriptToolSummary.summary(
            toolName: "Bash",
            toolInput: #"{"command":"git status","description":"Show working tree status"}"#)
        XCTAssertEqual(s, "git status")   // command beats description
    }
    func testUnparseableInputFallsBackToToolName() {
        // toolName outranks the raw-line fallback: unparseable junk input
        // must not beat a real tool name (controller resolution).
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: "MyTool", toolInput: "not json"), "MyTool")
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: nil, toolInput: nil), "Tool call")
    }
    func testNamelessToolFallsBackToRawFirstLine() {
        // The raw first-non-empty-line rung is reachable only when toolName
        // is nil/empty — it still serves nameless tools.
        XCTAssertEqual(
            TranscriptToolSummary.summary(toolName: nil, toolInput: "raw command text"),
            "raw command text")
        XCTAssertEqual(
            TranscriptToolSummary.summary(toolName: "", toolInput: "\n  raw command text\nsecond line"),
            "raw command text")
    }
    // MARK: - Group count, namespace and web search label

    private func countBlock(_ kind: SessionTranscriptBuilder.LogicalBlock.Kind, _ id: String) -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(kind: kind, text: id, timestamp: nil,
            messageID: nil, toolName: "shell", isDelta: false, toolInput: nil,
            isErrorOutput: false, eventID: id, rawJSON: "")
    }

    func testGroupHeaderCountsCallsNotBlocks() {
        let blocks = [countBlock(.toolCall, "a"), countBlock(.toolOut, "a"), countBlock(.toolCall, "b"), countBlock(.toolOut, "b")]
        XCTAssertEqual(TranscriptToolSummary.callCount(in: blocks), 2)
    }

    func testOrphanOutputGroupCountsOne() {
        XCTAssertEqual(TranscriptToolSummary.callCount(in: [countBlock(.toolOut, "x"), countBlock(.toolOut, "y")]), 1)
    }

    func testNamespaceDisplay() {
        XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "js", namespace: "mcp__node_repl__"), "node_repl › js")
        XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "send_message", namespace: "collaboration"), "collaboration › send_message")
        XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "x", namespace: "a::b"), "a › b › x")
        XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "js", namespace: nil), "js")
        XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "js", namespace: ""), "js")
        XCTAssertNil(TranscriptToolSummary.displayToolName(name: nil, namespace: "ns"))
    }

    // MARK: - Card header decision

    private func hdrBlock(_ kind: SessionTranscriptBuilder.LogicalBlock.Kind, _ id: String, name: String? = "shell",
                          input: String? = nil, ns: String? = nil) -> SessionTranscriptBuilder.LogicalBlock {
        var b = SessionTranscriptBuilder.LogicalBlock(kind: kind, text: id, timestamp: nil,
            messageID: nil, toolName: name, isDelta: false, toolInput: input,
            isErrorOutput: false, eventID: id, rawJSON: "")
        b.toolNamespace = ns
        return b
    }

    func testCallPlusOutputIsSingleHeader() {
        let h = TranscriptToolSummary.cardHeader(for: [
            hdrBlock(.toolCall, "a", input: #"{"command":"ls -la"}"#), hdrBlock(.toolOut, "a")])
        XCTAssertFalse(h.isGroup)
        XCTAssertEqual(h.toolName, "shell")
        XCTAssertEqual(h.summary, "ls -la")
    }

    func testNamespacedCallPlusOutputShowsServerAndTool() {
        let h = TranscriptToolSummary.cardHeader(for: [
            hdrBlock(.toolCall, "a", name: "js", input: #"{"code":"1"}"#, ns: "mcp__node_repl__"),
            hdrBlock(.toolOut, "a", name: "js")])
        XCTAssertFalse(h.isGroup)
        XCTAssertEqual(h.toolName, "node_repl › js")
    }

    func testTwoCallsWithOutputsAreGroupTitledByCallCount() {
        let h = TranscriptToolSummary.cardHeader(for: [
            hdrBlock(.toolCall, "a"), hdrBlock(.toolOut, "a"), hdrBlock(.toolCall, "b"), hdrBlock(.toolOut, "b")])
        XCTAssertTrue(h.isGroup)
        XCTAssertNil(h.toolName)
        XCTAssertEqual(h.summary, "2 tool calls")
    }

    func testOrphanOutputsAreSingleHeaderNotOneToolCalls() {
        let h = TranscriptToolSummary.cardHeader(for: [
            hdrBlock(.toolOut, "x", ns: "mcp__node_repl__"), hdrBlock(.toolOut, "y")])
        XCTAssertFalse(h.isGroup)
        XCTAssertEqual(h.toolName, "node_repl › shell")
        XCTAssertNotEqual(h.summary, "1 tool calls")
    }

    func testCoalesceKeepsFirstToolNamespaceOnMerge() {
        SessionTranscriptBuilder._testResetCoalesceCache()
        func out(_ id: String, ns: String) -> SessionEvent {
            var e = SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                                 toolName: "js", toolInput: nil, toolOutput: id,
                                 messageID: "m1", parentID: nil, isDelta: true, rawJSON: "{}")
            e.toolNamespace = ns
            return e
        }
        let session = Session(id: "ns-merge-\(UUID().uuidString)", source: .codex, startTime: nil, endTime: nil,
                              model: "test", filePath: "/tmp/x.jsonl", fileSizeBytes: nil,
                              eventCount: 2, events: [out("o1", ns: "first"), out("o2", ns: "second")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.toolNamespace, "first")
    }

    // The Session view's tool grouping is `TranscriptToolRows.emit` (tool rendering Task 13
    // replaced `mergeToolRuns`): a run of tool blocks is one group, keyed by its first invocation.

    private func emitRows(_ kinds: [SessionTranscriptBuilder.LogicalBlock.Kind]) -> [BlockRowModel] {
        let blocks = kinds.enumerated().map { i, kind -> SessionTranscriptBuilder.LogicalBlock in
            var b = SessionTranscriptBuilder.LogicalBlock(kind: kind, text: kind.isTool ? "t\(i)" : "u", timestamp: nil,
                messageID: nil, toolName: kind.isTool ? "shell" : nil, isDelta: false, toolInput: nil,
                isErrorOutput: false, eventID: "e\(i)", rawJSON: "")
            b.globalBlockIndex = i
            return b
        }
        // No pairing index: each tool block is its own invocation (id = its index).
        return TranscriptToolRows.emit(blocks: blocks[...], index: .empty,
                                       rowSummary: { _ in ToolRowSummary(actions: [], chips: []) },
                                       openGroups: [], openInvocations: [],
                                       activeRoles: Set(TranscriptRoleFilter.allCases), failedInvocationIDs: [])
    }

    func testConsecutiveToolBlocksEmitOneGroupHeader() {
        let rows = emitRows([.user, .toolCall, .toolCall, .toolCall, .user])
        XCTAssertEqual(rows.count, 3)
        guard case .toolGroupHeader(let header) = rows[1].content else { return XCTFail("expected a group header") }
        XCTAssertEqual(header.callCount, 3)
        XCTAssertEqual(header.groupID, 1)   // keyed by the first invocation
        XCTAssertEqual(header.invocationIDs, [1, 2, 3])
        XCTAssertEqual(rows[1].id, TranscriptToolRows.groupHeaderRowID(forGroup: 1))
    }

    func testLoneToolBlockIsSoloInvocationRow() {
        let rows = emitRows([.toolCall])
        XCTAssertEqual(rows.count, 1)
        guard case .toolInvocation(let invocation) = rows[0].content else {
            return XCTFail("expected a lone tool block to be one invocation row")
        }
        XCTAssertEqual(invocation.position, .solo)
        XCTAssertNil(invocation.groupID)
        XCTAssertEqual(rows[0].id, 0)
    }

    func testArrayCommandDropsBashWrapper() {
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["bash","-lc","echo hi && echo bye"]}"#)
        XCTAssertEqual(s, "echo hi && echo bye")
    }

    func testArrayCommandDropsLeadingBashLc() {
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["bash","-lc","npm test"]}"#)
        XCTAssertEqual(s, "npm test")
    }

    func testArrayCommandDropsLeadingShC() {
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["sh","-c","ls -la"]}"#)
        XCTAssertEqual(s, "ls -la")
    }

    func testArrayCommandKeepsNonLeadingWrapperToken() {
        // Regression: -c after a non-wrapper token is a real argument (grep -c),
        // not a shell wrapper, so it must be preserved.
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["grep","-c","TODO","notes.txt"]}"#)
        XCTAssertEqual(s, "grep -c TODO notes.txt")
    }

    func testArrayCommandDropsOnlyLeadingWrapperRun() {
        // Leading `zsh -lc` is dropped; the inner `-c` between args is kept.
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["zsh","-lc","x","-c","y"]}"#)
        XCTAssertEqual(s, "x -c y")
    }

    func testPatternFallback() {
        // `pattern` only wins when there is no `file_path`/`path` present —
        // path/file_path is higher priority per the binding order.
        let s = TranscriptToolSummary.summary(
            toolName: "Grep",
            toolInput: #"{"pattern":"TODO"}"#)
        XCTAssertEqual(s, "TODO")
    }

    func testQueryRung() {
        let s = TranscriptToolSummary.summary(
            toolName: "WebSearch",
            toolInput: #"{"query":"swift nstableview variable row height"}"#)
        XCTAssertEqual(s, "swift nstableview variable row height")
    }

    func testURLRung() {
        let s = TranscriptToolSummary.summary(
            toolName: "WebFetch",
            toolInput: #"{"url":"https://example.com/docs/page"}"#)
        XCTAssertEqual(s, "https://example.com/docs/page")
    }

    func testDescriptionBeatsFilePath() {
        // description is a higher rung than file_path/path in the binding order.
        let s = TranscriptToolSummary.summary(
            toolName: "Read",
            toolInput: #"{"description":"Read app config","file_path":"/etc/app/config.json"}"#)
        XCTAssertEqual(s, "Read app config")
    }

    func testMalformedJSONWithToolNameReturnsToolName() {
        // Controller resolution (adjudicating the brief's prose/test
        // contradiction): toolName sits ABOVE the raw-line rung, so malformed
        // JSON input never beats a real tool name.
        let s = TranscriptToolSummary.summary(
            toolName: "Edit",
            toolInput: #"{"file_path": /broken/json,"#)
        XCTAssertEqual(s, "Edit")
    }

    func testRawLineRungCapsAt80Chars() {
        // Raw-line rung (reachable only with nil/empty toolName) trims and
        // caps at 80 characters.
        let longLine = String(repeating: "x", count: 100)
        let s = TranscriptToolSummary.summary(toolName: nil, toolInput: "  " + longLine)
        XCTAssertEqual(s.count, 80)
        XCTAssertEqual(s, String(repeating: "x", count: 80))
    }

    // MARK: - Codex cmd / exec script summaries and call labels (transcript tool rendering)

    func testCodexExecCommandUsesCmd() {
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: "exec_command", toolInput: #"{"cmd":"git status","workdir":"/x"}"#), "git status")
    }

    func testCodexExecScriptUsesFirstCommand() {
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: "exec", toolInput: #"text(await tools.exec_command({cmd:"pwd; rg x"}));"#), "pwd; rg x")
    }

    private func callLabel(toolName: String, input: String) -> String {
        SessionTranscriptBuilder._testResetCoalesceCache()
        let event = TranscriptTestFixtures.toolCallEvent("e1", toolName: toolName, input: input)
        let session = Session(id: "label-\(UUID().uuidString)", source: .codex, startTime: nil, endTime: nil,
                              model: "test", filePath: "/tmp/x.jsonl", fileSizeBytes: nil,
                              eventCount: 1, events: [event])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        return blocks.map(\.text).joined(separator: "\n")
    }

    func testCallLabelShowsPrimaryArgumentFirst() {
        // description must not hide the command
        XCTAssertEqual(callLabel(toolName: "Bash", input: #"{"description":"List","command":"ls -la"}"#), "Bash ls -la")
    }

    func testGrepLabelShowsPatternNotPath() {
        XCTAssertEqual(callLabel(toolName: "Grep", input: #"{"pattern":"foo","path":"/repo"}"#), "Grep foo")
    }

    func testCallLabelForReadIsPath() {
        XCTAssertEqual(callLabel(toolName: "Read", input: #"{"file_path":"/tmp/a.txt"}"#), "Read /tmp/a.txt")
    }

    func testCallLabelCollapsesNewlinesAndCutsAt120() {
        XCTAssertEqual(callLabel(toolName: "Bash", input: #"{"command":"echo a\necho b"}"#), "Bash echo a echo b")
        let long = String(repeating: "x", count: 300)
        let cut = callLabel(toolName: "Bash", input: "{\"command\":\"\(long)\"}")
        XCTAssertEqual(cut.count, 121)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertTrue(cut.hasPrefix("Bash xxx"))
    }

    func testCallLabelWithoutPrimaryArgumentKeepsCompactJSON() {
        XCTAssertEqual(callLabel(toolName: "Foo", input: #"{"b": 2, "a": "/x"}"#), #"Foo {"a":"/x","b":2}"#)
    }

    func testCallLabelForExecScriptIsFirstCmd() {
        XCTAssertEqual(callLabel(toolName: "exec", input: #"text(await tools.exec_command({cmd:"pwd; rg x"}));"#), "exec pwd; rg x")
    }

    // MARK: - Large inputs (bounded label parsing)

    private func seconds(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return CFAbsoluteTimeGetCurrent() - start
    }

    func testLargeJSONInputLabelIsBoundedAndCorrect() {
        let command = "echo " + String(repeating: "abcdefghij\\n", count: 200_000)   // ~2.4 MB, escaped newlines
        let input = #"{"command":""# + command + #"","description":"d","pad":""# + String(repeating: "x", count: 100) + #""}"#
        XCTAssertGreaterThan(input.utf8.count, 2_000_000)
        let expected = ("echo " + String(repeating: "abcdefghij\n", count: 20)).prefix(120)
        var label: String?
        let elapsed = seconds { label = TranscriptToolSummary.callLabelArgument(toolName: "Bash", toolInput: input) }
        XCTAssertLessThan(elapsed, 0.02)
        XCTAssertEqual(label.map { String($0.prefix(120)) }, String(expected))
        var summary = ""
        XCTAssertLessThan(seconds { summary = TranscriptToolSummary.summary(toolName: "Bash", toolInput: input) }, 0.02)
        XCTAssertEqual(String(summary.prefix(120)), String(expected))
        // Through the builder: the label is cut to 120 characters plus an ellipsis.
        let built = callLabel(toolName: "Bash", input: input)
        let words = Array(repeating: "abcdefghij", count: 30).joined(separator: " ")
        XCTAssertEqual(built, String(("Bash echo " + words).prefix(120)) + "…")
    }

    func testLargeJSONInputSkipsNestedAndFindsLaterKeys() {
        let pad = String(repeating: "z", count: 20_000)
        let input = #"{"blob":{"command":"nested"},"list":[1,"a"],"pad":""# + pad + #"","file_path":"/a/b.txt"}"#
        // The key sits past the 16 KB scan prefix: no label, and no work on the rest.
        XCTAssertNil(TranscriptToolSummary.callLabelArgument(toolName: "Read", toolInput: input))
        let near = #"{"blob":{"command":"nested"},"list":[1,"a"],"file_path":"/a/b.txt","pad":""# + pad + #""}"#
        XCTAssertEqual(TranscriptToolSummary.callLabelArgument(toolName: "Read", toolInput: near), "/a/b.txt")
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: "Read", toolInput: near), "b.txt")
    }

    func testLargeJSONInputArrayCommandDropsShellWrapper() {
        let input = #"{"command":["bash","-lc","ls -la"],"pad":""# + String(repeating: "p", count: 20_000) + #""}"#
        XCTAssertEqual(TranscriptToolSummary.callLabelArgument(toolName: "shell", toolInput: input), "ls -la")
    }

    // MARK: - Exec fast path vs the full parser

    private func fullParserCommand(_ script: String) -> String? {
        guard let parsed = CodexExecScript.parse(script, maxCalls: 1),
              let cmd = parsed.calls.first?.arguments["cmd"]?.stringValue, !cmd.isEmpty else { return nil }
        return cmd
    }

    func testExecFastPathMatchesFullParser() {
        let scripts: [(String, Bool)] = [   // (script, fast path decides)
            (#"text(await tools.exec_command({cmd:"pwd; rg x", workdir:"/x"}));"#, true),
            (#"const r = await Promise.all([tools.exec_command({cmd:"ls -la"}), tools.exec_command({cmd:"pwd"})]);"#, true),
            (#"tools.exec_command({cmd:"echo \"hi\" && printf 'a\\n'\tbA\x42"})"#, true),
            (#"tools.exec_command({ workdir: "/w", 'cmd': 'git log --format=\'%h\'', yield_time_ms: 1000 })"#, true),
            (#"tools.exec_command({"cmd": "ls", "max": [1, {a: "}"}], z: f(1, 2)})"#, true),
            ("tools.exec_command({cmd: `echo \\`x\\` line1\\nline2`})", true),
            ("tools.exec_command({cmd: `echo ${name}`})", false),
            ("// plan\n/* tools.fake({cmd:\"no\"}) */ const a = 1; tools.exec_command(\n  {\n    // first\n    cmd: \"make -j4\",\n  })", true),
            ("// plan\nconst a = 1; tools.exec_command(\n  {\n    // first\n    /* b */ cmd: \"make -j4\",\n  })", true),
            (#"x.tools.nope({cmd:"a"}); mytools.nope({cmd:"b"}); tools.exec_command({cmd:"real"})"#, true),
            (#"tools.exec_command({cmd: "a" + b})"#, false),
            (#"tools.exec_command({cmd})"#, false),
            (#"tools.exec_command({...opts, cmd: "after spread"})"#, false),
            (#"tools.exec_command({cmd: "café é 日本"})"#, true),
            (#"tools.exec_command({cmd: "unterminated"#, false),
            (#"no call here"#, false),
            (#"tools.exec_command(args)"#, false),
            // The fast path defers (nil) wherever it could read the script differently from the parser.
            ("—tools.exec_command({cmd:\"first\"}); tools.exec_command({cmd:\"second\"})", false),   // non-ASCII before `tools.`
            ("étools.exec_command({cmd:\"first\"}); tools.exec_command({cmd:\"second\"})", false),
            (#"tools.exec_command({cmd: "first", cmd: "second"})"#, false),                       // the parser keeps the last `cmd`
            (#"tools.exec_command({cmd: "first", workdir: "/w", 'cmd': 'second'})"#, false),
            (#"tools.exec_command({cmd: "first", cmd})"#, false),
            (#"tools.exec_command({cmd: "ls", opts: {cmd: "nested"}})"#, true),
            (#"tools.exec_command({opts: [1, 2}, cmd: "ls"})"#, false),                          // the parser throws on these
            (#"tools.exec_command({opts: {"a" "b"}, cmd: "ls"})"#, false),
            (#"tools.exec_command({env: {A: "1", "B": [2, 'x', `y`]}, n: -1.5, cmd: "ls"})"#, true),
            ("tools.exec_command({ // note\r\n cmd: \"skipped\",\n workdir: \"/w\" })", false),      // CRLF is one Character
            ("tools.exec_command({\r\n  cmd: \"make\"\r\n})", true),
            ("tools.exec_command\u{0B}({cmd: \"first\"}); tools.exec_command({cmd: \"second\"})", false), // VT, FF, NBSP are spaces
            ("tools.exec_command\u{0C}({cmd: \"first\"}); tools.exec_command({cmd: \"second\"})", false),
            ("tools.exec_command\u{A0}({cmd: \"first\"}); tools.exec_command({cmd: \"second\"})", false),
            ("tools.\u{E9}x({cmd: \"first\"}); tools.exec_command({cmd: \"second\"})", false),           // a non-ASCII letter starts a name
            ("tools.exec_command({a: \"x\"\u{301}, cmd: \"ls\"})", false),                             // a mark joins the quote
            ("tools.exec_command({cmd: \"a\\n\u{301}b\"})", false),
            ("tools.exec_command({cmd: \"a\u{600}\"})", false),                                        // a prepended mark joins the quote
            ("tools.exec_command({a: f(\u{1FEF}), cmd: \"ls\"})", false),                             // U+1FEF equals "`"
            ("tools.exec_command({cmd: \"a\\x4\u{FF11}b\"})", false),                                  // a fullwidth hex digit
            ("tools.exec_command({cmd: `a\\u{`, b: `}X`})", true),                                    // a template ends as the parser ends it
        ]
        for (script, decides) in scripts {
            let fast = ExecFirstCommandScan.firstCommand(in: script)
            XCTAssertEqual(decides, fast != nil, script)
            if let fast { XCTAssertEqual(fast, fullParserCommand(script), script) }
            // Label and summary agree with the full parser whether or not the fast path decided.
            let expected = fullParserCommand(script)
            XCTAssertEqual(TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: script), expected, script)
            if let expected { XCTAssertEqual(TranscriptToolSummary.summary(toolName: "exec", toolInput: script), expected, script) }
        }
    }

    func testExecFastPathIsFast() {
        let cmd = "rg -n \"needle\" Sources && " + String(repeating: "echo filler; ", count: 80)
        let script = #"text(await tools.exec_command({cmd:""# + cmd.replacingOccurrences(of: "\"", with: "\\\"")
            + #"",workdir:"/x",yield_time_ms:1000,max_output_tokens:4000}));"#
            + String(repeating: " ", count: max(0, 1500 - cmd.utf8.count))
        let elapsed = seconds {
            for _ in 0..<1000 { _ = TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: script) }
        }
        XCTAssertEqual(TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: script), cmd)
        XCTAssertLessThan(elapsed, 0.2)
    }

    func testLargeExecScriptLabelIsBoundedAndCorrect() {
        let cmd = String(repeating: "q", count: 150)
        let script = #"text(await tools.exec_command({cmd:""# + cmd + #"",workdir:"/x"}));"# + "\n"
            + String(repeating: "// padding line to make the script large\n", count: 60_000)
        XCTAssertGreaterThan(script.utf8.count, 2_000_000)
        var label: String?
        let elapsed = seconds { label = TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: script) }
        XCTAssertLessThan(elapsed, 0.02)
        XCTAssertEqual(label, cmd)
        XCTAssertEqual(callLabel(toolName: "exec", input: script), String(("exec " + cmd).prefix(120)) + "…")
    }

    func testLargeExecScriptKeepsLabelWhenFirstCommandRunsPastThePrefix() {
        let lines = (0..<1_200).map { "line \($0): heredoc text for the long command" }
        let cmd = "cat > /tmp/notes.txt <<'EOF'\n" + lines.joined(separator: "\n") + "\nEOF"
        XCTAssertGreaterThan(cmd.utf8.count, 40_000)
        let oneLine = cmd.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        let expected = String(("exec " + oneLine).prefix(120)) + "…"
        let quoted = #"text(await tools.exec_command({cmd:""# + cmd.replacingOccurrences(of: "\n", with: "\\n")
            + #"",workdir:"/x"}));"#
        let template = "text(await tools.exec_command({cmd:`" + cmd + "`,workdir:\"/x\"}));"
        for script in [quoted, template] {
            var label: String?
            let elapsed = seconds { label = TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: script) }
            XCTAssertLessThan(elapsed, 0.02)
            // The 16 KB prefix cut the literal: the label keeps the part that was read.
            XCTAssertGreaterThan(label?.utf8.count ?? 0, 8_000)
            XCTAssertTrue(cmd.hasPrefix(label ?? "-"))
            let summary = TranscriptToolSummary.summary(toolName: "exec", toolInput: script)
            XCTAssertGreaterThan(summary.utf8.count, 8_000)
            XCTAssertTrue(cmd.hasPrefix(summary))
            XCTAssertEqual(callLabel(toolName: "exec", input: script), expected)
        }
        // A literal that is still open at the end of a script read whole is malformed, not cut: no partial value.
        let unterminated = #"tools.exec_command({cmd:""# + String(repeating: "y", count: 10_000)
        XCTAssertNil(TranscriptToolSummary.callLabelArgument(toolName: "exec", toolInput: unterminated))
    }

    func testLargeInputWithoutPrimaryKeyLabelIsBounded() {
        let items = (0..<60_000).map { "{\"v\": \"value \($0)\", \"k\": \($0)}" }.joined(separator: ",\n  ")
        let input = "{\"items\": [\n  " + items + "\n]}"
        XCTAssertGreaterThan(input.utf8.count, 2_000_000)
        XCTAssertNil(TranscriptToolSummary.callLabelArgument(toolName: "Foo", toolInput: input))
        // Above 8 KB the label is the start of the raw input, whitespace collapsed; no full JSON parse.
        let start = String(input.prefix(400)).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        var label = ""
        let elapsed = seconds { label = callLabel(toolName: "Foo", input: input) }
        XCTAssertLessThan(elapsed, 0.02)
        XCTAssertEqual(label, "Foo " + String(start.prefix(120)) + "…")
    }
}
