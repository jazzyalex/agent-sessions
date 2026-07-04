import XCTest
@testable import AgentSessions

/// Parity tests for `SessionRowsBuilder` (W3 Task 2): the extracted pure builder
/// must produce byte-identical output to the legacy synchronous computation that
/// lived inline in `UnifiedSessionsView.updateCachedRows()` before extraction.
///
/// `legacyBuild` below is a verbatim port of that pre-extraction logic (hierarchy
/// build -> isLargeReorder -> side-chat contexts -> row-derived sets), used here
/// purely as the oracle. It intentionally duplicates `SessionRowsBuilder.build`
/// rather than calling it, so a future accidental behavior change inside
/// `SessionRowsBuilder` shows up as a test failure instead of the oracle silently
/// tracking it.
final class SessionRowsBuilderTests: XCTestCase {

    // MARK: - Oracle (legacy inline logic, ported verbatim)

    private struct LegacyOutput: Equatable {
        let cachedRowIDs: [String]
        let hierarchyDepths: [String: Int]
        let hierarchyHasChildren: [String: Bool]
        let sideChatParentContextByID: [String: String]
        let cachedVisibleRowIDs: Set<String>
        let cachedExpandableParentIDs: Set<String>
        let isLargeReorder: Bool
    }

    private static func legacyBuild(
        nextRows: [Session],
        allSessions: [Session],
        previousCachedRows: [Session],
        collapsedParents: Set<String>,
        showSubagentHierarchy: Bool,
        searchActive: Bool,
        isHierarchyBrowsing: Bool
    ) -> LegacyOutput {
        let hierarchyResult = SubagentHierarchyBuilder.build(
            sessions: nextRows,
            collapsedParents: collapsedParents,
            hierarchyEnabled: showSubagentHierarchy && !searchActive
        )
        let newRows = hierarchyResult.sessions

        let isLargeReorder = UnifiedTableIdentityPolicy.isLargeReorder(old: previousCachedRows, new: newRows)

        let sideChatParentContextByID = UnifiedSessionsView.sideChatParentContexts(
            for: newRows,
            allSessions: allSessions
        )

        let cachedRowIDs = newRows.map(\.id)
        let cachedVisibleRowIDs = Set(cachedRowIDs)

        let cachedExpandableParentIDs: Set<String>
        if isHierarchyBrowsing {
            cachedExpandableParentIDs = Set(newRows.compactMap { session in
                hierarchyResult.rowMeta[session.id]?.hasChildren == true ? session.id : nil
            })
        } else {
            cachedExpandableParentIDs = []
        }

        var depths: [String: Int] = [:]
        var hasChildren: [String: Bool] = [:]
        for (id, meta) in hierarchyResult.rowMeta {
            depths[id] = meta.depth
            hasChildren[id] = meta.hasChildren
        }

        return LegacyOutput(
            cachedRowIDs: cachedRowIDs,
            hierarchyDepths: depths,
            hierarchyHasChildren: hasChildren,
            sideChatParentContextByID: sideChatParentContextByID,
            cachedVisibleRowIDs: cachedVisibleRowIDs,
            cachedExpandableParentIDs: cachedExpandableParentIDs,
            isLargeReorder: isLargeReorder
        )
    }

    private func assertParity(
        nextRows: [Session],
        allSessions: [Session],
        previousCachedRows: [Session],
        collapsedParents: Set<String>,
        showSubagentHierarchy: Bool,
        searchActive: Bool,
        isHierarchyBrowsing: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = Self.legacyBuild(
            nextRows: nextRows,
            allSessions: allSessions,
            previousCachedRows: previousCachedRows,
            collapsedParents: collapsedParents,
            showSubagentHierarchy: showSubagentHierarchy,
            searchActive: searchActive,
            isHierarchyBrowsing: isHierarchyBrowsing
        )

        let input = SessionRowsBuilder.RowsInput(
            nextRows: nextRows,
            allSessions: allSessions,
            previousCachedRows: previousCachedRows,
            collapsedParents: collapsedParents,
            showSubagentHierarchy: showSubagentHierarchy,
            searchActive: searchActive,
            isHierarchyBrowsing: isHierarchyBrowsing,
            presences: [],
            directJoinFallbackKeys: []
        )
        let actual = SessionRowsBuilder.build(input: input)

        XCTAssertEqual(actual.cachedRowIDs, expected.cachedRowIDs, "row order/membership", file: file, line: line)
        XCTAssertEqual(actual.cachedVisibleRowIDs, expected.cachedVisibleRowIDs, "visible id set", file: file, line: line)
        XCTAssertEqual(actual.cachedExpandableParentIDs, expected.cachedExpandableParentIDs, "expandable parents", file: file, line: line)
        XCTAssertEqual(actual.isLargeReorder, expected.isLargeReorder, "large-reorder flag", file: file, line: line)
        XCTAssertEqual(actual.sideChatParentContextByID, expected.sideChatParentContextByID, "side-chat contexts", file: file, line: line)

        for (id, depth) in expected.hierarchyDepths {
            XCTAssertEqual(actual.hierarchyRowMeta[id]?.depth, depth, "depth for \(id)", file: file, line: line)
        }
        for (id, hasChildren) in expected.hierarchyHasChildren {
            XCTAssertEqual(actual.hierarchyRowMeta[id]?.hasChildren, hasChildren, "hasChildren for \(id)", file: file, line: line)
        }
        XCTAssertEqual(actual.hierarchyRowMeta.count, expected.hierarchyDepths.count, "rowMeta key set", file: file, line: line)

        // cachedRowByID is new (not in the legacy oracle) — verify its own
        // invariant: exactly one entry per row, keyed correctly.
        XCTAssertEqual(actual.cachedRowByID.count, actual.cachedRows.count, "cachedRowByID size", file: file, line: line)
        for row in actual.cachedRows {
            XCTAssertEqual(actual.cachedRowByID[row.id]?.id, row.id, "cachedRowByID[\(row.id)]", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private func makeSession(
        id: String,
        source: SessionSource = .codex,
        modifiedAt: Date,
        cwd: String? = nil,
        parentSessionID: String? = nil,
        subagentType: String? = nil,
        relationshipKind: SessionRelationshipKind? = nil,
        codexInternalSessionIDHint: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: source,
            startTime: modifiedAt,
            endTime: modifiedAt,
            model: "test-model",
            filePath: "/tmp/\(id).jsonl",
            fileSizeBytes: 1024,
            eventCount: 1,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: "Session \(id)",
            codexInternalSessionIDHint: codexInternalSessionIDHint,
            parentSessionID: parentSessionID,
            subagentType: subagentType,
            relationshipKind: relationshipKind
        )
    }

    // MARK: - Tests

    func testFlatSessionsNoHierarchy() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<10).map { i in
            makeSession(id: "s\(i)", modifiedAt: base.addingTimeInterval(Double(i)))
        }
        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: false,
            searchActive: false,
            isHierarchyBrowsing: false
        )
    }

    func testHierarchyWithChildrenExpanded() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeSession(id: "parent-1", modifiedAt: base)
        let child1 = makeSession(id: "child-1", modifiedAt: base.addingTimeInterval(1), parentSessionID: "parent-1", subagentType: "review")
        let child2 = makeSession(id: "child-2", modifiedAt: base.addingTimeInterval(2), parentSessionID: "parent-1", subagentType: "explore")
        let other = makeSession(id: "other-1", modifiedAt: base.addingTimeInterval(3))
        let rows = [parent, other, child1, child2]

        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: true,
            searchActive: false,
            isHierarchyBrowsing: true
        )
    }

    func testHierarchyWithCollapsedParent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeSession(id: "parent-1", modifiedAt: base)
        let child = makeSession(id: "child-1", modifiedAt: base.addingTimeInterval(1), parentSessionID: "parent-1")
        let rows = [parent, child]

        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: rows,
            collapsedParents: ["parent-1"],
            showSubagentHierarchy: true,
            searchActive: false,
            isHierarchyBrowsing: true
        )
    }

    func testHierarchySuppressedDuringSearch() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeSession(id: "parent-1", modifiedAt: base)
        let child = makeSession(id: "child-1", modifiedAt: base.addingTimeInterval(1), parentSessionID: "parent-1")
        let rows = [parent, child]

        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: true,
            searchActive: true,
            isHierarchyBrowsing: false
        )
    }

    func testSideChatParentContextResolution() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeSession(id: "parent-1", source: .claude, modifiedAt: base)
        let sideChat = makeSession(
            id: "side-1",
            source: .claude,
            modifiedAt: base.addingTimeInterval(1),
            parentSessionID: "parent-1",
            relationshipKind: .sideChat
        )
        let rows = [parent, sideChat]

        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: false,
            searchActive: false,
            isHierarchyBrowsing: false
        )
    }

    func testSideChatParentResolvedFromAllSessionsOutsideFilteredRows() {
        // Parent lives only in allSessions (e.g. filtered out of the current
        // rows) — sideChatParentContexts must still resolve its title.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeSession(id: "parent-1", source: .claude, modifiedAt: base)
        let sideChat = makeSession(
            id: "side-1",
            source: .claude,
            modifiedAt: base.addingTimeInterval(1),
            parentSessionID: "parent-1",
            relationshipKind: .sideChat
        )

        assertParity(
            nextRows: [sideChat],
            allSessions: [parent, sideChat],
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: false,
            searchActive: false,
            isHierarchyBrowsing: false
        )
    }

    func testLargeReorderDetection() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 200 rows, all reordered (moved >= threshold of 128, same membership).
        let forward = (0..<200).map { i in makeSession(id: "s\(i)", modifiedAt: base.addingTimeInterval(Double(i))) }
        let reversed = Array(forward.reversed())

        assertParity(
            nextRows: reversed,
            allSessions: reversed,
            previousCachedRows: forward,
            collapsedParents: [],
            showSubagentHierarchy: false,
            searchActive: false,
            isHierarchyBrowsing: false
        )
    }

    func testSmallReorderIsNotLarge() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var rows = (0..<50).map { i in makeSession(id: "s\(i)", modifiedAt: base.addingTimeInterval(Double(i))) }
        let previous = rows
        rows.swapAt(0, 1)

        assertParity(
            nextRows: rows,
            allSessions: rows,
            previousCachedRows: previous,
            collapsedParents: [],
            showSubagentHierarchy: false,
            searchActive: false,
            isHierarchyBrowsing: false
        )
    }

    func testEmptyRows() {
        assertParity(
            nextRows: [],
            allSessions: [],
            previousCachedRows: [],
            collapsedParents: [],
            showSubagentHierarchy: true,
            searchActive: false,
            isHierarchyBrowsing: true
        )
    }

    /// Randomized fixture sweep: varied sort orders (via shuffling), hierarchy
    /// on/off, collapsed-parent subsets, and presence of unrelated/side-chat
    /// sessions — the combinations the plan calls out explicitly.
    func testRandomizedFixtureParity() {
        var rng = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for seed in 0..<20 {
            let sessionCount = Int.random(in: 5...60, using: &rng)
            var allRows: [Session] = []
            var parentIDs: [String] = []

            for i in 0..<sessionCount {
                let isChild = i > 0 && Bool.random(using: &rng) && !parentIDs.isEmpty
                if isChild {
                    let parentID = parentIDs.randomElement(using: &rng)!
                    allRows.append(makeSession(
                        id: "s\(seed)-\(i)",
                        modifiedAt: base.addingTimeInterval(Double(i)),
                        parentSessionID: parentID,
                        subagentType: "explore"
                    ))
                } else {
                    let id = "s\(seed)-\(i)"
                    allRows.append(makeSession(id: id, modifiedAt: base.addingTimeInterval(Double(i))))
                    parentIDs.append(id)
                }
            }

            let shuffled = allRows.shuffled(using: &rng)
            let collapsed = Set(parentIDs.shuffled(using: &rng).prefix(Int.random(in: 0...parentIDs.count, using: &rng)))
            let hierarchyOn = Bool.random(using: &rng)
            let searchActive = Bool.random(using: &rng)
            let hierarchyBrowsing = hierarchyOn && !searchActive

            assertParity(
                nextRows: shuffled,
                allSessions: shuffled,
                previousCachedRows: allRows,
                collapsedParents: collapsed,
                showSubagentHierarchy: hierarchyOn,
                searchActive: searchActive,
                isHierarchyBrowsing: hierarchyBrowsing
            )
        }
    }

#if DEBUG
    // MARK: - E3: fallback-presence map cache reuse
    //
    // `SessionRowsBuilder.build` used to call `buildFallbackPresenceMap`
    // unconditionally on every rebuild -- including the ~2s live-poll cadence
    // (`UnifiedSessionsView.onChange(of: unified.sessions)`), which republishes
    // even when `allSessions` is content-identical. These pin the fix: the same
    // (allSessions, presences, directJoinFallbackKeys) signature must be served
    // from cache on the second call, and a genuine change in any of those three
    // inputs must force a recompute.

    func testFallbackPresenceMapReusedForIdenticalInputs() {
        SessionRowsBuilder.debugResetFallbackPresenceCache()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<10).map { i in makeSession(id: "s\(i)", modifiedAt: base.addingTimeInterval(Double(i))) }

        func input() -> SessionRowsBuilder.RowsInput {
            SessionRowsBuilder.RowsInput(
                nextRows: rows,
                allSessions: rows,
                previousCachedRows: rows,
                collapsedParents: [],
                showSubagentHierarchy: false,
                searchActive: false,
                isHierarchyBrowsing: false,
                presences: [],
                directJoinFallbackKeys: []
            )
        }

        _ = SessionRowsBuilder.build(input: input())
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 1,
                       "first call always computes (nothing cached yet)")

        _ = SessionRowsBuilder.build(input: input())
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 1,
                       "second call with identical inputs must be served from cache, not recomputed")

        _ = SessionRowsBuilder.build(input: input())
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 1,
                       "repeated identical calls stay cached (matches the ~2s live-poll re-trigger pattern)")
    }

    func testFallbackPresenceMapRecomputesWhenAllSessionsChange() {
        SessionRowsBuilder.debugResetFallbackPresenceCache()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<5).map { i in makeSession(id: "s\(i)", modifiedAt: base.addingTimeInterval(Double(i))) }
        let changedRows = rows + [makeSession(id: "s-new", modifiedAt: base.addingTimeInterval(99))]

        func input(_ sessions: [Session]) -> SessionRowsBuilder.RowsInput {
            SessionRowsBuilder.RowsInput(
                nextRows: sessions,
                allSessions: sessions,
                previousCachedRows: sessions,
                collapsedParents: [],
                showSubagentHierarchy: false,
                searchActive: false,
                isHierarchyBrowsing: false,
                presences: [],
                directJoinFallbackKeys: []
            )
        }

        _ = SessionRowsBuilder.build(input: input(rows))
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 1)

        _ = SessionRowsBuilder.build(input: input(changedRows))
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 2,
                       "a genuine allSessions change (new session appended) must force a recompute")
    }

    func testFallbackPresenceMapRecomputesWhenDirectJoinKeysChange() {
        SessionRowsBuilder.debugResetFallbackPresenceCache()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<5).map { i in makeSession(id: "s\(i)", source: .claude, modifiedAt: base.addingTimeInterval(Double(i))) }

        func input(directJoinFallbackKeys: Set<String>) -> SessionRowsBuilder.RowsInput {
            SessionRowsBuilder.RowsInput(
                nextRows: rows,
                allSessions: rows,
                previousCachedRows: rows,
                collapsedParents: [],
                showSubagentHierarchy: false,
                searchActive: false,
                isHierarchyBrowsing: false,
                presences: [],
                directJoinFallbackKeys: directJoinFallbackKeys
            )
        }

        _ = SessionRowsBuilder.build(input: input(directJoinFallbackKeys: []))
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 1)

        let key = SessionRowsBuilder.fallbackPresenceKey(source: .claude, sessionID: "s0")
        _ = SessionRowsBuilder.build(input: input(directJoinFallbackKeys: [key]))
        XCTAssertEqual(SessionRowsBuilder.debugFallbackPresenceComputeCount(), 2,
                       "a genuine directJoinFallbackKeys change must force a recompute")
    }
#endif
}
