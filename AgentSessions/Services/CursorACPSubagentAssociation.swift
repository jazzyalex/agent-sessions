import Foundation

/// Applies the explicit relationship between a persisted Cursor ACP root and
/// the JSONL subagent transcript it references. No project, timestamp, or
/// filename heuristics are used here.
enum CursorACPSubagentAssociation {
    static let parentIDPrefix = "cursor-acp:"
    static let subagentType = "cursor-acp-subagent"

    static func apply(
        sessions: [Session],
        acpResults: [CursorACPParseResult]
    ) -> [Session] {
        let references = referenceMap(from: acpResults)
        guard !references.isEmpty else { return sessions }

        return sessions.map { session in
            let path = normalizedAbsolutePath(session.filePath)
            guard let path,
                  let candidates = references[path],
                  candidates.count == 1,
                  let candidate = candidates.first else {
                return session
            }

            let candidateID = candidate
            if let existingParent = session.parentSessionID,
               existingParent != candidateID {
                // A raw UUID derived from the path can be upgraded only when
                // it is the sole authoritative candidate. Conflicts remain
                // untouched, as do any other existing parent identifiers.
                guard existingParent == candidateID ||
                        existingParent == candidateID.replacingOccurrences(of: parentIDPrefix, with: "") else {
                    return session
                }
            }

            return session.withRelationship(
                parentSessionID: candidateID,
                subagentType: subagentType,
                relationshipKind: .subagent
            )
        }
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
