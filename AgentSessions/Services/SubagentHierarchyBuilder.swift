import Foundation

/// Row metadata for hierarchical session display.
struct SubagentRowMeta {
    let depth: Int        // 0 = top-level, 1 = subagent child
    let hasChildren: Bool // true if this session has resolved subagent children
    let childCount: Int   // number of resolved subagent children (0 for non-parents)
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
    ///   - collapsedParents: Set of session IDs whose children should be hidden.
    ///     When empty (the default), all parents are expanded so children are visible.
    ///   - hierarchyEnabled: When false, returns all sessions flat at depth 0 (no hierarchy nesting).
    static func build(
        sessions: [Session],
        collapsedParents: Set<String> = [],
        hierarchyEnabled: Bool
    ) -> Result {
        guard hierarchyEnabled else {
            return flatResult(sessions: sessions)
        }

        // 1. Build parent lookup: parentKey → [child Session]
        //    Also build a reverse lookup to resolve parentSessionID → session.id
        var parentKeyToID: [String: String] = [:]  // raw UUID/parentID → session.id
        var needsRoleOnlyParentIndex = false
        for s in sessions {
            if s.source == .codex,
               s.parentSessionID == nil,
               s.subagentType != nil {
                needsRoleOnlyParentIndex = true
            }

            // Only register hints for non-subagent sessions: subagent events
            // carry the *parent's* sessionId, so allowing them to register would
            // overwrite the real parent mapping and break resolution.
            if s.parentSessionID == nil {
                // Map codexInternalSessionIDHint (raw UUID) to session.id
                if let hint = s.codexInternalSessionIDHint, !hint.isEmpty {
                    parentKeyToID[hint] = s.id
                }
                // Derive UUID from file path for Claude sessions whose
                // codexInternalSessionIDHint may not be persisted in the DB yet.
                // Claude session files are named <UUID>.jsonl.
                let fileName = URL(fileURLWithPath: s.filePath)
                    .deletingPathExtension().lastPathComponent
                if fileName.count == 36, fileName.contains("-"),
                   parentKeyToID[fileName] == nil {
                    parentKeyToID[fileName] = s.id
                }
            }
            // Also map session.id directly
            parentKeyToID[s.id] = s.id
        }

        let roleOnlyParentIndex = needsRoleOnlyParentIndex
            ? RoleOnlyParentIndex(sessions: sessions)
            : nil

        var childrenByParentID: [String: [Session]] = [:]
        var childIDs: Set<String> = []

        for s in sessions {
            guard let resolvedParentID = resolvedParentID(
                for: s,
                parentKeyToID: parentKeyToID,
                roleOnlyParentIndex: roleOnlyParentIndex
            ) else { continue }
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
            rowMeta[s.id] = SubagentRowMeta(depth: 0, hasChildren: hasChildren, childCount: children.count)

            if hasChildren, !collapsedParents.contains(s.id) {
                for child in children {
                    flatSessions.append(child)
                    rowMeta[child.id] = SubagentRowMeta(depth: 1, hasChildren: false, childCount: 0)
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
            rowMeta[s.id] = SubagentRowMeta(depth: 0, hasChildren: false, childCount: 0)
        }
        return Result(sessions: sessions, rowMeta: rowMeta)
    }

    private static func resolvedParentID(
        for session: Session,
        parentKeyToID: [String: String],
        roleOnlyParentIndex: RoleOnlyParentIndex?
    ) -> String? {
        if let rawParentKey = session.parentSessionID {
            return parentKeyToID[rawParentKey]
        }
        return inferredRoleOnlyCodexParentID(for: session, roleOnlyParentIndex: roleOnlyParentIndex)
    }

    /// Older Codex role subagents record only `source.subagent = "<role>"`,
    /// with no `parent_thread_id`. Keep the fallback narrow so unrelated
    /// review/memory subagents are not grouped across projects or old sessions.
    private static func inferredRoleOnlyCodexParentID(
        for child: Session,
        roleOnlyParentIndex: RoleOnlyParentIndex?
    ) -> String? {
        guard child.source == .codex,
              child.parentSessionID == nil,
              child.subagentType != nil,
              let childCwd = normalizedCwd(child.cwd),
              let roleOnlyParentIndex else {
            return nil
        }

        return roleOnlyParentIndex.nearestParentID(
            cwd: childCwd,
            before: child.modifiedAt,
            maxAge: Self.maxRoleOnlyParentInferenceAge
        )
    }

    private static let maxRoleOnlyParentInferenceAge: TimeInterval = 6 * 60 * 60

    private struct RoleOnlyParentCandidate {
        let id: String
        let startedAt: Date
    }

    private struct RoleOnlyParentIndex {
        private var candidatesByCwd: [String: [RoleOnlyParentCandidate]] = [:]

        init(sessions: [Session]) {
            candidatesByCwd.reserveCapacity(sessions.count)

            for session in sessions {
                guard session.source == .codex,
                      !session.isSubagent,
                      let cwd = SubagentHierarchyBuilder.normalizedCwd(session.cwd) else {
                    continue
                }
                candidatesByCwd[cwd, default: []].append(
                    RoleOnlyParentCandidate(id: session.id, startedAt: session.modifiedAt)
                )
            }

            for cwd in candidatesByCwd.keys {
                candidatesByCwd[cwd]?.sort { lhs, rhs in
                    if lhs.startedAt == rhs.startedAt { return lhs.id < rhs.id }
                    return lhs.startedAt < rhs.startedAt
                }
            }
        }

        func nearestParentID(cwd: String, before childStartedAt: Date, maxAge: TimeInterval) -> String? {
            guard let candidates = candidatesByCwd[cwd], !candidates.isEmpty else {
                return nil
            }

            var low = 0
            var high = candidates.count
            while low < high {
                let mid = (low + high) / 2
                if candidates[mid].startedAt <= childStartedAt {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            guard low > 0 else { return nil }
            let nearest = candidates[low - 1]
            guard childStartedAt.timeIntervalSince(nearest.startedAt) <= maxAge else {
                return nil
            }
            return nearest.id
        }
    }

    private static func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }
}
