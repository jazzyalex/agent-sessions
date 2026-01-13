import Foundation

fileprivate struct QueryToken {
    let raw: String
    let value: String
    let startsWithQuote: Bool
}

fileprivate struct QueryLexer {
    private let input: String
    private var index: String.Index

    init(_ input: String) {
        self.input = input
        self.index = input.startIndex
    }

    mutating func nextToken() -> QueryToken? {
        skipWhitespace()
        guard index < input.endIndex else { return nil }

        let startsWithQuote = input[index] == "\""
        var raw = ""
        var value = ""
        var inQuote = false

        while index < input.endIndex {
            let scalar = input.unicodeScalars[index]
            if !inQuote, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                break
            }

            if scalar == "\"" {
                raw.append("\"")
                inQuote.toggle()
                index = input.unicodeScalars.index(after: index)
                continue
            }

            if inQuote, scalar == "\\" {
                raw.append("\\")
                index = input.unicodeScalars.index(after: index)
                guard index < input.endIndex else {
                    value.append("\\")
                    break
                }
                let escaped = input.unicodeScalars[index]
                raw.append(Character(escaped))
                if escaped == "\"" || escaped == "\\" {
                    value.append(Character(escaped))
                } else {
                    value.append("\\")
                    value.append(Character(escaped))
                }
                index = input.unicodeScalars.index(after: index)
                continue
            }

            raw.append(Character(scalar))
            value.append(Character(scalar))
            index = input.unicodeScalars.index(after: index)
        }

        return QueryToken(raw: raw, value: value, startsWithQuote: startsWithQuote)
    }

    private mutating func skipWhitespace() {
        while index < input.endIndex {
            let scalar = input.unicodeScalars[index]
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            index = input.unicodeScalars.index(after: index)
        }
    }
}

enum SearchTextMatcher {
    struct QueryTokenSpec: Hashable {
        let text: String
        let isPrefix: Bool
    }

    static func hasExplicitFTSSyntax(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        if q.contains("\"") { return true }
        if q.contains("*") { return true }
        if q.contains("(") || q.contains(")") { return true }
        if q.contains(":") { return true }
        let lower = q.lowercased()
        if lower.contains(" near ") || lower.hasPrefix("near ") || lower.hasSuffix(" near") { return true }
        if lower.contains(" and ") || lower.contains(" or ") || lower.contains(" not ") { return true }
        return false
    }

    static func hasMatch(in text: String, query: String) -> Bool {
        guard let pattern = buildPattern(from: query) else { return false }
        let tokens = tokenizeText(text)
        switch pattern {
        case .phrase(let phrase):
            return phraseHasMatch(tokens: tokens, query: phrase)
        case .boolean(let clauses):
            return booleanHasMatch(tokens: tokens, clauses: clauses)
        }
    }

    static func matchRanges(in text: String, query: String) -> [NSRange] {
        guard let pattern = buildPattern(from: query) else { return [] }
        let tokens = tokenizeText(text)
        switch pattern {
        case .phrase(let phrase):
            return phraseMatchRanges(tokens: tokens, query: phrase)
        case .boolean(let clauses):
            return booleanMatchRanges(tokens: tokens, clauses: clauses)
        }
    }

    private struct TextToken {
        let range: NSRange
        let valueLower: String
    }

    private struct BooleanClause {
        var required: [[QueryTokenSpec]] = []
        var forbidden: [[QueryTokenSpec]] = []
    }

    private enum Pattern {
        case phrase([QueryTokenSpec])
        case boolean([BooleanClause])
    }

    private static func buildPattern(from query: String) -> Pattern? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lexer = QueryLexer(trimmed)
        var tokens: [QueryToken] = []
        while let token = lexer.nextToken() {
            tokens.append(token)
        }
        let hasBooleanOps = tokens.contains { token in
            guard !token.startsWithQuote else { return false }
            let lower = token.value.lowercased()
            return lower == "and" || lower == "or" || lower == "not"
        }

        if hasBooleanOps {
            var clauses: [BooleanClause] = [BooleanClause()]
            var negateNext = false
            for token in tokens {
                let lower = token.value.lowercased()
                if !token.startsWithQuote {
                    if lower == "and" {
                        negateNext = false
                        continue
                    }
                    if lower == "or" {
                        negateNext = false
                        clauses.append(BooleanClause())
                        continue
                    }
                    if lower == "not" {
                        negateNext = true
                        continue
                    }
                }

                let termTokens = tokenizeQueryTerm(token.value, allowAutoPrefix: false)
                guard !termTokens.isEmpty else {
                    negateNext = false
                    continue
                }
                if negateNext {
                    clauses[clauses.count - 1].forbidden.append(termTokens)
                } else {
                    clauses[clauses.count - 1].required.append(termTokens)
                }
                negateNext = false
            }

            let filtered = clauses.filter { !$0.required.isEmpty || !$0.forbidden.isEmpty }
            guard !filtered.isEmpty else { return nil }
            return .boolean(filtered)
        }

        let allowAutoPrefix = !hasExplicitFTSSyntax(trimmed)
        let phraseTokens = tokenizeQueryTerm(trimmed, allowAutoPrefix: allowAutoPrefix)
        guard !phraseTokens.isEmpty else { return nil }
        return .phrase(phraseTokens)
    }

    private static func tokenizeText(_ text: String) -> [TextToken] {
        guard !text.isEmpty else { return [] }
        var out: [TextToken] = []
        out.reserveCapacity(max(8, text.count / 12))

        var start: String.Index? = nil
        var idx = text.unicodeScalars.startIndex
        let end = text.unicodeScalars.endIndex

        while idx < end {
            let scalar = text.unicodeScalars[idx]
            if isTokenChar(scalar) {
                if start == nil { start = idx }
            } else if let s = start {
                let tokenRange = s..<idx
                let token = String(text[tokenRange])
                let lower = token.lowercased()
                let range = NSRange(tokenRange, in: text)
                out.append(TextToken(range: range, valueLower: lower))
                start = nil
            }
            idx = text.unicodeScalars.index(after: idx)
        }

        if let s = start {
            let tokenRange = s..<end
            let token = String(text[tokenRange])
            let lower = token.lowercased()
            let range = NSRange(tokenRange, in: text)
            out.append(TextToken(range: range, valueLower: lower))
        }

        return out
    }

    private static func tokenizeQueryTerm(_ term: String, allowAutoPrefix: Bool) -> [QueryTokenSpec] {
        guard !term.isEmpty else { return [] }
        var out: [QueryTokenSpec] = []
        out.reserveCapacity(max(4, term.count / 12))

        var start: String.Index? = nil
        var idx = term.unicodeScalars.startIndex
        let end = term.unicodeScalars.endIndex

        while idx < end {
            let scalar = term.unicodeScalars[idx]
            if isTokenChar(scalar) {
                if start == nil { start = idx }
            } else if let s = start {
                let tokenRange = s..<idx
                let token = String(term[tokenRange])
                let lower = token.lowercased()
                let isPrefix = scalar == "*"
                out.append(QueryTokenSpec(text: lower, isPrefix: isPrefix))
                start = nil
            }
            idx = term.unicodeScalars.index(after: idx)
        }

        if let s = start {
            let tokenRange = s..<end
            let token = String(term[tokenRange])
            let lower = token.lowercased()
            out.append(QueryTokenSpec(text: lower, isPrefix: false))
        }

        if allowAutoPrefix, out.count == 1, !out[0].isPrefix {
            let token = out[0]
            if token.text.count >= 3, isSimpleASCII(token.text) {
                out[0] = QueryTokenSpec(text: token.text, isPrefix: true)
            }
        }

        return out
    }

    private static func phraseHasMatch(tokens: [TextToken], query: [QueryTokenSpec]) -> Bool {
        guard !tokens.isEmpty, !query.isEmpty else { return false }
        if query.count > tokens.count { return false }

        let maxIndex = tokens.count - query.count
        for start in 0...maxIndex {
            var matched = true
            for offset in 0..<query.count {
                let token = tokens[start + offset]
                let q = query[offset]
                if !matchesToken(token, query: q) {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }

    private static func phraseMatchRanges(tokens: [TextToken], query: [QueryTokenSpec]) -> [NSRange] {
        guard !tokens.isEmpty, !query.isEmpty else { return [] }
        if query.count > tokens.count { return [] }

        var out: [NSRange] = []
        let maxIndex = tokens.count - query.count
        for start in 0...maxIndex {
            var matched = true
            for offset in 0..<query.count {
                let token = tokens[start + offset]
                let q = query[offset]
                if !matchesToken(token, query: q) {
                    matched = false
                    break
                }
            }
            if matched {
                let first = tokens[start].range.location
                let last = tokens[start + query.count - 1].range
                let end = last.location + last.length
                out.append(NSRange(location: first, length: max(0, end - first)))
            }
        }
        return out
    }

    private static func booleanHasMatch(tokens: [TextToken], clauses: [BooleanClause]) -> Bool {
        for clause in clauses {
            var clauseOK = true
            for term in clause.required where !phraseHasMatch(tokens: tokens, query: term) {
                clauseOK = false
                break
            }
            if !clauseOK { continue }
            for term in clause.forbidden where phraseHasMatch(tokens: tokens, query: term) {
                clauseOK = false
                break
            }
            if clauseOK { return true }
        }
        return false
    }

    private static func booleanMatchRanges(tokens: [TextToken], clauses: [BooleanClause]) -> [NSRange] {
        var out: [NSRange] = []
        for clause in clauses {
            var clauseOK = true
            var clauseMatches: [NSRange] = []
            for term in clause.required {
                let ranges = phraseMatchRanges(tokens: tokens, query: term)
                if ranges.isEmpty {
                    clauseOK = false
                    break
                }
                clauseMatches.append(contentsOf: ranges)
            }
            if !clauseOK { continue }
            for term in clause.forbidden where phraseHasMatch(tokens: tokens, query: term) {
                clauseOK = false
                break
            }
            if clauseOK {
                out.append(contentsOf: clauseMatches)
            }
        }

        guard out.count > 1 else { return out }
        let sorted = out.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length < rhs.length
        }
        var unique: [NSRange] = []
        unique.reserveCapacity(sorted.count)
        var last: NSRange? = nil
        for r in sorted {
            if last?.location == r.location, last?.length == r.length { continue }
            unique.append(r)
            last = r
        }
        return unique
    }

    private static func matchesToken(_ token: TextToken, query: QueryTokenSpec) -> Bool {
        if query.isPrefix {
            return token.valueLower.hasPrefix(query.text)
        }
        return token.valueLower == query.text
    }

    private static func isTokenChar(_ scalar: UnicodeScalar) -> Bool {
        if scalar == "_" { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isSimpleASCII(_ term: String) -> Bool {
        for scalar in term.unicodeScalars {
            let v = scalar.value
            let isAZ = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            let is09 = (v >= 48 && v <= 57)
            let isUnderscore = (v == 95)
            if !(isAZ || is09 || isUnderscore) { return false }
        }
        return !term.isEmpty
    }
}

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

        if textScope == .toolOutputsOnly {
            if session.events.isEmpty { return false }
            for e in session.events {
                if let to = e.toolOutput, !to.isEmpty, SearchTextMatcher.hasMatch(in: to, query: q) { return true }
            }
            return false
        }

        // Priority 1: Search transcript if available
        if let cache = transcriptCache {
            if FeatureFlags.filterUsesCachedTranscriptOnly || !allowTranscriptGeneration {
                if let t = cache.getCached(session.id) {
                    return SearchTextMatcher.hasMatch(in: t, query: q)
                }
                // Fall through to raw fields if no cached transcript is present
            } else {
                let transcript = cache.getOrGenerate(session: session)
                return SearchTextMatcher.hasMatch(in: transcript, query: q)
            }
        }

        // Priority 2: Lightweight sessions without cache cannot be searched (no events to search)
        if session.events.isEmpty { return q.isEmpty }

        // Priority 3: Fallback to raw fields (title, repo, first user, event texts/tool io)
        if SearchTextMatcher.hasMatch(in: session.title, query: q) { return true }
        if let repo = session.repoName, SearchTextMatcher.hasMatch(in: repo, query: q) { return true }
        if let first = session.firstUserPreview, SearchTextMatcher.hasMatch(in: first, query: q) { return true }
        // Fallback to raw event fields (less accurate but works without cache)
        for e in session.events {
            if let t = e.text, !t.isEmpty, SearchTextMatcher.hasMatch(in: t, query: q) { return true }
            if let ti = e.toolInput, !ti.isEmpty, SearchTextMatcher.hasMatch(in: ti, query: q) { return true }
            if let to = e.toolOutput, !to.isEmpty, SearchTextMatcher.hasMatch(in: to, query: q) { return true }
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
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedQuery(freeText: "", repo: nil, path: nil) }

        enum PendingKey {
            case repo
            case path
        }

        var repo: String? = nil
        var path: String? = nil
        var remaining: [String] = []
        var pending: PendingKey? = nil

        var lexer = QueryLexer(trimmed)
        while let token = lexer.nextToken() {
            let lower = token.value.lowercased()
            let isRepoToken = lower.hasPrefix("repo:")
            let isPathToken = lower.hasPrefix("path:")

            if let pendingKey = pending, !isRepoToken, !isPathToken {
                let v = token.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    switch pendingKey {
                    case .repo: repo = v
                    case .path: path = v
                    }
                }
                pending = nil
                continue
            }

            if isRepoToken {
                let valueStart = token.value.index(token.value.startIndex, offsetBy: 5)
                let v = String(token.value[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    repo = v
                } else {
                    pending = .repo
                }
                continue
            }
            if isPathToken {
                let valueStart = token.value.index(token.value.startIndex, offsetBy: 5)
                let v = String(token.value[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    path = v
                } else {
                    pending = .path
                }
                continue
            }
            pending = nil
            remaining.append(token.raw)
        }

        return ParsedQuery(freeText: remaining.joined(separator: " "), repo: repo, path: path)
    }
}
