import Foundation

/// One verb of a group header's summary (spec §6.1 L0): an action verb key and how many of the
/// group's actions use it. A structured action's key is its display tool name; it counts as is.
struct VerbCount: Equatable {
    var verbKey: String
    var count: Int
}

/// The L0 header of a run of two or more tool invocations (spec §6.1).
struct ToolGroupHeaderModel: Equatable {
    /// The id of the group's first invocation in the loaded window. A group cut by the window edge
    /// takes its first loaded invocation's id, so loading older blocks can re-key it.
    var groupID: Int
    /// Calls as the agent made them: the number of invocations in the group.
    var callCount: Int
    /// The group's actions counted by `verbKey`, sorted by count (ties: first appearance), at most
    /// `TranscriptToolRows.verbDigestLimit` entries.
    var verbDigest: [VerbCount]
    /// Invocations of the group in `failedInvocationIDs`.
    var failedCount: Int
    /// Wall span from the group's first to its last timestamped member block (block order, loaded
    /// blocks only). Nil with fewer than 2 timestamps. A sum would overstate parallel calls.
    var durationSeconds: Double?
    /// The first timestamped member block's time.
    var timestamp: Date?
    var isOpen: Bool
    /// More distinct verbs than `verbDigest` holds: the view appends "…".
    var hasMoreVerbs: Bool = false
    /// The group's invocation ids, in row order (all of them, whatever the role filter shows).
    var invocationIDs: [Int] = []
}

/// Where an invocation row sits in its card: joined chrome for a group (spec §6.7).
enum CardPosition: Equatable {
    case solo, first, middle, last
}

/// One tool invocation row (spec §6.1 L1, with L2 below it when open).
struct ToolInvocationRowModel: Equatable {
    /// The call's `globalBlockIndex`, or the first output's when there is no call.
    var invocationID: Int
    /// The header's group id; nil for a lone invocation.
    var groupID: Int?
    var position: CardPosition
    var isOpen: Bool
    /// `TranscriptToolRows.contentStamp(memberCount:utf16Length:)` over the member blocks, so an
    /// arriving or growing output makes the row unequal and `classifyChange` reloads it.
    var contentStamp: Int
}

/// Row emission for tool blocks (spec §6.7): one table row per invocation plus a light header row
/// per group. Pure; no UI and no main-actor state.
enum TranscriptToolRows {
    typealias Block = SessionTranscriptBuilder.LogicalBlock

    /// Verbs a header digest holds before "…" (spec §6.1).
    static let verbDigestLimit = 3

    /// Row id of a group header: `Int.min / 2 + groupID`. Block rows use ids ≥ 0 and telemetry
    /// markers `-i - 1` (`BlockTableController.telemetryMarkerRowID`), so they never meet for any
    /// session shorter than 2^62 blocks.
    static func groupHeaderRowID(forGroup groupID: Int) -> Int {
        Int.min / 2 + groupID
    }

    /// The invocation with `id`. Binary search: `index.invocations` is in id order.
    static func invocationRef(id: Int, in index: ToolInvocationIndex) -> ToolInvocationRef? {
        let invocations = index.invocations
        var low = 0
        var high = invocations.count
        while low < high {
            let mid = (low + high) / 2
            if invocations[mid].id < id { low = mid + 1 } else { high = mid }
        }
        guard low < invocations.count, invocations[low].id == id else { return nil }
        return invocations[low]
    }

    /// A deterministic stamp of (member block count, total UTF-16 length of the loaded member
    /// blocks' text). Both inputs only grow while a session is live, and the stamp grows with
    /// each, so an output that arrives or grows always changes it.
    static func contentStamp(memberCount: Int, utf16Length: Int) -> Int {
        utf16Length &* 31 &+ memberCount
    }

    /// Rows for a window of blocks (spec §6.1, §6.7, §6.8), in one pass over `blocks`.
    ///
    /// - A run is a stretch of consecutive tool blocks: `.toolCall`, `.toolOut`, and any block in
    ///   `index.invocationIDByBlock` (paired `.error` blocks). A tool block missing from the index
    ///   is its own invocation (id = its index). Any other block, or a telemetry marker, ends the
    ///   run. Runs depend on the blocks only, never on the role filter, so a filter change does
    ///   not re-key groups.
    /// - Each invocation appears once, at its first member block in `blocks`. An invocation whose
    ///   call is before the window therefore sits at its first output; its row id is still the
    ///   invocation id, and `rowSummary` reads the call from the full block array.
    /// - A run with one invocation: one `.solo` row and no header. Two or more: a header (group
    ///   id = the first invocation's id) and, when the group is open, one row per shown
    ///   invocation, `first` / `middle` / `last` over the shown rows (`solo` when one shows).
    /// - Role filter: an invocation shows when `.tools` is active, or when `.errors` is active
    ///   and it failed. A header shows when any of its invocations shows; its counts cover the
    ///   whole group. An empty set shows everything, as in `rowsWithTelemetry`.
    /// - Every other block, and the telemetry markers, come out exactly as
    ///   `BlockTableController.rowsWithTelemetry` gives them.
    ///
    /// - Parameters:
    ///   - rowSummary: an invocation's L1 summary over the FULL block array (the controller passes
    ///     a cached closure). Called only for the invocations of each header that shows.
    ///   - markers: telemetry change lines by anchor block (`rowsWithTelemetry`'s `markers`).
    ///   - totalBlockCount: the full stream's length, for the trailing marker; nil skips it.
    static func emit(blocks: ArraySlice<Block>,
                     index: ToolInvocationIndex,
                     rowSummary: (ToolInvocationRef) -> ToolRowSummary,
                     openGroups: Set<Int>,
                     openInvocations: Set<Int>,
                     activeRoles: Set<TranscriptRoleFilter>,
                     failedInvocationIDs: Set<Int>,
                     markers: [Int: [String]] = [:],
                     totalBlockCount: Int? = nil) -> [BlockRowModel] {
        let context = Context(window: Window(blocks), openGroups: openGroups,
                              openInvocations: openInvocations, failedInvocationIDs: failedInvocationIDs,
                              activeRoles: activeRoles)
        var rows: [BlockRowModel] = []
        rows.reserveCapacity(blocks.count)
        var run: [ToolInvocationRef] = []
        var placed = Set<Int>()

        for block in blocks {
            let blockIndex = block.globalBlockIndex
            if let marker = telemetryMarkerRow(anchoredAt: blockIndex, markers: markers) {
                appendRun(&run, to: &rows, context: context, rowSummary: rowSummary)
                rows.append(marker)
            }
            if let id = index.invocationIDByBlock[blockIndex] ?? (block.kind.isTool ? blockIndex : nil) {
                if placed.insert(id).inserted {
                    run.append(invocationRef(id: id, in: index) ?? loneRef(id: id, block: block))
                }
                continue
            }
            appendRun(&run, to: &rows, context: context, rowSummary: rowSummary)
            let role = TranscriptRoleFilter.governing(block.kind)
            if activeRoles.isEmpty || role.map({ activeRoles.contains($0) }) ?? true {
                rows.append(BlockRowModel(id: blockIndex, content: .message(block)))
            }
        }
        appendRun(&run, to: &rows, context: context, rowSummary: rowSummary)

        if let totalBlockCount, blocks.last?.globalBlockIndex == totalBlockCount - 1,
           let marker = telemetryMarkerRow(anchoredAt: totalBlockCount, markers: markers) {
            rows.append(marker)
        }
        return rows
    }

    /// Default open state for groups the controller has not seen yet (spec §6.1): a group with a
    /// failed invocation starts open, and its failed invocations start open at L2. The controller
    /// calls this once per new group id and never reseeds after a user toggle.
    /// Group membership comes from `ToolGroupHeaderModel.invocationIDs`; `index` is not read.
    static func seedOpenState(newGroups: [ToolGroupHeaderModel], index _: ToolInvocationIndex,
                              failedInvocationIDs: Set<Int>) -> (groups: Set<Int>, invocations: Set<Int>) {
        var groups = Set<Int>()
        var invocations = Set<Int>()
        for header in newGroups {
            let failed = header.invocationIDs.filter { failedInvocationIDs.contains($0) }
            guard !failed.isEmpty else { continue }
            groups.insert(header.groupID)
            invocations.formUnion(failed)
        }
        return (groups, invocations)
    }

    // MARK: - Runs

    /// What one `emit` call needs to turn a run into rows.
    private struct Context {
        let window: Window
        let openGroups: Set<Int>
        let openInvocations: Set<Int>
        let failedInvocationIDs: Set<Int>
        let showsAllInvocations: Bool
        let showsFailedInvocations: Bool

        init(window: Window, openGroups: Set<Int>, openInvocations: Set<Int>,
             failedInvocationIDs: Set<Int>, activeRoles: Set<TranscriptRoleFilter>) {
            self.window = window
            self.openGroups = openGroups
            self.openInvocations = openInvocations
            self.failedInvocationIDs = failedInvocationIDs
            showsAllInvocations = activeRoles.isEmpty || activeRoles.contains(.tools)
            showsFailedInvocations = activeRoles.contains(.errors)
        }

        /// `TranscriptToolRows.showsInvocation`, with the role flags read once.
        func shows(_ id: Int) -> Bool {
            showsAllInvocations || (showsFailedInvocations && failedInvocationIDs.contains(id))
        }

        func row(_ ref: ToolInvocationRef, groupID: Int?, position: CardPosition) -> BlockRowModel {
            BlockRowModel(id: ref.id, content: .toolInvocation(ToolInvocationRowModel(
                invocationID: ref.id, groupID: groupID, position: position,
                isOpen: openInvocations.contains(ref.id), contentStamp: window.contentStamp(of: ref))))
        }
    }

    /// The role filter rule of `emit` for invocation `id`: it shows when `.tools` is active (or
    /// the set is empty), or when `.errors` is active and it failed. Find counts a match inside an
    /// invocation by this rule, never by the kind of the block that holds it.
    static func showsInvocation(_ id: Int, activeRoles: Set<TranscriptRoleFilter>,
                                failedInvocationIDs: Set<Int>) -> Bool {
        activeRoles.isEmpty || activeRoles.contains(.tools)
            || (activeRoles.contains(.errors) && failedInvocationIDs.contains(id))
    }

    /// Appends the rows of `run` and empties it.
    private static func appendRun(_ run: inout [ToolInvocationRef], to rows: inout [BlockRowModel],
                                  context: Context, rowSummary: (ToolInvocationRef) -> ToolRowSummary) {
        defer { run.removeAll(keepingCapacity: true) }
        if run.count == 1 {
            if context.shows(run[0].id) { rows.append(context.row(run[0], groupID: nil, position: .solo)) }
            return
        }
        let shown = run.filter { context.shows($0.id) }
        guard !shown.isEmpty else { return }
        let header = groupHeader(run, context: context, rowSummary: rowSummary)
        rows.append(BlockRowModel(id: groupHeaderRowID(forGroup: header.groupID), content: .toolGroupHeader(header)))
        guard header.isOpen else { return }
        for (offset, ref) in shown.enumerated() {
            rows.append(context.row(ref, groupID: header.groupID, position: position(at: offset, of: shown.count)))
        }
    }

    private static func groupHeader(_ run: [ToolInvocationRef], context: Context,
                                    rowSummary: (ToolInvocationRef) -> ToolRowSummary) -> ToolGroupHeaderModel {
        let groupID = run[0].id
        var counts: [VerbCount] = []
        var slotByVerb: [String: Int] = [:]
        var failedCount = 0
        var first: (block: Int, date: Date)?
        var last: (block: Int, date: Date)?
        var stamped = 0

        for ref in run {
            if context.failedInvocationIDs.contains(ref.id) { failedCount += 1 }
            for action in rowSummary(ref).actions {
                if let slot = slotByVerb[action.verbKey] {
                    counts[slot].count += 1
                } else {
                    slotByVerb[action.verbKey] = counts.count
                    counts.append(VerbCount(verbKey: action.verbKey, count: 1))
                }
            }
            ref.forEachMember { member in
                guard let date = context.window.timestamp(of: member) else { return }
                stamped += 1
                if first.map({ member < $0.block }) ?? true { first = (member, date) }
                if last.map({ member > $0.block }) ?? true { last = (member, date) }
            }
        }

        // Count descending; equal counts keep first appearance (explicit, as `sorted` is not
        // documented to be stable).
        let ranked = counts.indices.sorted { a, b in
            counts[a].count != counts[b].count ? counts[a].count > counts[b].count : a < b
        }
        var duration: Double?
        if stamped >= 2, let first, let last {
            duration = max(0, last.date.timeIntervalSince(first.date))
        }
        return ToolGroupHeaderModel(groupID: groupID,
                                    callCount: run.count,
                                    verbDigest: ranked.prefix(verbDigestLimit).map { counts[$0] },
                                    failedCount: failedCount,
                                    durationSeconds: duration,
                                    timestamp: first?.date,
                                    isOpen: context.openGroups.contains(groupID),
                                    hasMoreVerbs: counts.count > verbDigestLimit,
                                    invocationIDs: run.map(\.id))
    }

    private static func position(at offset: Int, of count: Int) -> CardPosition {
        if count == 1 { return .solo }
        if offset == 0 { return .first }
        return offset == count - 1 ? .last : .middle
    }

    /// A tool block the index does not know: an invocation of that block alone.
    private static func loneRef(id: Int, block: Block) -> ToolInvocationRef {
        let isCall = block.kind == .toolCall
        return ToolInvocationRef(id: id, callBlockIndex: isCall ? block.globalBlockIndex : nil,
                                 outputBlockIndices: isCall ? [] : [block.globalBlockIndex], status: .unknown)
    }

    /// The display-only marker row above block `index`, as `BlockTableController.rowsWithTelemetry`
    /// builds it (id `-index - 1`). Task 13 makes `rowsWithTelemetry` call `emit`, which leaves
    /// this the only copy.
    private static func telemetryMarkerRow(anchoredAt index: Int, markers: [Int: [String]]) -> BlockRowModel? {
        guard let lines = markers[index], !lines.isEmpty else { return nil }
        let block = Block(kind: .meta, text: lines.joined(separator: "\n"), timestamp: nil,
                          messageID: nil, toolName: nil, isDelta: false, toolInput: nil,
                          isErrorOutput: false, eventID: "telemetry-change-\(index)", rawJSON: "",
                          globalBlockIndex: -index - 1)
        return BlockRowModel(id: block.globalBlockIndex, content: .message(block))
    }

    // MARK: - Window

    /// Reads member blocks of the loaded window by global index. A window is a contiguous slice
    /// of the full stream, so a block sits at `startIndex + (globalIndex - first globalIndex)`;
    /// each lookup checks the block's own index, so another layout reads as "not loaded".
    private struct Window {
        let blocks: ArraySlice<Block>
        let firstGlobalIndex: Int

        init(_ blocks: ArraySlice<Block>) {
            self.blocks = blocks
            firstGlobalIndex = blocks.first?.globalBlockIndex ?? 0
        }

        private func position(of globalIndex: Int) -> Int? {
            let position = blocks.startIndex + (globalIndex - firstGlobalIndex)
            guard position >= blocks.startIndex, position < blocks.endIndex,
                  blocks[position].globalBlockIndex == globalIndex else { return nil }
            return position
        }

        func timestamp(of globalIndex: Int) -> Date? {
            position(of: globalIndex).flatMap { blocks[$0].timestamp }
        }

        func contentStamp(of ref: ToolInvocationRef) -> Int {
            var length = 0
            ref.forEachMember { member in
                if let position = position(of: member) { length += blocks[position].text.utf16.count }
            }
            return TranscriptToolRows.contentStamp(memberCount: ref.memberCount, utf16Length: length)
        }
    }
}

private extension ToolInvocationRef {
    var memberCount: Int { (callBlockIndex == nil ? 0 : 1) + outputBlockIndices.count }

    func forEachMember(_ body: (Int) -> Void) {
        if let callBlockIndex { body(callBlockIndex) }
        for output in outputBlockIndices { body(output) }
    }
}
