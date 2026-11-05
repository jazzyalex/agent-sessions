import XCTest
import AppKit
@testable import AgentSessions

/// Task 10: `ToolTextBudget` — visual-line budgets for tool output, command and heredoc panes.
final class ToolTextBudgetTests: XCTestCase {
    private func lines(_ n: Int, _ make: (Int) -> String = { "line \($0)" }) -> String {
        (0..<n).map(make).joined(separator: "\n")
    }

    func testShortTextUnfolded() {
        let folded = ToolTextBudget.fold(lines(16), columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<16)])
        XCTAssertFalse(folded.hitShowAllCap)
        XCTAssertEqual(ToolTextBudget.fold("", columns: 80, isError: false, state: FoldState()).segments, [])
    }

    func testTrailingNewlineDoesNotAddALine() {
        let folded = ToolTextBudget.fold("a\nb\n", columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<2)])
    }

    func testHeadAndTailFold() {
        let folded = ToolTextBudget.fold(lines(100), columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<12), .fold(hiddenLines: 84), .lines(96..<100)])
    }

    func testErrorShowsTail() {
        let folded = ToolTextBudget.fold(lines(100), columns: 80, isError: true, state: FoldState())
        XCTAssertEqual(folded.segments, [.fold(hiddenLines: 82), .lines(82..<100)])
        let small = ToolTextBudget.fold(lines(18), columns: 80, isError: true, state: FoldState())
        XCTAssertEqual(small.segments, [.lines(0..<18)])
    }

    func testVisualLinesCountWrappedLines() {
        let text = lines(5) { _ in String(repeating: "x", count: 300) }
        let folded = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<3), .fold(hiddenLines: 1), .lines(4..<5)])
    }

    func testTabAdvancesToFourColumnStop() {
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "a\tb"), 5)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "\t"), 4)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "abcd\te"), 9)
    }

    func testVisualWidthWideEmojiAndZeroWidth() {
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "日本"), 4)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "ｆ"), 2)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "😀"), 2)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "e\u{0301}"), 1)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: "a\u{200B}b"), 2)
        XCTAssertEqual(ToolTextBudget.visualWidth(of: ""), 0)
    }

    func testCommandFoldsAfterTwelveVisualLines() {
        let folded = ToolTextBudget.foldCommand(lines(20), columns: 80, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<12), .fold(hiddenLines: 8)])
        XCTAssertEqual(ToolTextBudget.foldCommand(lines(12), columns: 80, state: FoldState()).segments, [.lines(0..<12)])
        var open = FoldState()
        open.commandShowAll = true
        XCTAssertEqual(ToolTextBudget.foldCommand(lines(20), columns: 80, state: open).segments, [.lines(0..<20)])
    }

    func testLongLineCut() {
        let text = String(repeating: "a", count: 10_000)
        let folded = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.longLineCut(line: 0, hiddenChars: 10_000 - 320)])
    }

    func testLongLineCutBetweenRangesAndCountsAsFourLines() {
        var rows = (0..<10).map { "row \($0)" }
        rows[3] = String(repeating: "b", count: 1000)
        let folded = ToolTextBudget.fold(rows.joined(separator: "\n"), columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<3), .longLineCut(line: 3, hiddenChars: 1000 - 320), .lines(4..<10)])
    }

    func testOpenedLongLineIsNotCut() {
        var state = FoldState()
        state.openedLongLines = [0]
        let text = String(repeating: "a", count: 1000)
        XCTAssertEqual(ToolTextBudget.fold(text, columns: 80, isError: false, state: state).segments, [.lines(0..<1)])
    }

    /// Fix round 1: an opened long line keeps its cut size (4) in every budget, so it renders in full
    /// where it was and no fold boundary moves.
    func testOpeningALongLineNeverMovesFoldBoundaries() {
        let long = String(repeating: "a", count: 5000)  // 63 visual lines at 80 columns
        var head = (0..<30).map { "row \($0)" }
        head.insert(long, at: 2)
        let text = head.joined(separator: "\n")
        var open = FoldState()
        open.openedLongLines = [2]

        let closed = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(closed.segments, [.lines(0..<2), .longLineCut(line: 2, hiddenChars: 5000 - 320), .lines(3..<9),
                                         .fold(hiddenLines: 18), .lines(27..<31)])
        let opened = ToolTextBudget.fold(text, columns: 80, isError: false, state: open)
        XCTAssertEqual(opened.segments, [.lines(0..<9), .fold(hiddenLines: 18), .lines(27..<31)],
                       "line 2 is inside the head, and head, fold and tail are unchanged")

        let command = ToolTextBudget.foldCommand(text, columns: 80, state: open)
        XCTAssertEqual(command.segments, [.lines(0..<9), .fold(hiddenLines: 22)])
        XCTAssertEqual(ToolTextBudget.foldCommand(text, columns: 80, state: FoldState()).segments,
                       [.lines(0..<2), .longLineCut(line: 2, hiddenChars: 5000 - 320), .lines(3..<9), .fold(hiddenLines: 22)])

        var tail = (0..<30).map { "row \($0)" }
        tail.insert(long, at: 28)
        let errorText = tail.joined(separator: "\n")
        var openTail = FoldState()
        openTail.openedLongLines = [28]
        XCTAssertEqual(ToolTextBudget.fold(errorText, columns: 80, isError: true, state: FoldState()).segments,
                       [.fold(hiddenLines: 16), .lines(16..<28), .longLineCut(line: 28, hiddenChars: 5000 - 320), .lines(29..<31)])
        XCTAssertEqual(ToolTextBudget.fold(errorText, columns: 80, isError: true, state: openTail).segments,
                       [.fold(hiddenLines: 16), .lines(16..<31)], "error mode: the opened line stays in the tail")
    }

    /// Fix round 1: `commandShowAll` uses the Show-all caps and opens cut lines without a set.
    func testCommandShowAllIsCappedAndOpensCutLines() {
        var state = FoldState()
        state.commandShowAll = true
        let capped = ToolTextBudget.foldCommand(lines(30_000) { _ in "x" }, columns: 80, state: state)
        XCTAssertTrue(capped.hitShowAllCap)
        XCTAssertEqual(capped.segments, [.lines(0..<20_000), .fold(hiddenLines: 10_000)])
        let long = "short\n" + String(repeating: "c", count: 2000)
        XCTAssertEqual(ToolTextBudget.foldCommand(long, columns: 80, state: state).segments, [.lines(0..<2)])
        XCTAssertEqual(ToolTextBudget.foldCommand(long, columns: 80, state: FoldState()).segments,
                       [.lines(0..<1), .longLineCut(line: 1, hiddenChars: 2000 - 320)])
    }

    func testLongWideLineCutKeepsWholeCharacters() {
        // 80 columns x 4 = 320 columns = 160 wide characters kept.
        let text = String(repeating: "日", count: 400)
        let folded = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.longLineCut(line: 0, hiddenChars: 240)])
    }

    func testWideCharactersCountTwoColumns() {
        // 100 CJK characters = 200 columns = 3 visual lines at 80 columns; 6 such lines = 18 > 16.
        let text = lines(6) { _ in String(repeating: "日", count: 100) }
        let folded = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertEqual(folded.segments, [.lines(0..<4), .fold(hiddenLines: 1), .lines(5..<6)])
        let three = lines(5) { _ in String(repeating: "日", count: 100) } // 15 visual lines
        XCTAssertEqual(ToolTextBudget.fold(three, columns: 80, isError: false, state: FoldState()).segments, [.lines(0..<5)])
    }

    func testShowMoreAdds500() {
        var state = FoldState()
        state.extraLinesShown = 500
        let folded = ToolTextBudget.fold(lines(2000), columns: 80, isError: false, state: state)
        XCTAssertEqual(folded.segments, [.lines(0..<512), .fold(hiddenLines: 1484), .lines(1996..<2000)])
        state.extraLinesShown = 5000
        XCTAssertEqual(ToolTextBudget.fold(lines(2000), columns: 80, isError: false, state: state).segments, [.lines(0..<2000)])
        let err = ToolTextBudget.fold(lines(2000), columns: 80, isError: true, state: {
            var s = FoldState(); s.extraLinesShown = 500; return s
        }())
        XCTAssertEqual(err.segments, [.fold(hiddenLines: 1482), .lines(1482..<2000)])
    }

    func testShowAllCapped() {
        var state = FoldState()
        state.showAll = true
        let folded = ToolTextBudget.fold(lines(30_000) { _ in "x" }, columns: 80, isError: false, state: state)
        XCTAssertTrue(folded.hitShowAllCap)
        XCTAssertEqual(folded.segments, [.lines(0..<20_000), .fold(hiddenLines: 10_000)])
        let all = ToolTextBudget.fold(lines(100), columns: 80, isError: false, state: state)
        XCTAssertFalse(all.hitShowAllCap)
        XCTAssertEqual(all.segments, [.lines(0..<100)])
    }

    func testShowAllByteCap() {
        var state = FoldState()
        state.showAll = true
        // 1000-byte lines: 2 MB holds 2097152 / 1001 = 2095 lines.
        let folded = ToolTextBudget.fold(lines(5000) { _ in String(repeating: "y", count: 1000) },
                                         columns: 2000, isError: false, state: state)
        XCTAssertTrue(folded.hitShowAllCap)
        XCTAssertEqual(folded.segments, [.lines(0..<2095), .fold(hiddenLines: 5000 - 2095)])
    }

    func testColumnsFromFontAdvance() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(ToolTextBudget.columns(width: advance * 80 + 1, font: font), 80)
        XCTAssertEqual(ToolTextBudget.columns(width: 0, font: font), 1)
    }

    func testFoldsLargeTextQuickly() {
        let text = lines(100_000) { "line \($0) " + String(repeating: "z", count: 40) }
        XCTAssertGreaterThan(text.utf8.count, 5_000_000 - 500_000)
        let start = Date()
        let folded = ToolTextBudget.fold(text, columns: 100, isError: false, state: FoldState())
        let elapsed = Date().timeIntervalSince(start)
        print("ToolTextBudget perf: \(Int(elapsed * 1000)) ms for \(text.utf8.count) bytes")
        XCTAssertEqual(folded.segments, [.lines(0..<12), .fold(hiddenLines: 100_000 - 16), .lines(99_996..<100_000)])
        XCTAssertLessThan(elapsed, 0.2)
    }
}
