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
    func testMergeConsecutiveToolRuns() {
        func tool(_ i: Int) -> BlockRowModel {
            var b = SessionTranscriptBuilder.LogicalBlock(kind: .toolCall, text: "t\(i)", timestamp: nil,
                messageID: nil, toolName: "shell", isDelta: false, toolInput: nil,
                isErrorOutput: false, eventID: "e\(i)", rawJSON: "")
            b.globalBlockIndex = i
            return BlockRowModel(id: i, content: .message(b))
        }
        func user(_ i: Int) -> BlockRowModel {
            var b = SessionTranscriptBuilder.LogicalBlock(kind: .user, text: "u", timestamp: nil,
                messageID: nil, toolName: nil, isDelta: false, toolInput: nil,
                isErrorOutput: false, eventID: "e\(i)", rawJSON: "")
            b.globalBlockIndex = i
            return BlockRowModel(id: i, content: .message(b))
        }
        let merged = TranscriptToolSummary.mergeToolRuns([user(0), tool(1), tool(2), tool(3), user(4)])
        XCTAssertEqual(merged.count, 3)
        guard case .toolGroup(let group) = merged[1].content else { return XCTFail("expected toolGroup") }
        XCTAssertEqual(group.count, 3)
        XCTAssertEqual(merged[1].id, 1)   // keyed by first block's globalBlockIndex
    }

    func testLoneToolBlockStaysMessage() {
        var b = SessionTranscriptBuilder.LogicalBlock(kind: .toolCall, text: "t", timestamp: nil,
            messageID: nil, toolName: "shell", isDelta: false, toolInput: nil,
            isErrorOutput: false, eventID: "e0", rawJSON: "")
        b.globalBlockIndex = 0
        let row = BlockRowModel(id: 0, content: .message(b))
        let merged = TranscriptToolSummary.mergeToolRuns([row])
        XCTAssertEqual(merged.count, 1)
        guard case .message = merged[0].content else { return XCTFail("expected lone tool block to stay .message") }
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

    // MARK: expandedToolBodyOffset (Task 16 fold check)

    private func toolBlock(_ text: String, toolName: String = "shell", index: Int) -> SessionTranscriptBuilder.LogicalBlock {
        var b = SessionTranscriptBuilder.LogicalBlock(kind: .toolCall, text: text, timestamp: nil,
            messageID: nil, toolName: toolName, isDelta: false, toolInput: nil,
            isErrorOutput: false, eventID: "e\(index)", rawJSON: "")
        b.globalBlockIndex = index
        return b
    }

    func testExpandedToolBodyOffsetLoneBlockIsZero() {
        // A lone block's expandedToolBodyText is block.text verbatim (no
        // annotation) — its text always starts at offset 0.
        let blocks = [toolBlock("hello", index: 0)]
        XCTAssertEqual(BlockCardCellView.expandedToolBodyOffset(blocks: blocks, ownerIndex: 0), 0)
    }

    func testExpandedToolBodyOffsetMatchesGroupConstruction() {
        // The offset of each block's OWN text inside expandedToolBodyText must
        // exactly locate that substring — verifies the sibling helper's
        // arithmetic mirrors expandedToolBodyText's real construction rather
        // than drifting from it.
        let blocks = [toolBlock("first body", index: 0),
                      toolBlock("second body", index: 1),
                      toolBlock("third body", index: 2)]
        let full = BlockCardCellView.expandedToolBodyText(blocks: blocks) as NSString
        for (i, block) in blocks.enumerated() {
            let offset = BlockCardCellView.expandedToolBodyOffset(blocks: blocks, ownerIndex: i)
            let expectedRange = full.range(of: block.text)
            XCTAssertEqual(offset, expectedRange.location, "block \(i) offset should locate its own text")
        }
    }

    func testExpandedToolBodyOffsetOutOfRangeIsZero() {
        let blocks = [toolBlock("a", index: 0), toolBlock("b", index: 1)]
        XCTAssertEqual(BlockCardCellView.expandedToolBodyOffset(blocks: blocks, ownerIndex: 5), 0)
    }
}
