import Foundation

struct Filters: Equatable {
    var query: String = ""
    var dateFrom: Date?
    var dateTo: Date?
    var model: String?
    var kinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    var repoName: String? = nil
    var pathContains: String? = nil
}

enum FilterEngine {
    enum TextScope {
        case all
        case toolOutputsOnly
    }

    static func sessionMatches(_ session: Session,
                               filters: Filters,
                               transcriptCache: TranscriptCache? = nil,
                               allowTranscriptGeneration: Bool = true,
                               textScope: TextScope = .all) -> Bool {
        // Parse query operators repo: and path:
        let parsed = parseOperators(filters.query)
        let effectiveRepo = filters.repoName ?? parsed.repo
        let pathSubstr = filters.pathContains ?? parsed.path

        // Date range: compare session endTime first (modified), fallback to startTime
        let ref = session.endTime ?? session.startTime
        if let from = filters.dateFrom, let t = ref, t < from { return false }
        if let to = filters.dateTo, let t = ref, t > to { return false }

        if let m = filters.model, !m.isEmpty, session.model != m { return false }

        if let repo = effectiveRepo, !repo.isEmpty {
            guard let r = session.repoName?.lowercased() else { return false }
            if !r.contains(repo.lowercased()) { return false }
        }

        if let p = pathSubstr, !p.isEmpty {
            guard let path = session.cwd?.lowercased() else { return false }
            if !path.contains(p.lowercased()) { return false }
        }

        // Kinds: session must have any event in selected kinds
        // Skip this check for lightweight sessions (empty events array) since we can't filter by kind
        if !session.events.isEmpty {
            if !session.events.contains(where: { filters.kinds.contains($0.kind) }) { return false }
        }

        let q = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let qLower = q.lowercased()

        if textScope == .toolOutputsOnly {
            if session.events.isEmpty { return false }
            for e in session.events {
                if let to = e.toolOutput, !to.isEmpty, to.localizedCaseInsensitiveContains(q) { return true }
            }
            return false
        }

        // Priority 1: Search transcript if available
        if let cache = transcriptCache {
            if FeatureFlags.filterUsesCachedTranscriptOnly || !allowTranscriptGeneration {
                if let t = cache.getCached(session.id) {
                    return t.localizedCaseInsensitiveContains(q)
                }
                // Fall through to raw fields if no cached transcript is present
            } else {
                let transcript = cache.getOrGenerate(session: session)
                return transcript.localizedCaseInsensitiveContains(q)
            }
        }

        // Priority 2: Lightweight sessions without cache cannot be searched (no events to search)
        if session.events.isEmpty { return q.isEmpty }

        // Priority 3: Fallback to raw fields (title, repo, first user, event texts/tool io)
        if session.title.localizedCaseInsensitiveContains(q) { return true }
        if let repo = session.repoName?.lowercased(), repo.contains(qLower) { return true }
        if let first = session.firstUserPreview?.lowercased(), first.contains(qLower) { return true }
        // Fallback to raw event fields (less accurate but works without cache)
        for e in session.events {
            if let t = e.text, !t.isEmpty, t.localizedCaseInsensitiveContains(q) { return true }
            if let ti = e.toolInput, !ti.isEmpty, ti.localizedCaseInsensitiveContains(q) { return true }
            if let to = e.toolOutput, !to.isEmpty, to.localizedCaseInsensitiveContains(q) { return true }
        }
        return false
    }

    static func filterSessions(_ sessions: [Session],
                               filters: Filters,
                               transcriptCache: TranscriptCache? = nil,
                               allowTranscriptGeneration: Bool = true) -> [Session] {
        // Preserve the original sort order from allSessions instead of re-sorting
        sessions.filter { sessionMatches($0, filters: filters, transcriptCache: transcriptCache, allowTranscriptGeneration: allowTranscriptGeneration) }
    }

    struct ParsedQuery { let freeText: String; let repo: String?; let path: String? }
    static func parseOperators(_ q: String) -> ParsedQuery {
        guard !q.isEmpty else { return ParsedQuery(freeText: "", repo: nil, path: nil) }
        var repo: String? = nil
        var path: String? = nil
        var remaining: [String] = []
        for raw in q.split(separator: " ") {
            let token = String(raw)
            if token.hasPrefix("repo:") {
                let v = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { repo = v; continue }
            }
            if token.hasPrefix("path:") {
                let v = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { path = v; continue }
            }
            remaining.append(token)
        }
        return ParsedQuery(freeText: remaining.joined(separator: " "), repo: repo, path: path)
    }
}
