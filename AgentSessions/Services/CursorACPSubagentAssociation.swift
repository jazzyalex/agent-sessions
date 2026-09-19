import Foundation

/// Applies the explicit relationship between a persisted Cursor ACP root and
/// the JSONL subagent transcript it references. No project, timestamp, or
/// filename heuristics are used here.
enum CursorACPSubagentAssociation {
    static let parentIDPrefix = "cursor-acp:"
    static let subagentType = "cursor-acp-subagent"

    static func apply(
        sessions: [Session],
        acpResults: [CursorACPParseResult],
        chatMetadata: [CursorSessionMeta] = []
    ) -> [Session] {
        let metadataReferences = metadataReferenceMap(from: chatMetadata, acpResults: acpResults)
        let pathReferences = referenceMap(from: acpResults)
        guard !metadataReferences.isEmpty || !pathReferences.isEmpty else { return sessions }

        return sessions.map { session in
            // Cursor's child-store lineage is the strong signal. The path
            // map is consulted only when no validated metadata relation exists
            // for this child, preserving compatibility with older layouts.
            if let candidates = metadataReferences[session.id],
               let candidate = uniqueCandidate(candidates),
               let linked = apply(candidate: candidate, to: session) {
                return linked
            }

            let path = normalizedAbsolutePath(session.filePath)
            guard let path,
                  let candidates = pathReferences[path],
                  let candidate = uniqueCandidate(candidates),
                  let linked = apply(candidate: candidate, to: session) else {
                return session
            }
            return linked
        }
    }

    /// Build child-ID → ACP-parent IDs from Cursor's explicit child-store
    /// metadata. Unknown parents are intentionally omitted: attaching a child
    /// to a guessed/raw UUID would make an incomplete ACP graph look certain.
    static func metadataReferenceMap(
        from metadata: [CursorSessionMeta],
        acpResults: [CursorACPParseResult]
    ) -> [String: Set<String>] {
        let knownParents = Set(acpResults.compactMap { rawParentID(from: $0.session.id) })
        guard !knownParents.isEmpty else { return [:] }
        var map: [String: Set<String>] = [:]
        for meta in metadata {
            guard let info = meta.subagentInfo,
                  knownParents.contains(info.parentAgentID) else { continue }
            map[meta.agentId, default: []].insert(parentID(for: info.parentAgentID))
        }
        return map
    }

    private static func uniqueCandidate(_ candidates: Set<String>) -> String? {
        candidates.count == 1 ? candidates.first : nil
    }

    private static func apply(candidate: String, to session: Session) -> Session? {
        if let existingParent = session.parentSessionID,
           existingParent != candidate {
            // A raw UUID derived from a nested transcript path may be upgraded
            // only when it names this exact ACP parent. Other authoritative
            // relationships remain untouched.
            guard existingParent == candidate.replacingOccurrences(of: parentIDPrefix, with: "") else {
                return nil
            }
        }
        return session.withRelationship(
            parentSessionID: candidate,
            subagentType: subagentType,
            relationshipKind: .subagent
        )
    }

    private static func rawParentID(from sessionID: String) -> String? {
        let raw = sessionID.hasPrefix(parentIDPrefix)
            ? String(sessionID.dropFirst(parentIDPrefix.count))
            : sessionID
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func parentID(for rawUUID: String) -> String {
        parentIDPrefix + rawUUID.lowercased()
    }

    static func referenceMap(
        from results: [CursorACPParseResult]
    ) -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for result in results {
            for rawPath in result.referencedTranscriptPaths {
                guard let path = childPath(rawPath) else { continue }
                map[path, default: []].insert(result.session.id)
            }
        }
        return map
    }

    static func normalizedAbsolutePath(_ rawPath: String) -> String? {
        guard rawPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    private static func childPath(_ rawPath: String) -> String? {
        guard let normalized = normalizedAbsolutePath(rawPath) else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        guard let marker = components.lastIndex(of: "agent-transcripts") else { return nil }
        let suffix = Array(components.dropFirst(marker + 1))
        guard suffix.count == 3,
              suffix[1] == "subagents",
              suffix[2].hasSuffix(".jsonl") else { return nil }
        guard let parentUUID = UUID(uuidString: suffix[0])?.uuidString.lowercased(),
              let childUUID = UUID(uuidString: String(suffix[2].dropLast(".jsonl".count)))?.uuidString.lowercased(),
              parentUUID != childUUID else { return nil }
        return normalized
    }
}
