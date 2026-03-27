import Foundation

/// Row metadata for hierarchical session display.
struct SubagentRowMeta {
    let depth: Int        // 0 = top-level, 1 = subagent child
    let hasChildren: Bool // true if this session has resolved subagent children
}

/// Builds a parent-first flattened session list from a flat `[Session]` array,
/// grouping subagent sessions beneath their resolved parent.
///
/// The builder resolves parent references by matching `child.parentSessionID`
/// against both `session.id` and `session.codexInternalSessionIDHint` (needed
/// because Claude session IDs are SHA256 hashes, not raw UUIDs).
enum SubagentHierarchyBuilder {

    struct Result {
        /// Flattened session list with parents followed by their expanded children.
        let sessions: [Session]
        /// Per-session row metadata keyed by `session.id`.
        let rowMeta: [String: SubagentRowMeta]
    }

    /// Build a hierarchical session list.
    ///
    /// - Parameters:
    ///   - sessions: Pre-sorted flat session list (parents sorted by active sort).
    ///   - expandedParents: Set of session IDs whose children should be visible.
    ///   - hierarchyEnabled: When false, returns all sessions flat at depth 0 (no hierarchy nesting).
    static func build(
        sessions: [Session],
        expandedParents: Set<String>,
        hierarchyEnabled: Bool
    ) -> Result {
        guard hierarchyEnabled else {
            return flatResult(sessions: sessions)
        }

        // 1. Build parent lookup: parentKey → [child Session]
        //    Also build a reverse lookup to resolve parentSessionID → session.id
        var parentKeyToID: [String: String] = [:]  // raw UUID/parentID → session.id
        for s in sessions {
            // Map codexInternalSessionIDHint (raw UUID) to session.id
            if let hint = s.codexInternalSessionIDHint, !hint.isEmpty {
                parentKeyToID[hint] = s.id
            }
            // Also map session.id directly
            parentKeyToID[s.id] = s.id
        }

        var childrenByParentID: [String: [Session]] = [:]
        var childIDs: Set<String> = []

        for s in sessions {
            guard let rawParentKey = s.parentSessionID else { continue }
            guard let resolvedParentID = parentKeyToID[rawParentKey] else { continue }
            // Don't attach to self
            guard resolvedParentID != s.id else { continue }
            childrenByParentID[resolvedParentID, default: []].append(s)
            childIDs.insert(s.id)
        }

        // 2. Sort children within each parent by descending modifiedAt
        for (key, children) in childrenByParentID {
            childrenByParentID[key] = children.sorted { $0.modifiedAt > $1.modifiedAt }
        }

        // 3. Flatten: parents in original order, children inserted after expanded parents
        var flatSessions: [Session] = []
        var rowMeta: [String: SubagentRowMeta] = [:]
        flatSessions.reserveCapacity(sessions.count)
        rowMeta.reserveCapacity(sessions.count)

        for s in sessions {
            // Skip children — they'll be inserted after their parent
            if childIDs.contains(s.id) { continue }

            let children = childrenByParentID[s.id] ?? []
            let hasChildren = !children.isEmpty

            flatSessions.append(s)
            rowMeta[s.id] = SubagentRowMeta(depth: 0, hasChildren: hasChildren)

            if hasChildren, expandedParents.contains(s.id) {
                for child in children {
                    flatSessions.append(child)
                    rowMeta[child.id] = SubagentRowMeta(depth: 1, hasChildren: false)
                }
            }
        }

        return Result(sessions: flatSessions, rowMeta: rowMeta)
    }

    /// Returns a flat result with all sessions at depth 0 (no hierarchy nesting).
    private static func flatResult(sessions: [Session]) -> Result {
        var rowMeta: [String: SubagentRowMeta] = [:]
        rowMeta.reserveCapacity(sessions.count)
        for s in sessions {
            rowMeta[s.id] = SubagentRowMeta(depth: 0, hasChildren: false)
        }
        return Result(sessions: sessions, rowMeta: rowMeta)
    }
}
