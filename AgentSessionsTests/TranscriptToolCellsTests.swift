import AppKit
import SwiftUI
import XCTest
@testable import AgentSessions

/// Task 13a: the Session view's table runs on `TranscriptToolRows.emit` rows. These tests host a
/// real table (window + scroll view + `BlockTableView` + `BlockTableController.apply`) and drive
/// the controller's toggles, fold links and row lookup.
@MainActor
final class TranscriptToolCellsTests: XCTestCase {
    private typealias F = TranscriptTestFixtures
    private typealias Block = SessionTranscriptBuilder.LogicalBlock

    // MARK: - Harness

    /// A window that hosts the Session view's table the way `TranscriptBlockListView.makeNSView`
    /// builds it, with a controller that received one `apply`.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let scroll: NSScrollView
        let table: NSTableView
        let controller: BlockTableController
        private(set) var blocks: [Block]
        let source: SessionSource
        let sessionID = "tool-cells-\(UUID().uuidString)"

        /// L1 summaries handed to every `apply`, as the snapshot's `rowSummaries`.
        var rowSummaries: [Int: TranscriptDerivedState.RowSummaryEntry]

        init(_ blocks: [Block], source: SessionSource = .claude, size: NSSize = NSSize(width: 640, height: 900),
             rowSummaries: [Int: TranscriptDerivedState.RowSummaryEntry] = [:]) {
            self.source = source
            self.rowSummaries = rowSummaries
            self.blocks = F.sequence(blocks)
            controller = BlockTableController()
            let views = BlockTableController.makeScrollView(selectionOwner: controller)
            scroll = views.scroll
            table = views.table
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.frame = NSRect(origin: .zero, size: size)
            window.contentView = scroll
            controller.attach(table: table, scroll: scroll)
            apply()
        }

        /// Replaces the stream (a live append) and applies it.
        func replace(_ blocks: [Block]) {
            self.blocks = F.sequence(blocks)
            apply()
        }

        /// Role filters handed to every `apply`.
        var activeRoleFilters = Set(TranscriptRoleFilter.allCases)

        /// Applies the same stream again (after a filter change).
        func reapply() { apply() }

        private func apply() {
            let index = ToolInvocationIndex.build(blocks: blocks, source: source)
            var failed = Set<Int>()
            for invocation in index.invocations {
                if case .failed = invocation.status { failed.insert(invocation.id) }
            }
            let jumps = TranscriptDerivedState.jumpIDs(blocks: blocks, index: index, failedInvocationIDs: failed)
            controller.apply(allBlocks: blocks, invocationIndex: index, failedInvocationIDs: failed,
                             toolJumpIDs: jumps.tools, errorJumpIDs: jumps.errors,
                             totalBlockCount: blocks.count, fontSize: 13, source: source, sessionID: sessionID,
                             activeRoleFilters: activeRoleFilters, rowSummaries: rowSummaries)
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
        }

        /// Runs the main run loop until every off-main presentation landed.
        @discardableResult
        func waitForPresentations(timeout: TimeInterval = 20) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while controller.hasPendingToolPresentations && Date() < deadline
            layout()
            return !controller.hasPendingToolPresentations
        }

        var rowIDs: [Int] { controller.rows.map(\.id) }

        /// The viewport shows the end of the last row.
        var isAtBottom: Bool {
            layout()
            guard table.numberOfRows > 0 else { return true }
            let end = table.rect(ofRow: table.numberOfRows - 1).maxY
            return scroll.contentView.bounds.maxY >= end - 1
        }

        func rowIndex(id: Int) -> Int? { controller.rows.firstIndex { $0.id == id } }

        func invocation(id: Int) -> ToolInvocationRowModel? {
            for row in controller.rows {
                if case .toolInvocation(let model) = row.content, model.invocationID == id { return model }
            }
            return nil
        }

        func view<T: NSView>(id: Int, as type: T.Type) -> T? {
            guard let row = rowIndex(id: id) else { return nil }
            return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? T
        }

        /// Whole-session matches for `query` after the decode pass (Task 15), as the derived
        /// state computes them.
        func decodedMatches(_ query: String) -> [TranscriptDerivedState.BlockMatch] {
            let store = ToolSearchTextStore()
            var done = false
            store.start(blocks: blocks, index: ToolInvocationIndex.build(blocks: blocks, source: source), source: source,
                        sessionID: sessionID, viewportBlock: blocks.count - 1) { _ in done = true }
            let deadline = Date().addingTimeInterval(10)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return TranscriptDerivedState.computeFindMatches(blocks: blocks, query: query, toolText: store.text(forBlock:))
        }
    }

    private func json(_ object: [String: Any]) -> String {
        ToolJSON.string(from: object, pretty: false) ?? "{}"
    }

    private func bash(_ id: String, _ command: String) -> Block {
        F.block(.toolCall, id: id, toolName: "Bash", toolInput: json(["command": command]))
    }

    private func read(_ id: String, _ path: String) -> Block {
        F.block(.toolCall, id: id, toolName: "Read", toolInput: json(["file_path": path]))
    }

    private func output(_ id: String, _ text: String = "ok", failed: Bool = false) -> Block {
        F.block(.toolOut, id: id, text: text, isError: failed)
    }

    private func user(_ text: String = "go") -> Block { F.block(.user, text: text) }
    private func assistant(_ text: String = "done") -> Block { F.block(.assistant, text: text) }
    private func hid(_ group: Int) -> Int { TranscriptToolRows.groupHeaderRowID(forGroup: group) }

    /// 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant: one closed group of two invocations (1, 3).
    private var twoCallGroup: [Block] {
        [user(), bash("t1", "make"), output("t1"), read("t2", "/repo/Sources/App.swift"), output("t2"), assistant()]
    }

    // MARK: - Toggles

    func testToggleGroupInsertsRows() {
        let h = Harness(twoCallGroup)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        XCTAssertEqual(h.table.numberOfRows, 3)

        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5], "rows grow by the group's invocation count")
        XCTAssertEqual(h.table.numberOfRows, h.controller.rows.count)
        XCTAssertEqual(h.invocation(id: 1)?.position, .first)
        XCTAssertEqual(h.invocation(id: 3)?.position, .last)
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false, "opening a group opens L1, not L2")

        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        XCTAssertEqual(h.table.numberOfRows, 3)
    }

    func testRowIndexForOutputBlockFindsInvocationRow() {
        // ... plus 6 c3 · 7 o3: a solo invocation after the assistant message.
        let h = Harness(twoCallGroup + [bash("t3", "ls"), output("t3")])
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5, 6])

        // Output block 7 → its solo invocation row (id 6).
        XCTAssertEqual(h.controller.rowIndex(forBlock: 7), h.rowIndex(id: 6))
        // Output block 4 sits in the closed group → the header row.
        XCTAssertEqual(h.controller.rowIndex(forBlock: 4), h.rowIndex(id: hid(1)))
        // A message block → its own row.
        XCTAssertEqual(h.controller.rowIndex(forBlock: 5), h.rowIndex(id: 5))

        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.controller.rowIndex(forBlock: 4), h.rowIndex(id: 3), "open group → the invocation row")
        XCTAssertEqual(h.controller.rowIndex(forBlock: 3), h.rowIndex(id: 3), "the call block → the same row")
        XCTAssertNotNil(h.rowIndex(id: 3))
    }

    func testOptionToggleOpensAllInvocations() {
        let h = Harness(twoCallGroup)

        h.controller.toggleGroup(groupID: 1, allRows: true)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, true)
        XCTAssertEqual(h.invocation(id: 3)?.isOpen, true)
        XCTAssertEqual(h.table.numberOfRows, 5)

        // Option-click on one invocation closes every invocation of its group.
        h.controller.toggleInvocation(invocationID: 1, allInGroup: true)
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false)
        XCTAssertEqual(h.invocation(id: 3)?.isOpen, false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5], "the group stays open")

        // A plain click toggles one invocation.
        h.controller.toggleInvocation(invocationID: 3, allInGroup: false)
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false)
        XCTAssertEqual(h.invocation(id: 3)?.isOpen, true)

        // Option-click on an open group closes it and every invocation in it.
        h.controller.toggleGroup(groupID: 1, allRows: true)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        XCTAssertFalse(h.controller.openInvocations.contains(3))
    }

    // MARK: - L2 presentation and fold links

    func testFoldLinkShowAllGrowsHeight() throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let h = Harness([user(), bash("t1", "seq 1 200"), output("t1", lines)])
        XCTAssertEqual(h.rowIDs, [0, 1])
        let row = try XCTUnwrap(h.rowIndex(id: 1))
        let closedHeight = h.table.rect(ofRow: row).height

        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations(), "the L2 body is built off the main thread and lands")
        let openHeight = h.table.rect(ofRow: row).height
        XCTAssertGreaterThan(openHeight, closedHeight + 100, "the open row shows the folded output")

        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let storage = try XCTUnwrap(cell.bodyText.textStorage)
        var showAll: (url: URL, location: Int)?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL, ToolFoldLink(url: url) == .showAll(action: 0) { showAll = (url, range.location) }
        }
        let link = try XCTUnwrap(showAll, "the folded output offers Show all")

        XCTAssertTrue(h.controller.textView(cell.bodyText, clickedOnLink: link.url, at: link.location))
        XCTAssertTrue(h.waitForPresentations())
        let allHeight = h.table.rect(ofRow: row).height
        XCTAssertGreaterThan(allHeight, openHeight + 1000, "Show all renders every line")
    }

    /// The cell's "Show all" fold control for action 0.
    private func showAllLink(in cell: ToolInvocationCellView) -> (url: URL, location: Int)? {
        guard let storage = cell.bodyText.textStorage else { return nil }
        var found: (url: URL, location: Int)?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL, ToolFoldLink(url: url) == .showAll(action: 0) { found = (url, range.location) }
        }
        return found
    }

    // MARK: - Fix round 1

    func testFailedTailInvocationKeepsFollowingTail() {
        // Enough messages to scroll, then a failed call whose L2 opens by default (seeded) and
        // lands off the main thread after the view pinned to the bottom.
        var blocks: [Block] = []
        for i in 0..<20 {
            blocks.append(user("question \(i)\nsecond line\nthird line"))
            blocks.append(assistant("answer \(i)\nmore\nmore"))
        }
        let failing = (1...120).map { "error line \($0)" }.joined(separator: "\n")
        blocks += [bash("t1", "make"), output("t1", failing, failed: true)]
        let h = Harness(blocks)
        XCTAssertEqual(h.invocation(id: 40)?.isOpen, true)
        XCTAssertTrue(h.waitForPresentations())
        XCTAssertGreaterThan(h.table.rect(ofRow: h.table.numberOfRows - 1).height, 200, "the L2 body landed")
        XCTAssertTrue(h.isAtBottom, "a landing L2 body keeps the tail in view")

        // A live append of another failing call keeps following.
        h.replace(blocks + [assistant("retrying"), bash("t2", "make again"), output("t2", failing, failed: true)])
        XCTAssertEqual(h.invocation(id: 43)?.isOpen, true)
        XCTAssertTrue(h.waitForPresentations())
        XCTAssertGreaterThan(h.table.rect(ofRow: h.table.numberOfRows - 1).height, 200)
        XCTAssertTrue(h.isAtBottom, "live tail still follows after the second landing")
    }

    func testCellOrdinalsFollowRowsAfterGroupToggle() throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant · 6 S call · 7 S output
        let h = Harness([user(), bash("t1", "make"), output("t1", lines), bash("t2", "make test"), output("t2", lines),
                         assistant(), bash("t3", "seq 1 200"), output("t3", lines)])
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5, 6])
        h.controller.toggleInvocation(invocationID: 6, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())
        XCTAssertEqual(try XCTUnwrap(h.view(id: 6, as: ToolInvocationCellView.self)).bodyText.blockOrdinal, 3)

        // Opening the group inserts two rows above S; S's cell moves without a reconfigure.
        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5, 6])
        let cell = try XCTUnwrap(h.view(id: 6, as: ToolInvocationCellView.self))
        XCTAssertEqual(cell.bodyText.blockOrdinal, 5, "the moved cell names its new row")

        // S's Show all acts on S, never on the group member now at S's old index.
        let link = try XCTUnwrap(showAllLink(in: cell))
        XCTAssertTrue(h.controller.textView(cell.bodyText, clickedOnLink: link.url, at: link.location))
        XCTAssertEqual(h.controller.foldStates[6]?[0]?.showAll, true)
        XCTAssertNil(h.controller.foldStates[1])
        XCTAssertNil(h.controller.foldStates[3])
    }

    func testFindRepaintUpdatesToolPillWithoutResettingBody() throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let h = Harness([user(), bash("t1", "seq 1 200"), output("t1", lines)])
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        cell.bodyText.setSelectedRange(NSRange(location: 0, length: 4))

        let match = TranscriptDerivedState.BlockMatch(globalBlockIndex: 2, rangeInBlockText: NSRange(location: 0, length: 4),
                                                      ordinal: 0)
        h.controller.applyFind(source: .local, query: "line", matches: [match], token: 1, direction: 1,
                               reset: true, shouldJump: false)
        XCTAssertEqual(cell.findMatchCount, 1, "the pill shows the match")
        XCTAssertEqual(cell.bodyText.selectedRange(), NSRange(location: 0, length: 4),
                       "a find repaint leaves the L2 body and its selection alone")
    }

    // MARK: - Find on decoded text (Task 15)

    func testMatchInFoldOpensAndEscRestores() throws {
        var lines = (1...200).map { "line \($0)" }
        lines[149] = "needle here"
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant: a closed group of invocations 1 and 3.
        let h = Harness([user(), bash("t1", "make"), output("t1"), bash("t2", "seq 1 200"),
                         output("t2", lines.joined(separator: "\n")), assistant()])
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        let matches = h.decodedMatches("needle")
        XCTAssertEqual(matches.map(\.space), [.decoded])
        XCTAssertEqual(matches.first?.globalBlockIndex, 3)

        h.controller.applyFind(source: .local, query: "needle", matches: matches, token: 1, direction: 1,
                               reset: true, shouldJump: true)
        XCTAssertTrue(h.waitForPresentations())

        // The group, the invocation and the fold that hid line 150 opened.
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])
        XCTAssertTrue(h.controller.openInvocations.contains(3))
        XCTAssertEqual(h.controller.foldStates[3]?[0]?.showAll, true)

        // The match is highlighted inside L2 as the current match, and scrolled into view.
        let cell = try XCTUnwrap(h.view(id: 3, as: ToolInvocationCellView.self))
        let needle = (cell.bodyText.string as NSString).range(of: "needle")
        XCTAssertNotEqual(needle.location, NSNotFound, "the opened body shows the line")
        XCTAssertTrue(cell.bodyFindHighlights.contains { $0.range == needle && $0.isCurrent },
                      "\(cell.bodyFindHighlights)")
        XCTAssertNotNil(cell.bodyText.textStorage?.attribute(.backgroundColor, at: needle.location, effectiveRange: nil))
        let rect = try XCTUnwrap(cell.bodyRect(forCharacterRange: needle, in: h.table))
        XCTAssertTrue(h.scroll.contentView.bounds.contains(rect),
                      "match \(rect) inside the viewport \(h.scroll.contentView.bounds)")

        // Esc: everything Find opened closes again.
        h.controller.applyFind(source: .local, query: "", matches: [], token: 2, direction: 1, reset: true,
                               shouldJump: false)
        XCTAssertTrue(h.waitForPresentations())
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        XCTAssertFalse(h.controller.openGroups.contains(1))
        XCTAssertFalse(h.controller.openInvocations.contains(3))
        XCTAssertNil(h.controller.foldStates[3], "the fold is back to its state before Find")
    }

    func testRawJumpRevealsDecodedMatchAfterDecodePass() throws {
        var lines = (1...200).map { "line \($0)" }
        lines[149] = "needle here"
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant: a closed group of invocations 1 and 3.
        let h = Harness([user(), bash("t1", "make"), output("t1"), bash("t2", "seq 1 200"),
                         output("t2", lines.joined(separator: "\n")), assistant()])
        // Before the decode pass: the match is raw, in output block 4. The jump opens the row only.
        let raw = TranscriptDerivedState.computeFindMatches(blocks: h.blocks, query: "needle")
        XCTAssertEqual(raw.map(\.space), [.raw])
        h.controller.applyFind(source: .local, query: "needle", matches: raw, token: 1, direction: 1,
                               reset: true, shouldJump: true)
        XCTAssertTrue(h.waitForPresentations())
        XCTAssertTrue(h.controller.openInvocations.contains(3))
        XCTAssertNil(h.controller.foldStates[3], "a raw match cannot open a fold")

        // The pass ends: Find re-runs once with the decoded match of the same invocation.
        let decoded = h.decodedMatches("needle")
        XCTAssertEqual(decoded.map(\.space), [.decoded])
        let counts = h.controller.refreshFindAfterRowsChanged(matches: decoded)
        XCTAssertEqual(counts.current, 1)
        XCTAssertTrue(h.waitForPresentations())

        XCTAssertEqual(h.controller.foldStates[3]?[0]?.showAll, true, "the fold hiding line 150 opened")
        let cell = try XCTUnwrap(h.view(id: 3, as: ToolInvocationCellView.self))
        let needle = (cell.bodyText.string as NSString).range(of: "needle")
        XCTAssertNotEqual(needle.location, NSNotFound)
        XCTAssertTrue(cell.bodyFindHighlights.contains { $0.range == needle && $0.isCurrent },
                      "\(cell.bodyFindHighlights)")
        let rect = try XCTUnwrap(cell.bodyRect(forCharacterRange: needle, in: h.table))
        XCTAssertTrue(h.scroll.contentView.bounds.contains(rect))
    }

    func testUnifiedJumpWithNoLocalMatchFlashesRow() {
        let header = "Chunk ID: a1\nWall time: 0.1 seconds\nProcess exited with code 0\nOriginal token count: 3\nOutput:\nclean\n"
        // 0 user · 1 call · 2 output · 3 assistant: one solo invocation row.
        let h = Harness([user(), F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: json(["cmd": "git status"])),
                         F.block(.toolOut, id: "t1", text: header, toolName: "exec_command"), assistant()],
                        source: .codex)
        XCTAssertEqual(h.rowIDs, [0, 1, 3])
        // The search index matched the raw header; the decoded text has no such word.
        XCTAssertFalse(TranscriptDerivedState.computeFindMatches(blocks: h.blocks, query: "chunk").isEmpty)
        let matches = h.decodedMatches("chunk")
        XCTAssertTrue(matches.isEmpty)

        let counts = h.controller.applyFind(source: .unified, query: "chunk", matches: matches, token: 1, direction: 1,
                                            reset: true, shouldJump: true)
        XCTAssertEqual(counts.total, 0)
        XCTAssertTrue(h.controller.openInvocations.contains(1), "the invocation opens to L2")
        XCTAssertTrue(h.controller.isFlashing(rowID: 1), "its row flashes")
        XCTAssertTrue(h.waitForPresentations())

        // Clearing the search closes what the jump opened.
        h.controller.applyFind(source: .unified, query: "", matches: [], token: 2, direction: 1, reset: true,
                               shouldJump: false)
        XCTAssertFalse(h.controller.openInvocations.contains(1))
    }

    // MARK: - ▲▼ jumps (Task 16)

    func testJumpIntoClosedGroupOpensIt() {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant: one closed group of two invocations (1, 3).
        let h = Harness(twoCallGroup)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        XCTAssertFalse(h.controller.openGroups.contains(1))

        h.controller.handleRoleJumpIntent(token: 1, role: .tools, direction: 1)
        XCTAssertTrue(h.controller.openGroups.contains(1), "the jump opens the group that hides invocation 1")
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])
        XCTAssertTrue(h.controller.isFlashing(rowID: 1), "and lands on the invocation row")

        // The open is a user open: clearing a find does not close it again.
        h.controller.applyFind(source: .local, query: "", matches: [], token: 2, direction: 1, reset: true,
                               shouldJump: false)
        XCTAssertTrue(h.controller.openGroups.contains(1))
    }

    /// A short window over a long stream so the table can scroll; filler messages keep the end reachable.
    private func jumpHarness(_ blocks: [Block]) -> Harness {
        Harness(blocks + (0..<40).map { _ in assistant("filler") }, size: NSSize(width: 640, height: 160))
    }

    /// Puts row `index` at the top of the viewport.
    private func scrollRowToTop(_ h: Harness, row index: Int) {
        h.layout()
        h.scroll.contentView.scroll(to: NSPoint(x: 0, y: h.table.rect(ofRow: index).minY))
        h.scroll.reflectScrolledClipView(h.scroll.contentView)
        h.layout()
    }

    func testDownFromClosedHeaderLandsOnFirstInvocationThenStepsThroughGroup() {
        // 0 user · 1 c o (solo) · 3 assistant · 4 c5 o · 6 c7 o (group 4: ids 4, 6) · 8 assistant
        let h = jumpHarness([user(), bash("t1", "ls"), output("t1"), assistant(),
                             bash("t2", "make"), output("t2"), read("t3", "/repo/a.swift"), output("t3"), assistant()])
        XCTAssertEqual(Array(h.rowIDs.prefix(4)), [0, 1, 3, hid(4)])
        scrollRowToTop(h, row: h.rowIndex(id: hid(4))!)

        // (a) ▼ from the closed header lands on the group's first invocation and opens the group.
        h.controller.handleRoleJumpIntent(token: 1, role: .tools, direction: 1)
        XCTAssertTrue(h.controller.openGroups.contains(4))
        XCTAssertTrue(h.controller.isFlashing(rowID: 4))

        // (b) ▼ again: the second invocation of the now open group.
        h.controller.handleRoleJumpIntent(token: 2, role: .tools, direction: 1)
        XCTAssertTrue(h.controller.isFlashing(rowID: 6))

        // (c) ▲ from inside the group: the previous invocation, then out of the group.
        h.controller.handleRoleJumpIntent(token: 3, role: .tools, direction: -1)
        XCTAssertTrue(h.controller.isFlashing(rowID: 4))
        h.controller.handleRoleJumpIntent(token: 4, role: .tools, direction: -1)
        XCTAssertTrue(h.controller.isFlashing(rowID: 1))
    }

    func testErrorsJumpOpensClosedGroupThenReachesPlainError() {
        // 0 user · 1 c o ✗ · 3 c o (group 1: ids 1, 3) · 5 assistant · 6 plain .error
        let h = jumpHarness([user(), bash("t1", "make"), output("t1", "boom", failed: true),
                             bash("t2", "ls"), output("t2"), assistant(),
                             F.block(.error, text: "plain error", isError: true)])
        // A group with a failure opens by default; the user closes it.
        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertFalse(h.controller.openGroups.contains(1))
        scrollRowToTop(h, row: 0)

        // (d) ▼ Errors reaches the failed invocation inside the closed group and opens it.
        h.controller.handleRoleJumpIntent(token: 1, role: .errors, direction: 1)
        XCTAssertTrue(h.controller.openGroups.contains(1))
        XCTAssertTrue(h.controller.isFlashing(rowID: 1))

        // The next stop is the plain error block; groups stay as they are.
        h.controller.handleRoleJumpIntent(token: 2, role: .errors, direction: 1)
        XCTAssertTrue(h.controller.isFlashing(rowID: 6))
        XCTAssertEqual(h.controller.openGroups, [1])
    }

    // MARK: - Card chrome

    func testCardPositionsDrawContinuousBar() throws {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 c3 · 6 o3 · 7 assistant
        let h = Harness([user(), bash("t1", "make"), output("t1"), bash("t2", "make test"), output("t2"),
                         bash("t3", "make lint"), output("t3"), assistant()])
        h.controller.toggleGroup(groupID: 1, allRows: false)
        h.layout()
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5, 7])
        XCTAssertEqual(h.invocation(id: 3)?.position, .middle)

        let header = try XCTUnwrap(h.view(id: hid(1), as: ToolGroupHeaderCellView.self))
        let cells = try [1, 3, 5].map { try XCTUnwrap(h.view(id: $0, as: ToolInvocationCellView.self)) }
        h.layout()
        let rowCells: [ToolCardCellView] = [header] + cells
        // The drawn bar: a tool cell clips its card (a joined edge overhangs the cell by the
        // corner radius), so the visible bar is the bar's frame inside its cell.
        let frames = rowCells.map { cell -> NSRect in
            XCTAssertTrue(cell.clipsToBounds)
            let bar = cell.accentBarView.convert(cell.accentBarView.bounds, to: h.table)
            return bar.intersection(cell.convert(cell.bounds, to: h.table))
        }
        for frame in frames {
            XCTAssertEqual(frame.width, CardMetrics.accentBarWidth, accuracy: 0.01)
            XCTAssertGreaterThan(frame.height, 0)
        }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(upper.maxY, lower.minY, accuracy: 0.01, "header, first, middle and last bars touch")
            XCTAssertEqual(upper.minX, lower.minX, accuracy: 0.01)
        }

        // Joined edges are square (the card's rounded corner lies past the clipped cell edge);
        // the header's top and the last row's bottom are the card's rounded outer edges.
        for (index, cell) in rowCells.enumerated() {
            let card = cell.cardBackground.convert(cell.cardBackground.bounds, to: h.table)
            let bounds = cell.convert(cell.bounds, to: h.table)
            XCTAssertEqual(card.minY < bounds.minY, index > 0, "row \(index) top joined")
            XCTAssertEqual(card.maxY > bounds.maxY, index < 3, "row \(index) bottom joined")
        }

        // The last row's card ends before the next message: a gap, not a joined bar.
        let lastRow = try XCTUnwrap(h.rowIndex(id: 5))
        XCTAssertGreaterThan(h.table.rect(ofRow: lastRow).maxY, frames[3].maxY + 1)
    }

    // MARK: - Default open state (spec §6.1)

    func testFailedSoloInvocationOpensOnceAndStaysClosedAfterUserToggle() {
        let blocks = [user(), bash("t1", "make"), output("t1", "error: boom", failed: true)]
        let h = Harness(blocks)
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, true, "a failed row opens to L2")

        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false)

        h.replace(blocks + [assistant("next")])
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false, "a user toggle is never reseeded")
    }

    func testFailedGroupSeedsOpenAndUserCloseSticks() {
        let blocks = [user(), bash("t1", "make"), output("t1"), bash("t2", "make test"),
                      output("t2", "FAILED", failed: true), assistant()]
        let h = Harness(blocks)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, false)
        XCTAssertEqual(h.invocation(id: 3)?.isOpen, true)

        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5])
        h.replace(blocks + [user("again")])
        XCTAssertEqual(h.rowIDs, [0, hid(1), 5, 6], "the closed group stays closed")
    }

    // MARK: - Task 13b: copy, raw event, VoiceOver, Increase Contrast

    /// A private pasteboard, so the tests never touch the user's.
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("tool-cells-test-\(UUID().uuidString)"))
    }

    /// Runs the main run loop until `condition` holds.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func menuItem(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func perform(_ item: NSMenuItem?, in menu: NSMenu) {
        guard let item else { return XCTFail("menu item missing") }
        menu.performActionForItem(at: menu.index(of: item))
    }

    func testCopyReturnsPlainText() throws {
        // Two actions in one invocation are not available through a plain Claude pair, so the
        // single-action forms are checked here and the multi-action join by the format helpers.
        let h = Harness([user(), bash("t1", "make"), output("t1", "built 3 targets\nok"), assistant()])
        let pasteboard = privatePasteboard()
        h.controller.toolPasteboard = pasteboard
        let menu = h.controller.toolContextMenu(invocationID: 1, actionIndex: nil)
        XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty },
                       ["Copy", "Copy Command", "Copy Output", "Copy as Markdown", "Show Raw Event", "Speak",
                        "Stop Speaking"], "a solo invocation has no group to expand")

        perform(menuItem(menu, "Copy"), in: menu)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "$ make\nbuilt 3 targets\nok",
                       "Copy is the plain form: no gutter, no fold rows")

        pasteboard.clearContents()
        perform(menuItem(menu, "Copy Command"), in: menu)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "make")

        pasteboard.clearContents()
        perform(menuItem(menu, "Copy Output"), in: menu)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "built 3 targets\nok")

        pasteboard.clearContents()
        perform(menuItem(menu, "Copy as Markdown"), in: menu)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "**Ran make**\n```\n$ make\nbuilt 3 targets\nok\n```")
        XCTAssertFalse(h.controller.hasPendingToolPresentations, "the menu action built off the main thread and finished")
    }

    func testCopyFormatsJoinActionsAndFenceSafely() {
        func action(_ command: String?, _ verb: String, _ object: String, output: String?, plain: String) -> ToolAction {
            ToolAction(category: command == nil ? .read : .shell, verbKey: verb, object: object,
                       objectIsAgentLabel: false, objectDetail: nil, context: [], command: command,
                       exactCommand: command, heredoc: nil, inputFields: [],
                       output: output.map { DecodedText(text: $0, sourceMap: [], shape: .plain) }, facts: [],
                       hiddenNotes: [], status: .success, plainText: plain)
        }
        let a = action("make", ToolVerb.ran, "make", output: "ok", plain: "$ make\nok")
        let b = action(nil, ToolVerb.read, "App.swift", output: "code ``` fence", plain: "Read App.swift\ncode ``` fence")
        var invocation = ToolInvocation(ref: ToolInvocationRef(id: 1, callBlockIndex: 1, outputBlockIndices: [2], status: .success),
                                        displayToolName: "exec", actions: [a, b], scriptSource: nil,
                                        scriptOutput: DecodedText(text: "loose", sourceMap: [], shape: .plain),
                                        durationSeconds: nil)
        XCTAssertEqual(ToolCopyFormat.text(.plain, invocation: invocation, actionIndex: nil),
                       "$ make\nok\n\nRead App.swift\ncode ``` fence\n\nloose")
        XCTAssertEqual(ToolCopyFormat.text(.plain, invocation: invocation, actionIndex: 1), "Read App.swift\ncode ``` fence")
        XCTAssertEqual(ToolCopyFormat.text(.command, invocation: invocation, actionIndex: nil), "make")
        XCTAssertNil(ToolCopyFormat.text(.command, invocation: invocation, actionIndex: 1), "no shell action: nothing to copy")
        XCTAssertEqual(ToolCopyFormat.text(.output, invocation: invocation, actionIndex: nil),
                       "ok\n\ncode ``` fence\n\nloose")
        XCTAssertEqual(ToolCopyFormat.text(.markdown, invocation: invocation, actionIndex: nil),
                       "**Ran make**\n```\n$ make\nok\n```\n\n**Read App.swift**\n````\nRead App.swift\ncode ``` fence\n````",
                       "a fence longer than any backtick run inside the text")
        invocation.scriptOutput = nil
        XCTAssertEqual(ToolCopyFormat.text(.plain, invocation: invocation, actionIndex: nil),
                       "$ make\nok\n\nRead App.swift\ncode ``` fence")
    }

    func testHoverCopyAndRawReachTheController() throws {
        let h = Harness([user(), bash("t1", "make"), output("t1", "ok")])
        let pasteboard = privatePasteboard()
        h.controller.toolPasteboard = pasteboard
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        cell.performHoverCopy(actionIndex: 0)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "$ make\nok")
    }

    func testShowRawMentionsShortenedStrings() throws {
        var call = bash("t1", "make")
        call.rawJSON = #"{"type":"tool_use","input":{"command":"make","blob":"[OMITTED bytes=9000]"}}"#
        var out = output("t1", "ok")
        // Claude stores rawJSON base64-encoded.
        out.rawJSON = Data(#"{"type":"tool_result","content":"ok"}"#.utf8).base64EncodedString()
        var other = bash("t2", "ls")
        other.rawJSON = #"{"type":"tool_use","input":{"command":"ls"}}"#
        let h = Harness([user(), call, out, other, output("t2")])

        // The two calls form a closed group: open it so the cells exist.
        h.controller.toggleGroup(groupID: 1, allRows: false)
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let otherCell = try XCTUnwrap(h.view(id: 3, as: ToolInvocationCellView.self))

        // Parsing and pretty-printing run off the main thread; the popover opens when ready.
        func popover(_ id: Int, _ anchor: NSView) throws -> ToolRawEventViewController {
            var shown: NSPopover??
            h.controller.showRawEvent(invocationID: id, relativeTo: anchor.bounds, of: anchor) { shown = .some($0) }
            XCTAssertFalse(shown != nil, "not opened synchronously on the main thread")
            spin { shown != nil }
            let popover = try XCTUnwrap(try XCTUnwrap(shown))
            XCTAssertEqual(h.controller.rawEventInvocationID, id)
            return try XCTUnwrap(popover.contentViewController as? ToolRawEventViewController)
        }
        let controller = try popover(1, cell)
        let text = controller.displayedText
        XCTAssertTrue(text.contains("Large strings were shortened when the app stored this event."), text)
        XCTAssertTrue(text.contains("[OMITTED bytes=9000]"))
        XCTAssertTrue(text.contains("\"tool_use\""), "the call, pretty-printed")
        XCTAssertTrue(controller.rawText.contains("\n  \"input\""), "pretty-printed with indentation: \(controller.rawText)")
        XCTAssertTrue(controller.rawText.contains("\"tool_result\""), "the base64 output event is decoded")
        XCTAssertTrue(controller.rawText.contains("tool_use") && controller.rawText.contains("tool_result"))

        let clean = try popover(3, otherCell)
        XCTAssertFalse(clean.displayedText.contains("Large strings were shortened"))
        XCTAssertTrue(clean.rawText.contains("\"ls\""))
        h.controller.closeRawEvent()
        XCTAssertNil(h.controller.rawEventInvocationID)
    }

    func testRawPopoverClosesWithItsRowAndOnSessionSwitch() throws {
        var call = bash("t1", "make")
        call.rawJSON = #"{"type":"tool_use"}"#
        let blocks = [user(), call, output("t1"), bash("t2", "ls"), output("t2"), assistant()]
        let h = Harness(blocks)
        h.controller.toggleGroup(groupID: 1, allRows: false)
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))

        func open() {
            var done = false
            h.controller.showRawEvent(invocationID: 1, relativeTo: cell.bounds, of: cell) { _ in done = true }
            spin { done }
            XCTAssertEqual(h.controller.rawEventInvocationID, 1)
        }
        open()
        // Another row takes over the cell (reuse): the popover of the old row closes.
        h.controller.closeRawEventIfAnchorReassigned(cell: cell, invocationID: 1)
        XCTAssertEqual(h.controller.rawEventInvocationID, 1, "same row: stays")
        h.controller.closeRawEventIfAnchorReassigned(cell: cell, invocationID: 3)
        XCTAssertNil(h.controller.rawEventInvocationID, "another row in the same cell: closed")

        // The row goes away (its group closes): closed.
        open()
        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertNil(h.controller.rawEventInvocationID)

        // A request still being prepared when the session switches does not open.
        h.controller.toggleGroup(groupID: 1, allRows: false)
        let again = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        var opened: NSPopover??
        h.controller.showRawEvent(invocationID: 1, relativeTo: again.bounds, of: again) { opened = .some($0) }
        let index = ToolInvocationIndex.build(blocks: h.blocks, source: h.source)
        h.controller.apply(allBlocks: h.blocks, invocationIndex: index, failedInvocationIDs: [],
                           totalBlockCount: h.blocks.count, fontSize: 13, source: h.source, sessionID: "other-session")
        spin { opened != nil }
        XCTAssertEqual(opened.map { $0 == nil }, true, "dropped after the session switch")
        XCTAssertNil(h.controller.rawEventInvocationID)
    }

    // MARK: Task 13b fix round: real clicks and line/action alignment

    private func items(_ texts: [String]) -> ToolPayloadValue {
        .array(texts.map { .object(["type": .string("input_text"), "text": .string($0)]) })
    }

    private func chunk(_ id: String, exit: Int, output: String) -> String {
        let escaped = output.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return "{\"chunk_id\":\"\(id)\",\"wall_time_seconds\":0.5,\"exit_code\":\(exit),"
            + "\"original_token_count\":12,\"output\":\"\(escaped)\"}"
    }

    /// A Codex exec script with two `exec_command` calls: one invocation, two actions ("false" fails
    /// with "boom", "true" has no output).
    private var codexTwoCommands: [Block] {
        let script = """
        const a = await tools.exec_command({cmd: "false"});
        const b = await tools.exec_command({cmd: "true"});
        """
        let texts = ["Script completed\nWall time 1.2 seconds\nOutput:\n",
                     chunk("a", exit: 1, output: "boom\n"), chunk("b", exit: 0, output: "")]
        var out = F.block(.toolOut, id: "t1", text: texts.joined(), toolName: "exec")
        out.toolOutputValue = items(texts)
        return [user(), F.block(.toolCall, id: "t1", toolName: "exec", toolInput: script), out, assistant()]
    }

    /// Right-clicks at `windowPoint` the way AppKit does: hit-test, then the first view up the
    /// chain whose `menu(for:)` answers.
    private func rightClickMenu(_ h: Harness, at windowPoint: NSPoint) -> NSMenu? {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint, modifierFlags: [],
                                             timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
              let content = h.window.contentView, let frame = content.superview else { return nil }
        var view = content.hitTest(frame.convert(windowPoint, from: nil))
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    private func actionIndex(of menu: NSMenu?) -> Int?? {
        (menu?.items.first?.representedObject as? BlockTableController.ToolMenuPayload).map(\.actionIndex)
    }

    func testRightClickOpensRowMenuForTheLineUnderTheEvent() throws {
        let h = Harness(codexTwoCommands, source: .codex)
        XCTAssertTrue(h.waitForPresentations(), "the failed invocation opens at L2 and renders")
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertEqual(cell.lineAccessibilityLabels.count, 2, "two actions, two lines")

        func lineEdge(_ fromTop: CGFloat) -> NSPoint {
            let lines = cell.linesView
            let y = lines.isFlipped ? fromTop : lines.bounds.height - fromTop
            return lines.convert(NSPoint(x: 60, y: y), to: nil)
        }
        // Top and bottom edges of both lines (flipped-y mapping).
        XCTAssertEqual(actionIndex(of: rightClickMenu(h, at: lineEdge(0.5))), .some(0))
        XCTAssertEqual(actionIndex(of: rightClickMenu(h, at: lineEdge(23.5))), .some(0))
        XCTAssertEqual(actionIndex(of: rightClickMenu(h, at: lineEdge(24.5))), .some(1))
        XCTAssertEqual(actionIndex(of: rightClickMenu(h, at: lineEdge(47.5))), .some(1))

        // The L2 body: the menu covers the whole invocation.
        XCTAssertFalse(cell.bodyText.isHidden)
        let body = cell.bodyText.convert(NSPoint(x: 20, y: min(10, cell.bodyText.bounds.height / 2)), to: nil)
        let bodyMenu = rightClickMenu(h, at: body)
        XCTAssertNotNil(bodyMenu)
        XCTAssertEqual(actionIndex(of: bodyMenu), .some(nil), "no line: the invocation")
        XCTAssertEqual(bodyMenu?.items.first?.title, "Copy")
    }

    func testCopyOnSecondLineTargetsSecondAction() throws {
        let h = Harness(codexTwoCommands, source: .codex)
        XCTAssertTrue(h.waitForPresentations())
        let pasteboard = privatePasteboard()
        h.controller.toolPasteboard = pasteboard

        let second = h.controller.toolContextMenu(invocationID: 1, actionIndex: 1)
        perform(menuItem(second, "Copy"), in: second)
        spin { pasteboard.string(forType: .string) != nil }
        let plain = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(plain.hasPrefix("$ true"), plain)
        XCTAssertFalse(plain.contains("false") || plain.contains("boom"), "only the second action: \(plain)")

        pasteboard.clearContents()
        perform(menuItem(second, "Copy Command"), in: second)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "true")

        let first = h.controller.toolContextMenu(invocationID: 1, actionIndex: 0)
        pasteboard.clearContents()
        perform(menuItem(first, "Copy Command"), in: first)
        spin { pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(pasteboard.string(forType: .string), "false")

        // Copy Output is per targeted action: line 1 has "boom", line 2 has no output at all.
        XCTAssertEqual(menuItem(first, "Copy Output")?.isEnabled, true)
        XCTAssertEqual(menuItem(second, "Copy Output")?.isEnabled, false)
        let whole = h.controller.toolContextMenu(invocationID: 1, actionIndex: nil)
        XCTAssertEqual(menuItem(whole, "Copy Output")?.isEnabled, true)
    }

    func testLineIndexNeedsMatchingActionCount() {
        XCTAssertEqual(ToolCopyFormat.alignedIndex(1, lineCount: 2, actionCount: 2), 1)
        XCTAssertNil(ToolCopyFormat.alignedIndex(1, lineCount: 2, actionCount: 3), "counts differ: whole invocation")
        XCTAssertNil(ToolCopyFormat.alignedIndex(2, lineCount: 2, actionCount: 2), "out of range")
        XCTAssertNil(ToolCopyFormat.alignedIndex(0, lineCount: -1, actionCount: 1), "no ref")
    }

    func testVoiceOverLabel() throws {
        let failed = F.block(.toolOut, id: "t1", text: "boom", isError: true, sidecar: ToolSidecar(exitCode: 2))
        let h = Harness([user(), bash("t1", "make"), failed, bash("t2", "ls"), output("t2"), assistant()])
        // The failed row is seeded open; the group is open with it.
        let failedCell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertEqual(failedCell.lineAccessibilityLabels, ["Ran make, failed, exit 2"])
        XCTAssertEqual(failedCell.accessibilityDisclosureValue, "expanded")

        let okCell = try XCTUnwrap(h.view(id: 3, as: ToolInvocationCellView.self))
        XCTAssertEqual(okCell.lineAccessibilityLabels, ["Ran ls, succeeded"], "no chips: no third part")
        XCTAssertEqual(okCell.accessibilityDisclosureValue, "collapsed")

        h.controller.toggleGroup(groupID: 1, allRows: false)
        let header = try XCTUnwrap(h.view(id: hid(1), as: ToolGroupHeaderCellView.self))
        XCTAssertEqual(header.accessibilityDisclosureValue, "collapsed")
        XCTAssertTrue(header.accessibilityLabelText.hasPrefix("2 tool calls"), header.accessibilityLabelText)
        XCTAssertTrue(header.accessibilityLabelText.contains("1 failed"), header.accessibilityLabelText)

        XCTAssertEqual(ToolAccessibility.statusWord(.pending), "running")
        XCTAssertEqual(ToolAccessibility.statusWord(.rejected), "rejected")
        XCTAssertEqual(ToolAccessibility.statusWord(.noResult), "no result")
        XCTAssertEqual(ToolAccessibility.statusWord(.interrupted), "interrupted")
        XCTAssertNil(ToolAccessibility.statusWord(.unknown))
    }

    func testIncreaseContrastReachesRenderedRows() throws {
        var contrast = false
        let h = Harness([user(), bash("t1", "make"), output("t1", "built")])
        h.controller.increaseContrastProvider = { contrast }
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())

        func fill(_ cell: ToolInvocationCellView) -> NSColor? {
            let text = cell.bodyText.string as NSString
            let at = text.range(of: "built").location
            guard at != NSNotFound else { return nil }
            return cell.bodyText.textStorage?.attribute(.backgroundColor, at: at, effectiveRange: nil) as? NSColor
        }
        func white(_ color: NSColor?) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                value = color?.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
            }
            return value
        }
        let before = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let normalWhite = white(fill(before))
        XCTAssertGreaterThan(normalWhite, 0)
        XCTAssertNil(before.cardBackground.borderColor, "no border without Increase Contrast")
        let tint = before.cardBackground.fillAlpha

        contrast = true
        h.controller.accessibilityDisplayOptionsDidChange()
        XCTAssertTrue(h.waitForPresentations(), "open rows render again")
        let after = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertLessThan(white(fill(after)), normalWhite, "darker pane fill in light mode")
        XCTAssertNotNil(after.cardBackground.borderColor, "the card gets a separator border")
        XCTAssertEqual(after.cardBackground.fillAlpha, tint * 1.5, accuracy: 0.0001, "tint x1.5")
    }

    func testRekeyedGroupKeepsOpenStateWhenWindowWidens() throws {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 c3 · 6 o3 · 7 assistant, then filler. The tail
        // window starts at block 4, so the group is keyed by invocation 3 until the window widens.
        var blocks = [user(), bash("t1", "make"), output("t1"), bash("t2", "make test"), output("t2"),
                      bash("t3", "make lint"), output("t3"), assistant()]
        let total = FeatureFlags.transcriptWindowBlockTarget + 4
        while blocks.count < total { blocks.append(blocks.count.isMultiple(of: 2) ? user("u") : assistant("a")) }
        let h = Harness(blocks)
        XCTAssertEqual(Array(h.rowIDs.prefix(2)), [hid(3), 7])

        h.controller.toggleGroup(groupID: 3, allRows: false)
        XCTAssertEqual(Array(h.rowIDs.prefix(4)), [hid(3), 3, 5, 7])

        h.controller.widen(toIncludeBlock: 0)
        XCTAssertEqual(Array(h.rowIDs.prefix(6)), [0, hid(1), 1, 3, 5, 7], "the re-keyed group stays open")
    }

    // MARK: - Selection and copy (Task 14)

    private func selectionLength(_ h: Harness, row id: Int) -> Int {
        h.controller.selectableText(atRow: h.rowIndex(id: id)!).utf16.count
    }

    func testDragAcrossClosedRowsCopiesSummaries() {
        // Rows: 0 user, group header, inv 1, inv 3, 5 assistant (group open, L2 closed).
        let h = Harness(twoCallGroup)
        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])

        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (4, 4))
        XCTAssertEqual(h.controller.assembleSelectedText(),
                       "go\n\n2 tool calls\n\nRan make\n\nRead App.swift\n\ndone",
                       "a header copies its title, a closed row its L1 lines")

        // A drag that ends at the end of the second closed row leaves the assistant out.
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (3, selectionLength(h, row: 3)))
        XCTAssertEqual(h.controller.assembleSelectedText(), "go\n\n2 tool calls\n\nRan make\n\nRead App.swift")

        // Upward drag: a focus at the start of a closed row keeps the whole row.
        h.controller.setCrossBlockSelection(anchor: (4, 4), focus: (3, 0))
        XCTAssertEqual(h.controller.assembleSelectedText(), "Read App.swift\n\ndone")
    }

    func testOpenRowCopiesVisibleTextWithoutGutter() throws {
        let numbered = "     1→let a = 1\n     2→let b = 2\n     3→let c = 3"
        let h = Harness([user(), read("t1", "/repo/Sources/App.swift"), output("t1", numbered), assistant()])
        XCTAssertEqual(h.rowIDs, [0, 1, 3])
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())

        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertTrue(cell.bodyText.string.contains("\t"), "the shown body has a gutter (precondition)")

        // Whole-row selection: L1 lines, a blank line, then the visible L2 text.
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (2, 4))
        let whole = h.controller.assembleSelectedText()
        XCTAssertEqual(whole, "go\n\nRead App.swift\n\nfile_path  /repo/Sources/App.swift\n"
                       + "let a = 1\nlet b = 2\nlet c = 3\n\ndone")
        XCTAssertFalse(whole.contains("\t"), "gutter text is never copied")

        // Partial: the drag ends inside the body. The L1 lines are covered (the drag started
        // above); the body part is the selected text without its gutter.
        let lead = h.controller.toolLeadLength(atRow: 1)
        let body = cell.bodyText.string as NSString
        let second = body.range(of: "let b")
        XCTAssertNotEqual(second.location, NSNotFound)
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (1, lead + second.location + second.length))
        let partial = h.controller.assembleSelectedText()
        XCTAssertTrue(partial.hasPrefix("go\n\nRead App.swift\n\n"), partial)
        XCTAssertTrue(partial.hasSuffix("let b"), partial)
        XCTAssertFalse(partial.contains("\t"), partial)
        XCTAssertFalse(partial.contains("let c"), partial)

        // The drag starts inside the body: the L1 lines are not copied.
        h.controller.setCrossBlockSelection(anchor: (1, lead + second.location), focus: (2, 4))
        let tail = h.controller.assembleSelectedText()
        XCTAssertFalse(tail.contains("Read App.swift"), tail)
        XCTAssertTrue(tail.hasPrefix("let b = 2\nlet c = 3"), tail)
        XCTAssertTrue(tail.hasSuffix("done"), tail)
    }

    func testOpenRowWithPendingPresentationCopiesSummaryOnly() {
        let h = Harness([user(), bash("t1", "make"), output("t1", "built"), assistant()])
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.controller.hasPendingToolPresentations, "the off-main render has not landed")
        XCTAssertEqual(h.invocation(id: 1)?.isOpen, true)

        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (2, 4))
        XCTAssertEqual(h.controller.assembleSelectedText(), "go\n\nRan make\n\ndone",
                       "no body yet: the L1 lines only, and nothing is built on the main thread")
        XCTAssertTrue(h.waitForPresentations())
    }

    func testCrossBlockSelectionTintsCoveredToolRows() throws {
        let h = Harness(twoCallGroup)
        h.controller.toggleGroup(groupID: 1, allRows: false)
        XCTAssertEqual(h.rowIDs, [0, hid(1), 1, 3, 5])
        let header = try XCTUnwrap(h.view(id: hid(1), as: ToolGroupHeaderCellView.self))
        let first = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let second = try XCTUnwrap(h.view(id: 3, as: ToolInvocationCellView.self))
        XCTAssertFalse(header.isSelectionTintVisible)

        // message, closed header, closed invocation, closed invocation, message
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (4, 4))
        XCTAssertTrue(header.isSelectionTintVisible, "a copied header looks selected")
        XCTAssertTrue(first.isSelectionTintVisible)
        XCTAssertTrue(second.isSelectionTintVisible)

        // The focus ends inside the first invocation row: the second is not covered.
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (2, selectionLength(h, row: 1)))
        XCTAssertTrue(header.isSelectionTintVisible)
        XCTAssertTrue(first.isSelectionTintVisible)
        XCTAssertFalse(second.isSelectionTintVisible)

        h.controller.clearCrossBlockSelection()
        XCTAssertFalse(header.isSelectionTintVisible)
        XCTAssertFalse(first.isSelectionTintVisible)
        XCTAssertFalse(second.isSelectionTintVisible)
    }

    func testShowScriptOpenWholeBodyCopyIncludesScriptPane() throws {
        let h = Harness(codexTwoCommands, source: .codex)
        XCTAssertTrue(h.waitForPresentations(), "the failed invocation opens at L2")
        h.controller.handleToolFoldLink(.showScript, invocationID: 1)
        XCTAssertTrue(h.waitForPresentations())
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertTrue(cell.bodyText.string.contains("tools.exec_command"), "the script pane is visible (precondition)")

        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (2, 4))
        let copied = h.controller.assembleSelectedText()
        XCTAssertTrue(copied.hasPrefix("go\n\n"), copied)
        XCTAssertTrue(copied.hasSuffix("\n\ndone"), copied)
        XCTAssertTrue(copied.contains("boom"), "the action output is copied")
        XCTAssertTrue(copied.contains("const a = await tools.exec_command({cmd: \"false\"});"),
                      "the visible script pane is copied, since it is visible text")
        XCTAssertFalse(copied.contains("Hide script"), "the link is a control, not text")
        XCTAssertFalse(copied.contains("\t"), "no gutter")

        // A partial copy that covers the same body reads the same pieces.
        let lead = h.controller.toolLeadLength(atRow: 1)
        h.controller.setCrossBlockSelection(anchor: (1, lead), focus: (2, 0))
        let bodyOnly = h.controller.assembleSelectedText()
        XCTAssertFalse(bodyOnly.contains("Hide script"))
        XCTAssertTrue(bodyOnly.contains("boom"))
        XCTAssertTrue(bodyOnly.contains("const b = await tools.exec_command"))
    }

    func testRoleFilterHidingToolRowsKeepsTheirTextOutOfACopy() {
        let h = Harness(twoCallGroup)
        h.activeRoleFilters = [.user, .assistant]
        h.reapply()
        XCTAssertEqual(h.rowIDs, [0, 5], "the tool rows are hidden")

        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (1, 4))
        let copied = h.controller.assembleSelectedText()
        XCTAssertEqual(copied, "go\n\ndone")
        XCTAssertFalse(copied.contains("tool calls"))
        XCTAssertFalse(copied.contains("make"))
    }

    func testUpwardDragEndingOnAnOpenRowsLineCopiesLeadAndBody() throws {
        let numbered = "     1→let a = 1\n     2→let b = 2\n     3→let c = 3"
        let h = Harness([user(), read("t1", "/repo/Sources/App.swift"), output("t1", numbered), assistant()])
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())

        // The anchor is in the assistant message; the focus lands on the L1 line (offset 0).
        h.controller.setCrossBlockSelection(anchor: (2, 4), focus: (1, 0))
        XCTAssertEqual(h.controller.assembleSelectedText(),
                       "Read App.swift\n\nfile_path  /repo/Sources/App.swift\nlet a = 1\nlet b = 2\nlet c = 3\n\ndone")

        // The row also shows the tint, and the body paints its whole range.
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        h.controller.setCrossBlockSelection(anchor: (2, 4), focus: (1, 0))
        XCTAssertTrue(cell.isSelectionTintVisible)
    }

    // MARK: - Final review fixes

    /// A Codex session of `exec_command` calls: (call id, command, exit code) per call, each call
    /// with its result and an assistant reply after it, so every call is a solo invocation.
    private func codexSession(_ id: String, _ calls: [(String, String, Int)]) -> Session {
        var events = [TranscriptTestFixtures.userEvent("\(id)-u", "go")]
        for (callID, command, exitCode) in calls {
            events.append(SessionEvent(id: "\(id)-c-\(callID)", timestamp: nil, kind: .tool_call, role: "assistant",
                                       text: nil, toolName: "exec_command", toolInput: #"{"cmd":"\#(command)"}"#,
                                       toolOutput: nil, toolNamespace: nil, toolCallID: callID,
                                       messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"))
            events.append(SessionEvent(id: "\(id)-r-\(callID)", timestamp: nil, kind: .tool_result, role: "tool",
                                       text: nil, toolName: nil, toolInput: nil,
                                       toolOutput: "Process exited with code \(exitCode)\nOutput:\nout",
                                       toolNamespace: nil, toolCallID: callID,
                                       messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"))
            events.append(TranscriptTestFixtures.assistantDelta("\(id)-a-\(callID)", "next", messageID: "m-\(id)-\(callID)"))
        }
        return Session(id: id, source: .codex, startTime: nil, endTime: nil, model: "test",
                       filePath: "/tmp/\(id).jsonl", fileSizeBytes: nil, eventCount: events.count, events: events)
    }

    func testSessionSwitchWithPendingSnapshotSeedsOnlyTheNewSession() throws {
        // A: 0 user · 1 call (exit 2) · 2 result · 3 assistant → failed {1}.
        // B: 0 user · 1 call (exit 0) · 2 result · 3 assistant · 4 call (exit 2) · 5 result · 6 assistant → failed {4}.
        let a = codexSession("switch-a-\(UUID().uuidString)", [("k1", "make", 2)])
        let b = codexSession("switch-b-\(UUID().uuidString)", [("k1", "ls", 0), ("k2", "make test", 2)])
        let state = TranscriptDerivedState()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false, reviewCardsEnabled: true)
        func view(_ session: Session) -> TranscriptBlockListView {
            TranscriptBlockListView(derivedState: state, session: session, fontSize: 13,
                                    findMatchCount: .constant(0), findCurrentIndex: .constant(0),
                                    unifiedMatchCount: .constant(0), unifiedCurrentIndex: .constant(0))
        }
        state.update(session: a, settings: settings)
        spin { !state.isComputing }
        let host = NSHostingView(rootView: view(a))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func controller() -> BlockTableController? {
            var stack: [NSView] = [host]
            while let view = stack.popLast() {
                if let table = view as? NSTableView, let owner = table.delegate as? BlockTableController { return owner }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }
        spin { controller()?.rows.isEmpty == false }
        let table = try XCTUnwrap(controller())
        XCTAssertEqual(table.openInvocations, [1], "A's failed call opens by default")

        // B's snapshot is still computing when the view gets B: that pass must not take A's
        // blocks as B's.
        state.update(session: b, settings: settings)
        XCTAssertTrue(state.isComputing)
        host.rootView = view(b)
        host.layoutSubtreeIfNeeded()
        spin { !state.isComputing }
        spin { table.rows.count == 5 }
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(table.rows.map(\.id), [0, 1, 3, 4, 6])
        XCTAssertEqual(table.openInvocations, [4], "only B's failed call opens; A's id 1 is B's successful call")
        for row in table.rows {
            if case .toolInvocation(let model) = row.content {
                XCTAssertEqual(model.isOpen, model.invocationID == 4, "row \(model.invocationID)")
            }
        }
        window.close()
    }

    func testNativeCopyAndMenuCopyLeaveOutGutterAndFoldRows() throws {
        // Native ⌘C writes to the general pasteboard before the fix: keep the reader's text.
        let general = NSPasteboard.general
        let generalChange = general.changeCount
        let generalText = general.string(forType: .string)
        defer {
            if general.changeCount != generalChange, let generalText {
                general.clearContents()
                general.setString(generalText, forType: .string)
            }
        }
        let numbered = (1...300).map { String(format: "%6d→let v%d = %d", $0, $0, $0) }.joined(separator: "\n")
        let h = Harness([user(), read("t1", "/repo/Sources/App.swift"), output("t1", numbered), assistant()])
        let pasteboard = privatePasteboard()
        h.controller.toolPasteboard = pasteboard
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let storage = try XCTUnwrap(cell.bodyText.textStorage)
        let all = NSRange(location: 0, length: storage.length)
        XCTAssertNotNil(showAllLink(in: cell), "the body has a fold row")
        let expected = ToolDetailRenderer.copyText(of: storage, in: all)
        XCTAssertTrue(expected.contains("let v1 = 1"))

        // Native ⌘C on a body selection that covers gutter cells and the fold row.
        cell.bodyText.setSelectedRange(all)
        cell.bodyText.copy(nil)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, expected)
        XCTAssertFalse(copied.contains("Show all"))
        for line in copied.components(separatedBy: "\n") where line.contains("let v") {
            XCTAssertTrue(line.hasPrefix("let v"), "no gutter number: \(line.debugDescription)")
        }
        XCTAssertNil(pasteboard.data(forType: .rtf), "plain text only, no RTF with toolfold: links")
        XCTAssertNil(pasteboard.data(forType: .rtfd))

        // The context menu's Copy with the same selection.
        pasteboard.clearContents()
        let point = cell.bodyText.convert(NSPoint(x: 20, y: 5), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(cell.menu(for: event))
        perform(menuItem(menu, "Copy"), in: menu)
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func testGrowingOutputKeepsASelectionElsewhere() {
        // 0 user · 1 assistant · 2 c1 · 3 o1: rows [0, 1, 2].
        let h = Harness([user("first prompt"), assistant("an answer"), bash("t1", "make"), output("t1", "step 1")])
        XCTAssertEqual(h.rowIDs, [0, 1, 2])
        h.controller.setCrossBlockSelection(anchor: (0, 0), focus: (1, 4))
        XCTAssertTrue(h.controller.isCrossBlockSelectionActive)

        // The output grows (row 2 reloads in place): the selection over rows 0–1 stays.
        h.replace([user("first prompt"), assistant("an answer"), bash("t1", "make"), output("t1", "step 1\nstep 2")])
        XCTAssertTrue(h.controller.isCrossBlockSelectionActive, "the reloaded row is outside the selection")
        XCTAssertEqual(h.controller.assembleSelectedText(), "first prompt\n\nan a")

        // A selection that reaches the reloaded row is cleared.
        h.controller.setCrossBlockSelection(anchor: (1, 0), focus: (2, 2))
        h.replace([user("first prompt"), assistant("an answer"), bash("t1", "make"), output("t1", "step 1\nstep 2\nstep 3")])
        XCTAssertFalse(h.controller.isCrossBlockSelectionActive)
    }

    func testApplyTakesRowSummariesBuiltOffMain() throws {
        let blocks = F.sequence([user(), bash("t1", "make"), output("t1")])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)
        let ref = try XCTUnwrap(TranscriptToolRows.invocationRef(id: 1, in: index))
        var summary = ToolInvocationBuilder.rowSummary(ref, blocks: blocks, index: index, source: .claude)
        summary.actions[0].object = "built off main"
        let stamp = ToolSearchTextStore.contentStamp(of: ref, blocks: blocks)
        let entry = TranscriptDerivedState.RowSummaryEntry(stamp: stamp, status: ref.status, summary: summary)

        let h = Harness([user(), bash("t1", "make"), output("t1")], rowSummaries: [1: entry])
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertEqual(cell.lineAccessibilityLabels.first.map { $0.contains("built off main") }, true,
                       "the row shows the summary it was handed, with no parse on the main thread")

        // An entry built for other content (another stamp) is not used.
        var stale = entry
        stale.stamp &+= 1
        let fresh = Harness([user(), bash("t1", "make"), output("t1")], rowSummaries: [1: stale])
        let freshCell = try XCTUnwrap(fresh.view(id: 1, as: ToolInvocationCellView.self))
        XCTAssertEqual(freshCell.lineAccessibilityLabels.first.map { $0.contains("built off main") }, false)
        XCTAssertEqual(freshCell.lineAccessibilityLabels.first.map { $0.contains("make") }, true)
    }

    func testLongBodyGetsFileLinksFromAnOffMainScan() throws {
        let file = NSTemporaryDirectory() + "tool-links-\(UUID().uuidString).swift"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data("x\n".utf8)))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let lines = ["\(file):1: warning: unused value"] + (2...300).map { "compiled step \($0) of the module with options" }
        let h = Harness([user(), bash("t1", "make"), output("t1", lines.joined(separator: "\n"))])
        h.controller.toggleInvocation(invocationID: 1, allInGroup: false)
        XCTAssertTrue(h.waitForPresentations())
        let cell = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let link = try XCTUnwrap(showAllLink(in: cell))
        XCTAssertTrue(h.controller.textView(cell.bodyText, clickedOnLink: link.url, at: link.location))
        XCTAssertTrue(h.waitForPresentations())
        spin { h.controller.pendingToolBodyLinkScans == 0 }

        let shown = try XCTUnwrap(h.view(id: 1, as: ToolInvocationCellView.self))
        let storage = try XCTUnwrap(shown.bodyText.textStorage)
        XCTAssertGreaterThan(storage.length, BlockTableController.toolBodyInlineLinkifyLimit, "the long path")
        let path = (storage.string as NSString).range(of: file)
        XCTAssertNotEqual(path.location, NSNotFound)
        let payload = storage.attribute(.link, at: path.location, effectiveRange: nil) as? String
        XCTAssertEqual(payload.map { $0.contains("tool-links-") }, true, "the file path is a link once the scan ends")
    }

    func testFindUnderErrorsOnlyKeepsMatchesInShownFailedRows() {
        // 0 user · 1 c1 · 2 o1 (failed) · 3 assistant · 4 c2 · 5 o2 · 6 assistant
        let h = Harness([user(), bash("t1", "make"), output("t1", "needle failed", failed: true), assistant(),
                         bash("t2", "ls"), output("t2", "needle ok"), assistant()])
        h.activeRoleFilters = [.errors]
        h.reapply()
        XCTAssertEqual(h.rowIDs, [1], "only the failed invocation shows")
        let matches = [
            TranscriptDerivedState.BlockMatch(globalBlockIndex: 2, rangeInBlockText: NSRange(location: 0, length: 6), ordinal: 0),
            TranscriptDerivedState.BlockMatch(globalBlockIndex: 5, rangeInBlockText: NSRange(location: 0, length: 6), ordinal: 1),
        ]
        let counts = h.controller.applyFind(source: .local, query: "needle", matches: matches, token: 1, direction: 1,
                                            reset: true, shouldJump: false)
        XCTAssertEqual(counts.total, 1, "the failed row's match counts; the hidden row's does not")
    }

    func testFindWithErrorsOffKeepsMatchInPairedErrorOfShownInvocation() {
        // 0 user · 1 c1 · 2 .error carrying t1 (paired) · 3 assistant · 4 plain .error
        let h = Harness([user(), bash("t1", "rm x"),
                         F.block(.error, id: "t1", text: "Error: needle denied", isError: true, disposition: .runtimeError),
                         assistant(), F.block(.error, text: "needle plain", isError: true)])
        h.activeRoleFilters = [.user, .assistant, .tools]
        h.reapply()
        XCTAssertEqual(h.rowIDs, [0, 1, 3], "the invocation shows, the plain error does not")
        let matches = [
            TranscriptDerivedState.BlockMatch(globalBlockIndex: 2, rangeInBlockText: NSRange(location: 7, length: 6), ordinal: 0),
            TranscriptDerivedState.BlockMatch(globalBlockIndex: 4, rangeInBlockText: NSRange(location: 0, length: 6), ordinal: 1),
        ]
        let counts = h.controller.applyFind(source: .local, query: "needle", matches: matches, token: 1, direction: 1,
                                            reset: true, shouldJump: false)
        XCTAssertEqual(counts.total, 1, "the paired error is inside a shown invocation; the plain error is hidden")
    }
}
