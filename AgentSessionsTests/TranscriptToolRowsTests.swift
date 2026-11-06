import XCTest
@testable import AgentSessions

/// Task 12: `TranscriptToolRows.emit` turns a window of blocks into group-header rows and one row
/// per invocation (spec §6.1, §6.7, §6.8), and `seedOpenState` opens groups with a failure.
/// `classifyChange` / `prependDiff` over these rows are in `TranscriptBlockWindowingTests`.
final class TranscriptToolRowsTests: XCTestCase {
    private typealias F = TranscriptTestFixtures
    private typealias Block = SessionTranscriptBuilder.LogicalBlock

    /// A full session stream, its pairing index and its failed invocations.
    private struct Built {
        var blocks: [Block]
        var index: ToolInvocationIndex
        var failed: Set<Int>
        var source: SessionSource

        func summary(_ ref: ToolInvocationRef) -> ToolRowSummary {
            ToolInvocationBuilder.rowSummary(ref, blocks: blocks, index: index, source: source)
        }

        func rows(_ window: ClosedRange<Int>? = nil,
                  openGroups: Set<Int> = [],
                  openInvocations: Set<Int> = [],
                  roles: Set<TranscriptRoleFilter> = Set(TranscriptRoleFilter.allCases),
                  markers: [Int: [String]] = [:]) -> [BlockRowModel] {
            TranscriptToolRows.emit(blocks: window.map { blocks[$0] } ?? blocks[...],
                                    index: index,
                                    rowSummary: { summary($0) },
                                    openGroups: openGroups,
                                    openInvocations: openInvocations,
                                    activeRoles: roles,
                                    failedInvocationIDs: failed,
                                    markers: markers,
                                    totalBlockCount: blocks.count)
        }
    }

    private func built(_ blocks: [Block], source: SessionSource = .claude) -> Built {
        let stream = F.sequence(blocks)
        let index = ToolInvocationIndex.build(blocks: stream, source: source)
        var failed = Set<Int>()
        for invocation in index.invocations {
            if case .failed = invocation.status { failed.insert(invocation.id) }
        }
        return Built(blocks: stream, index: index, failed: failed, source: source)
    }

    private func json(_ object: [String: Any]) -> String {
        ToolJSON.string(from: object, pretty: false) ?? "{}"
    }

    private func bash(_ id: String, _ command: String, at offset: Double? = nil) -> Block {
        F.block(.toolCall, id: id, toolName: "Bash", toolInput: json(["command": command]), at: offset)
    }

    private func read(_ id: String, _ path: String, at offset: Double? = nil) -> Block {
        F.block(.toolCall, id: id, toolName: "Read", toolInput: json(["file_path": path]), at: offset)
    }

    private func grep(_ id: String, _ pattern: String) -> Block {
        F.block(.toolCall, id: id, toolName: "Grep", toolInput: json(["pattern": pattern]))
    }

    private func output(_ id: String, _ text: String = "ok", failed: Bool = false,
                        at offset: Double? = nil) -> Block {
        F.block(.toolOut, id: id, text: text, isError: failed, at: offset)
    }

    private func user(_ text: String = "go") -> Block { F.block(.user, text: text) }
    private func assistant(_ text: String = "done") -> Block { F.block(.assistant, text: text) }

    private func header(_ row: BlockRowModel) -> ToolGroupHeaderModel? {
        if case .toolGroupHeader(let model) = row.content { return model }
        return nil
    }

    private func invocation(_ row: BlockRowModel) -> ToolInvocationRowModel? {
        if case .toolInvocation(let model) = row.content { return model }
        return nil
    }

    private func hid(_ group: Int) -> Int { TranscriptToolRows.groupHeaderRowID(forGroup: group) }

    // MARK: - Runs and groups

    func testSoloInvocationHasNoHeader() throws {
        // 0 user · 1 c1 · 2 o1 · 3 assistant
        let s = built([user(), bash("t1", "make"), output("t1"), assistant()])
        let rows = s.rows()

        XCTAssertEqual(rows.map(\.id), [0, 1, 3])
        XCTAssertEqual(rows[0].content, .message(s.blocks[0]))
        XCTAssertEqual(rows[2].content, .message(s.blocks[3]))
        XCTAssertFalse(rows.contains { header($0) != nil })
        let row = try XCTUnwrap(invocation(rows[1]))
        XCTAssertEqual(row.invocationID, 1)
        XCTAssertNil(row.groupID)
        XCTAssertEqual(row.position, .solo)
        XCTAssertFalse(row.isOpen)
        XCTAssertTrue(rows[1].isToolRow)
        XCTAssertFalse(rows[0].isToolRow)

        XCTAssertEqual(invocation(s.rows(openInvocations: [1])[1])?.isOpen, true)
    }

    func testClosedGroupEmitsHeaderOnly() throws {
        // 0 user · 1 Read a · 2 out · 3 Grep · 4 out · 5 Read b · 6 out · 7 Bash · 8 out · 9 MCP · 10 out · 11 assistant
        let s = built([
            user(),
            read("t1", "/src/a.swift", at: 100), output("t1"),
            grep("t2", "TODO"), output("t2", at: 103),
            read("t3", "/src/b.swift"), output("t3"),
            bash("t4", "make"), output("t4"),
            F.block(.toolCall, id: "t5", toolName: "mcp__x__y", toolInput: json(["q": "1"])),
            output("t5", at: 112.5),
            assistant(),
        ])
        let rows = s.rows()

        XCTAssertEqual(rows.map(\.id), [0, hid(1), 11])
        let model = try XCTUnwrap(header(rows[1]))
        XCTAssertEqual(model.groupID, 1)
        XCTAssertEqual(model.callCount, 5)
        XCTAssertEqual(model.invocationIDs, [1, 3, 5, 7, 9])
        // Sorted by count; ties keep first appearance; at most three, and the fourth verb sets hasMoreVerbs.
        XCTAssertEqual(model.verbDigest, [VerbCount(verbKey: "tool.verb.read", count: 2),
                                          VerbCount(verbKey: "tool.verb.searched", count: 1),
                                          VerbCount(verbKey: "tool.verb.ran", count: 1)])
        XCTAssertTrue(model.hasMoreVerbs)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertEqual(model.durationSeconds, 12.5)
        XCTAssertEqual(model.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(rows[1].isToolRow)
    }

    func testOpenGroupEmitsRowsWithPositions() {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 c3 · 6 o3 · 7 assistant · 8 c4 · 9 o4 · 10 Read · 11 o5
        let s = built([
            user(),
            bash("t1", "make"), output("t1"), bash("t2", "make test"), output("t2"),
            bash("t3", "make lint"), output("t3"),
            assistant(),
            bash("t4", "make"), output("t4"), read("t5", "/src/c.swift"), output("t5"),
        ])
        let rows = s.rows(openGroups: [1, 8], openInvocations: [3])

        XCTAssertEqual(rows.map(\.id), [0, hid(1), 1, 3, 5, 7, hid(8), 8, 10])
        XCTAssertEqual(header(rows[1])?.isOpen, true)
        XCTAssertEqual(rows[2...4].compactMap { invocation($0)?.position }, [.first, .middle, .last])
        XCTAssertEqual(rows[2...4].compactMap { invocation($0)?.groupID }, [1, 1, 1])
        XCTAssertEqual(rows[2...4].compactMap { invocation($0)?.isOpen }, [false, true, false])
        // A two-row group is first + last.
        XCTAssertEqual(rows[7...8].compactMap { invocation($0)?.position }, [.first, .last])
        XCTAssertEqual(rows[7...8].compactMap { invocation($0)?.groupID }, [8, 8])
        XCTAssertEqual(header(rows[6])?.verbDigest.map(\.count), [1, 1])
        XCTAssertEqual(header(rows[6])?.hasMoreVerbs, false)
        // No timestamps: no duration and no time.
        XCTAssertNil(header(rows[1])?.durationSeconds)
        XCTAssertNil(header(rows[1])?.timestamp)

        // One timestamp is not a span.
        let one = built([user(), bash("t1", "make", at: 50), output("t1"), bash("t2", "make"), output("t2")])
        XCTAssertNil(header(one.rows()[1])?.durationSeconds)
        XCTAssertEqual(header(one.rows()[1])?.timestamp, Date(timeIntervalSince1970: 50))
    }

    func testFailedGroupSeedsOpen() throws {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 runtime .error for c2 · 5 c3 · 6 o3 · 7 assistant · 8 c4 · 9 o4 · 10 c5 · 11 o5
        let s = built([
            user(),
            bash("t1", "make"), output("t1"),
            bash("t2", "make test"),
            F.block(.error, id: "t2", text: "Error: permission denied", isError: true, disposition: .runtimeError),
            bash("t3", "make lint"), output("t3"),
            assistant(),
            bash("t4", "ls"), output("t4"), bash("t5", "pwd"), output("t5"),
        ])
        XCTAssertEqual(s.failed, [3])

        let closed = s.rows()
        // The paired `.error` block is part of the run, not its own error row.
        XCTAssertEqual(closed.map(\.id), [0, hid(1), 7, hid(8)])
        let headers = closed.compactMap(header)
        XCTAssertEqual(headers.map(\.failedCount), [1, 0])

        let seeded = TranscriptToolRows.seedOpenState(newGroups: headers, index: s.index,
                                                      failedInvocationIDs: s.failed)
        XCTAssertEqual(seeded.groups, [1])
        XCTAssertEqual(seeded.invocations, [3])

        let open = s.rows(openGroups: seeded.groups, openInvocations: seeded.invocations)
        XCTAssertEqual(open.map(\.id), [0, hid(1), 1, 3, 5, 7, hid(8)])
        XCTAssertEqual(open[2...4].compactMap { invocation($0)?.isOpen }, [false, true, false])

        // Nothing failed: nothing to seed.
        let none = TranscriptToolRows.seedOpenState(newGroups: [headers[1]], index: s.index,
                                                    failedInvocationIDs: s.failed)
        XCTAssertTrue(none.groups.isEmpty)
        XCTAssertTrue(none.invocations.isEmpty)
    }

    // MARK: - ▲▼ jump stops (Task 16, spec §6.8)

    func testToolJumpStepsPerInvocation() {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 · 5 assistant · 6 c3 (no output yet)
        let s = built([user(), bash("t1", "make"), output("t1"), bash("t2", "ls"), output("t2"),
                       assistant(), bash("t3", "pwd")])
        let ids = TranscriptDerivedState.jumpIDs(blocks: s.blocks, index: s.index, failedInvocationIDs: s.failed)
        XCTAssertEqual(ids.tools, [1, 3, 6], "one stop per invocation, never per call or output block")
    }

    func testErrorJumpIncludesFailedInvocations() {
        // 0 user · 1 c1 · 2 o1 ✗ · 3 c2 · 4 o2 · 5 plain .error · 6 c3 · 7 o3 ✗
        let s = built([user(), bash("t1", "make"), output("t1", "boom", failed: true),
                       bash("t2", "ls"), output("t2"),
                       F.block(.error, text: "plain error", isError: true),
                       bash("t3", "make"), output("t3", "boom", failed: true)])
        XCTAssertEqual(s.failed, [1, 6])
        let ids = TranscriptDerivedState.jumpIDs(blocks: s.blocks, index: s.index, failedInvocationIDs: s.failed)
        XCTAssertEqual(ids.errors, [1, 5, 6], "failed invocations and unpaired error blocks, ascending")
    }

    func testRuntimeErrorBlockIsOneErrorStop() {
        // 0 user · 1 c1 · 2 paired runtime .error for c1
        let s = built([user(), bash("t1", "make"),
                       F.block(.error, id: "t1", text: "Error: permission denied", isError: true,
                               disposition: .runtimeError)])
        XCTAssertEqual(s.failed, [1])
        let ids = TranscriptDerivedState.jumpIDs(blocks: s.blocks, index: s.index, failedInvocationIDs: s.failed)
        XCTAssertEqual(ids.errors, [1], "the paired error block is the invocation's failure, not a second stop")
        XCTAssertEqual(ids.tools, [1])
    }

    func testErrorsOnlyFilterShowsFailedInvocations() {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 ✗ · 5 c3 · 6 o3 · 7 assistant · 8 c4 · 9 o4 · 10 c5 · 11 o5 ·
        // 12 user · 13 c6 · 14 o6 ✗ · 15 assistant · 16 c7 · 17 o7 · 18 plain .error
        let s = built([
            user(),
            bash("t1", "make"), output("t1"), bash("t2", "make test"), output("t2", "boom", failed: true),
            bash("t3", "make lint"), output("t3"),
            assistant(),
            bash("t4", "ls"), output("t4"), bash("t5", "pwd"), output("t5"),
            user("again"),
            bash("t6", "make"), output("t6", "boom", failed: true),
            assistant(),
            bash("t7", "ls"), output("t7"),
            F.block(.error, text: "plain error", isError: true),
        ])
        XCTAssertEqual(s.failed, [3, 13])

        // Group 1 shows its header and only its failed row; group 8 has no failure and hides; the
        // failed solo row shows; the plain error block shows as today.
        let errorsOnly = s.rows(openGroups: [1, 8], roles: [.errors])
        XCTAssertEqual(errorsOnly.map(\.id), [hid(1), 3, 13, 18])
        XCTAssertEqual(invocation(errorsOnly[1])?.position, .solo)
        XCTAssertEqual(invocation(errorsOnly[1])?.groupID, 1)
        XCTAssertEqual(header(errorsOnly[0])?.callCount, 3, "the header still counts the whole group")
        XCTAssertEqual(s.rows(roles: [.errors]).map(\.id), [hid(1), 13, 18])

        // Tools and errors off: no tool rows at all.
        XCTAssertEqual(s.rows(openGroups: [1, 8], roles: [.user, .assistant]).map(\.id), [0, 7, 12, 15])

        // Tools only: every tool row. A hidden message still ends a run, so the groups stay apart.
        XCTAssertEqual(s.rows(roles: [.tools]).map(\.id), [hid(1), hid(8), 13, 16])

        // All roles, and the empty set (no filter), show everything.
        let all = s.rows(openGroups: [1, 8])
        XCTAssertEqual(all.map(\.id), [0, hid(1), 1, 3, 5, 7, hid(8), 8, 10, 12, 13, 15, 16, 18])
        XCTAssertEqual(s.rows(openGroups: [1, 8], roles: []), all)
    }

    @MainActor
    func testHeaderRowIDNeverCollides() {
        var headerIDs = Set<Int>()
        for group in 0...10_000 {
            XCTAssertTrue(headerIDs.insert(TranscriptToolRows.groupHeaderRowID(forGroup: group)).inserted)
        }
        let blockIDs = Set(0...10_000)
        let telemetryIDs = Set((0...10_001).map { BlockTableController.telemetryMarkerRowID(forBlock: $0) })
        XCTAssertTrue(headerIDs.isDisjoint(with: blockIDs))
        XCTAssertTrue(headerIDs.isDisjoint(with: telemetryIDs))
        // Far below every telemetry id, even for a huge session.
        XCTAssertLessThan(TranscriptToolRows.groupHeaderRowID(forGroup: 50_000_000),
                          BlockTableController.telemetryMarkerRowID(forBlock: 50_000_000))
    }

    func testCallOutsideWindowStillEmitsCompleteRow() throws {
        // 0 user · 1 Bash "git status" · 2 o1 · 3 assistant — the window starts at the output.
        let s = built([user(), bash("t1", "git status"), output("t1", "clean"), assistant()])
        let rows = s.rows(2...3)

        XCTAssertEqual(rows.map(\.id), [1, 3])
        let row = try XCTUnwrap(invocation(rows[0]))
        XCTAssertEqual(row.invocationID, 1)
        XCTAssertEqual(row.position, .solo)
        let ref = try XCTUnwrap(TranscriptToolRows.invocationRef(id: row.invocationID, in: s.index))
        XCTAssertEqual(ref.callBlockIndex, 1)
        let action = try XCTUnwrap(s.summary(ref).actions.first)
        XCTAssertEqual(action.object, "git status")
        XCTAssertEqual(action.verbKey, "tool.verb.ran")

        // A group cut by the window edge: 0 user · 1 c1 · 2 c2 · 3 o1 · 4 o2 · 5 c3 · 6 o3.
        // From block 3 the calls of 1 and 2 are outside; the group takes its first loaded
        // invocation's id and the digest still reads the calls ("Ran", not "Output").
        let cut = built([user(), bash("t1", "make"), bash("t2", "make test"), output("t1"), output("t2"),
                         bash("t3", "make lint"), output("t3")])
        let cutRows = cut.rows(3...6, openGroups: [1])
        XCTAssertEqual(cutRows.map(\.id), [hid(1), 1, 2, 5])
        XCTAssertEqual(header(cutRows[0])?.verbDigest, [VerbCount(verbKey: "tool.verb.ran", count: 3)])
        XCTAssertEqual(header(cutRows[0])?.invocationIDs, [1, 2, 5])
    }

    // MARK: - Details

    @MainActor
    func testNonToolRowsMatchRowsWithTelemetry() {
        // 0 user · 1 assistant · 2 plain .error · 3 meta · 4 user
        let s = built([user("a"), assistant("b"), F.block(.error, text: "plain", isError: true),
                       F.block(.meta, text: "m"), user("c")])
        let markers = [0: ["Before"], 2: ["During"], 5: ["After"]]
        let roleSets: [Set<TranscriptRoleFilter>] = [Set(TranscriptRoleFilter.allCases), [], [.user],
                                                     [.errors, .assistant], [.tools]]
        for roles in roleSets {
            for window in [0...4, 2...4, 0...1] {
                let expected = referenceRows(s.blocks[window], markers: markers, totalBlockCount: 5, roles: roles)
                XCTAssertEqual(s.rows(window, roles: roles, markers: markers), expected, "\(roles) \(window)")
                // The Session view's rows are `emit` (Task 13), so the controller's entry point agrees too.
                XCTAssertEqual(BlockTableController.rowsWithTelemetry(from: s.blocks[window], markers: markers,
                                                                      totalBlockCount: 5, activeRoles: roles,
                                                                      index: s.index, failedInvocationIDs: s.failed),
                               expected, "\(roles) \(window)")
            }
        }
    }

    /// The pre-Task-13 message-row emission (`rowsWithTelemetry` before it called `emit`): one row
    /// per block that the role filter shows, a marker row (id `-i - 1`) above block `i`, and the
    /// trailing marker after the stream's last block. Kept here as the reference for non-tool rows.
    private func referenceRows(_ blocks: ArraySlice<Block>, markers: [Int: [String]], totalBlockCount: Int,
                               roles: Set<TranscriptRoleFilter>) -> [BlockRowModel] {
        var rows: [BlockRowModel] = []
        func appendMarker(at index: Int) {
            guard let lines = markers[index], !lines.isEmpty else { return }
            let block = Block(kind: .meta, text: lines.joined(separator: "\n"), timestamp: nil,
                              messageID: nil, toolName: nil, isDelta: false, toolInput: nil,
                              isErrorOutput: false, eventID: "telemetry-change-\(index)", rawJSON: "",
                              globalBlockIndex: -index - 1)
            rows.append(BlockRowModel(id: block.globalBlockIndex, content: .message(block)))
        }
        for block in blocks {
            appendMarker(at: block.globalBlockIndex)
            let role = TranscriptRoleFilter.governing(block.kind)
            if roles.isEmpty || role.map({ roles.contains($0) }) ?? true {
                rows.append(BlockRowModel(id: block.globalBlockIndex, content: .message(block)))
            }
        }
        if blocks.last?.globalBlockIndex == totalBlockCount - 1 { appendMarker(at: totalBlockCount) }
        return rows
    }

    func testTelemetryMarkerSplitsRun() {
        // 0 user · 1 c1 · 2 o1 · 3 c2 · 4 o2 — a marker above block 3 ends the run.
        let s = built([user(), bash("t1", "make"), output("t1"), bash("t2", "make test"), output("t2")])
        let rows = s.rows(markers: [3: ["Model changed"]])

        XCTAssertEqual(rows.map(\.id), [0, 1, -4, 3])
        XCTAssertEqual(invocation(rows[1])?.position, .solo)
        XCTAssertEqual(invocation(rows[3])?.position, .solo)
        XCTAssertTrue(rows[2].isMeta)
    }

    func testInvocationAppearsOnceAcrossRuns() {
        // 0 user · 1 c1 · 2 assistant · 3 o1 · 4 c2 · 5 o2 — o1 lies in a later run; its invocation is
        // already placed at the call, so the second run holds only invocation 4.
        let s = built([user(), bash("t1", "make"), assistant(), output("t1"), bash("t2", "ls"), output("t2")])
        let rows = s.rows()

        XCTAssertEqual(rows.map(\.id), [0, 1, 2, 4])
        XCTAssertEqual(invocation(rows[1])?.position, .solo)
        XCTAssertEqual(invocation(rows[3])?.position, .solo)
    }

    func testContentStampChangesWhenOutputArrivesOrGrows() throws {
        let base = [user(), bash("t1", "make")]
        let pending = try XCTUnwrap(invocation(built(base).rows()[1]))
        let arrived = try XCTUnwrap(invocation(built(base + [output("t1", "ok")]).rows()[1]))
        let grown = try XCTUnwrap(invocation(built(base + [output("t1", "ok, all done")]).rows()[1]))
        let again = try XCTUnwrap(invocation(built(base + [output("t1", "ok")]).rows()[1]))

        XCTAssertNotEqual(pending.contentStamp, arrived.contentStamp)
        XCTAssertNotEqual(arrived.contentStamp, grown.contentStamp)
        XCTAssertEqual(arrived, again, "same blocks, same row")
    }

    func testToolBlockMissingFromIndexIsItsOwnInvocation() {
        // Without an index every tool block is its own invocation (a caller that passes `.empty`).
        let blocks = F.sequence([user(), bash("t1", "make"), output("t1"), assistant()])
        let rows = TranscriptToolRows.emit(blocks: blocks[...], index: .empty,
                                           rowSummary: { _ in ToolRowSummary(actions: [], chips: []) },
                                           openGroups: [1], openInvocations: [],
                                           activeRoles: Set(TranscriptRoleFilter.allCases),
                                           failedInvocationIDs: [])

        XCTAssertEqual(rows.map(\.id), [0, hid(1), 1, 2, 3])
        XCTAssertEqual(header(rows[1])?.callCount, 2)
        XCTAssertEqual(header(rows[1])?.verbDigest, [])
    }
}
