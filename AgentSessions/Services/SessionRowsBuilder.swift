import Foundation

/// Pure, `Sendable` extraction of `UnifiedSessionsView.updateCachedRows()`'s heavy
/// phases (hierarchy build + row-derived state), so the computation can run off
/// the main actor and be applied as a generation-checked snapshot.
///
/// Deliberately narrow scope: this does NOT include `rows` (the filtered/sorted
/// session list `UnifiedSessionsView` derives before calling the builder) — that
/// filter depends on `CodexActiveSessionsModel.presence(for:)`, a main-actor
/// lookup against live, frequently-mutated presence caches (see docs plan W3
/// Task 1/3). Folding that in is out of scope for this extraction; `nextRows` is
/// passed in already computed by the caller on main.
enum SessionRowsBuilder {
    /// Snapshot of everything the heavy phases need. Every field is `Sendable`
    /// value data so this can cross into a detached task with no isolation
    /// concerns.
    struct RowsInput: Sendable {
        /// The already filtered + sorted session list (`UnifiedSessionsView.rows`
        /// at the moment the rebuild was triggered).
        let nextRows: [Session]
        /// `unified.allSessions` — needed for side-chat parent-title resolution,
        /// which may reference a parent session outside the current filtered set.
        let allSessions: [Session]
        /// The previous `cachedRows`, used to detect a large wholesale reorder.
        let previousCachedRows: [Session]
        let collapsedParents: Set<String>
        let showSubagentHierarchy: Bool
        /// True when a search query is active — hierarchy nesting is suppressed
        /// while searching (matches must be shown flat).
        let searchActive: Bool
        /// `isHierarchyBrowsing` at trigger time — gates whether
        /// `cachedExpandableParentIDs` is computed at all.
        let isHierarchyBrowsing: Bool

        init(nextRows: [Session],
             allSessions: [Session],
             previousCachedRows: [Session],
             collapsedParents: Set<String>,
             showSubagentHierarchy: Bool,
             searchActive: Bool,
             isHierarchyBrowsing: Bool) {
            self.nextRows = nextRows
            self.allSessions = allSessions
            self.previousCachedRows = previousCachedRows
            self.collapsedParents = collapsedParents
            self.showSubagentHierarchy = showSubagentHierarchy
            self.searchActive = searchActive
            self.isHierarchyBrowsing = isHierarchyBrowsing
        }
    }

    /// Result of the heavy phases, ready to be assigned to `UnifiedSessionsView`'s
    /// `@State` on the main actor in one turn.
    struct RowsOutput: Sendable {
        let cachedRows: [Session]
        let hierarchyRowMeta: [String: SubagentRowMeta]
        let sideChatParentContextByID: [String: String]
        let cachedRowIDs: [String]
        let cachedVisibleRowIDs: Set<String>
        let cachedExpandableParentIDs: Set<String>
        /// O(1) id -> row lookup, built once per rebuild so callers (selection
        /// bookkeeping, cockpit navigation) stop doing O(n) `first(where:)` scans
        /// per click.
        let cachedRowByID: [String: Session]
        /// Whether `previousCachedRows` -> `cachedRows` is a large wholesale
        /// reorder (see `UnifiedTableIdentityPolicy.isLargeReorder`). The caller
        /// bumps `tableReorderGeneration` on apply when this is true — that bump
        /// must happen in the same main-actor turn as assigning `cachedRows`.
        let isLargeReorder: Bool
    }

    /// Build the hierarchy + row-derived state. Pure function — safe to call from
    /// any isolation context (this is what makes it runnable via
    /// `Task.detached`).
    static func build(input: RowsInput) -> RowsOutput {
        let hierarchyResult = SubagentHierarchyBuilder.build(
            sessions: input.nextRows,
            collapsedParents: input.collapsedParents,
            hierarchyEnabled: input.showSubagentHierarchy && !input.searchActive
        )
        let newRows = hierarchyResult.sessions

        let isLargeReorder = UnifiedTableIdentityPolicy.isLargeReorder(
            old: input.previousCachedRows,
            new: newRows
        )

        let sideChatParentContextByID = UnifiedSessionsView.sideChatParentContexts(
            for: newRows,
            allSessions: input.allSessions
        )

        let cachedRowIDs = newRows.map(\.id)
        let cachedVisibleRowIDs = Set(cachedRowIDs)
        var cachedRowByID: [String: Session] = [:]
        cachedRowByID.reserveCapacity(newRows.count)
        for row in newRows {
            cachedRowByID[row.id] = row
        }

        let cachedExpandableParentIDs: Set<String>
        if input.isHierarchyBrowsing {
            cachedExpandableParentIDs = Set(newRows.compactMap { session in
                hierarchyResult.rowMeta[session.id]?.hasChildren == true ? session.id : nil
            })
        } else {
            cachedExpandableParentIDs = []
        }

        return RowsOutput(
            cachedRows: newRows,
            hierarchyRowMeta: hierarchyResult.rowMeta,
            sideChatParentContextByID: sideChatParentContextByID,
            cachedRowIDs: cachedRowIDs,
            cachedVisibleRowIDs: cachedVisibleRowIDs,
            cachedExpandableParentIDs: cachedExpandableParentIDs,
            cachedRowByID: cachedRowByID,
            isLargeReorder: isLargeReorder
        )
    }
}
