import AppKit
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

        init(_ blocks: [Block], source: SessionSource = .claude, size: NSSize = NSSize(width: 640, height: 900)) {
            self.source = source
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

        private func apply() {
            let index = ToolInvocationIndex.build(blocks: blocks, source: source)
            var failed = Set<Int>()
            for invocation in index.invocations {
                if case .failed = invocation.status { failed.insert(invocation.id) }
            }
            controller.apply(allBlocks: blocks, invocationIndex: index, failedInvocationIDs: failed,
                             totalBlockCount: blocks.count, fontSize: 13, source: source, sessionID: sessionID)
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
}
