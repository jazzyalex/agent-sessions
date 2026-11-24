import Foundation
import SQLite3

/// The same native tokenizer used by both search FTS tables. One instance is worker-local.
final class SearchTokenizer {
    enum Failure: Error { case unavailable, tokenization, resourceLimit }
    private var db: OpaquePointer?
    private var tokenizer: fts5_tokenizer = .init()
    private var instance: OpaquePointer?

    init() throws {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw Failure.unavailable }
        var api: UnsafeMutablePointer<fts5_api>?
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &statement, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        withUnsafeMutablePointer(to: &api) { pointer in
            "fts5_api_ptr".withCString { tag in
                _ = sqlite3_bind_pointer(statement, 1, pointer, tag, nil)
                _ = sqlite3_step(statement)
            }
        }
        guard let api else { throw Failure.unavailable }
        var context: UnsafeMutableRawPointer?
        guard api.pointee.xFindTokenizer(api, "unicode61", &context, &tokenizer) == SQLITE_OK,
              tokenizer.xCreate(context, nil, 0, &instance) == SQLITE_OK else { throw Failure.unavailable }
    }
    deinit { if let instance { tokenizer.xDelete(instance) }; sqlite3_close(db) }

    private final class Sink {
        var failure: Error?
        let consume: (String, Range<Int>) throws -> Void
        init(_ consume: @escaping (String, Range<Int>) throws -> Void) { self.consume = consume }
    }
    func enumerate(_ text: String, consume: @escaping (String, Range<Int>) throws -> Void) throws {
        // Split only on ASCII whitespace, a native unicode61 separator. The caller's
        // phrase window spans chunks. An indivisible >64-KiB run is explicit incomplete
        // coverage rather than an uninterruptible tokenizer traversal.
        let bytes = text.utf8
        var start = bytes.startIndex
        var offset = 0
        while start < bytes.endIndex {
            try Task.checkCancellation()
            var end = bytes.index(start, offsetBy: 64 * 1024, limitedBy: bytes.endIndex) ?? bytes.endIndex
            if end < bytes.endIndex {
                var boundary = end
                while boundary > start {
                    let before = bytes.index(before: boundary)
                    if [UInt8(9), 10, 11, 12, 13, 32].contains(bytes[before]) { break }
                    boundary = before
                }
                guard boundary > start else { throw Failure.resourceLimit }
                end = boundary
            }
            let chunk = bytes[start..<end]
            let chunkOffset = offset
            try enumerateChunk(String(decoding: chunk, as: UTF8.self)) { token, range in
                try consume(token, (chunkOffset + range.lowerBound)..<(chunkOffset + range.upperBound))
            }
            offset += chunk.count
            start = end
        }
    }
    private func enumerateChunk(_ text: String, consume: @escaping (String, Range<Int>) throws -> Void) throws {
        let sink = Sink(consume)
        let result = text.utf8CString.withUnsafeBufferPointer { bytes in
            tokenizer.xTokenize(instance, Unmanaged.passUnretained(sink).toOpaque(), 0x0004,
                                bytes.baseAddress, Int32(bytes.count - 1)) { context, _, token, count, start, end in
                guard let context, let token else { return SQLITE_ERROR }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                do {
                    try Task.checkCancellation()
                    let value = String(decoding: UnsafeRawBufferPointer(start: token, count: Int(count)), as: UTF8.self)
                    try sink.consume(value, Int(start)..<Int(end))
                    return SQLITE_OK
                } catch { sink.failure = error; return SQLITE_ABORT }
            }
        }
        if let failure = sink.failure { throw failure }
        guard result == SQLITE_OK else { throw Failure.tokenization }
    }
    func tokens(_ text: String) throws -> [String] {
        var tokens: [String] = []
        try enumerate(text) { token, _ in tokens.append(token) }
        return tokens
    }
}

enum SearchTextSafety {
    static func mayContainCommonSecret(_ text: String) -> Bool {
        text.contains("botToken") || text.contains("apiKey") || text.contains("\"token\"")
            || text.contains("accessToken") || text.contains("refreshToken")
    }
}

struct SearchExcerpt: Equatable, Sendable {
    let leading: String
    let match: String
    let trailing: String

    var text: String { leading + match + trailing }

    /// FTS marks matches with U+0001 and U+0002. Highlight the first match in its passage.
    init?(indexedSnippet: String) {
        guard !SearchTextSafety.mayContainCommonSecret(indexedSnippet),
              let open = indexedSnippet.firstIndex(of: "\u{1}"),
              let close = indexedSnippet[indexedSnippet.index(after: open)...].firstIndex(of: "\u{2}") else { return nil }
        let prefix = indexedSnippet[..<open].utf8
        let matched = indexedSnippet[indexedSnippet.index(after: open)..<close].utf8
        let suffix = indexedSnippet[indexedSnippet.index(after: close)...].utf8
        self.init(before: prefix, matched: matched, after: suffix)
    }

    init?(field: String, range: Range<Int>) {
        let bytes = field.utf8
        guard let start = bytes.index(bytes.startIndex, offsetBy: range.lowerBound, limitedBy: bytes.endIndex),
              let end = bytes.index(start, offsetBy: range.count, limitedBy: bytes.endIndex) else { return nil }
        self.init(before: bytes[..<start], matched: bytes[start..<end], after: bytes[end...])
    }

    private init?<Bytes: Collection>(before: Bytes, matched: Bytes, after: Bytes) where Bytes.Element == UInt8 {
        let left = before.suffix(28)
        let center = matched.prefix(72)
        let right = after.prefix(100)
        leading = (left.count < before.count ? "…" : "") + Self.oneLine(left, suffix: true)
        match = Self.oneLine(center) + (center.count < matched.count ? "…" : "")
        trailing = Self.oneLine(right) + (right.count < after.count ? "…" : "")
        guard !match.isEmpty else { return nil }
    }

    private static func oneLine(_ bytes: some Collection<UInt8>, suffix: Bool = false) -> String {
        // The byte caps can fall between UTF-8 code units. Remove only the partial scalar.
        var string = String(decoding: bytes, as: UTF8.self)
        if suffix, string.first == "�" { string.removeFirst() }
        if !suffix, string.last == "�" { string.removeLast() }
        let content = string.filter { $0 != "\u{1}" && $0 != "\u{2}" }
        let words = content.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return content.isEmpty ? "" : " " }
        return (content.first?.isWhitespace == true ? " " : "") + words.joined(separator: " ")
            + (content.last?.isWhitespace == true ? " " : "")
    }
}

struct SearchQuery: Sendable, Equatable {
    struct Atom: Sendable, Equatable {
        let tokens: [String]
        let prefix: Bool
        var fts: String { "\"" + tokens.joined(separator: " ").replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "") }
    }
    indirect enum Predicate: Sendable, Equatable {
        case atom(Int), and(Predicate, Predicate), or(Predicate, Predicate), not(Predicate)
    }
    enum Truth: Sendable { case yes, no, unknown }
    enum Invalid: Error, LocalizedError, Equatable {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
    struct Lexeme: Equatable {
        let raw: String
        let value: String
        let quoted: Bool
    }
    struct Metadata {
        let freeText: String
        let repo: String?
        let path: String?
        let sideChatsOnly: Bool
    }
    let atoms: [Atom]
    let predicate: Predicate?
    let metadata: MetadataValue
    struct MetadataValue: Sendable, Equatable {
        let repo: String?
        let path: String?
        let sideChatsOnly: Bool
    }
    let freeText: String

    static func lex(_ input: String) throws -> [Lexeme] {
        guard input.utf8.count <= 8192 else { throw Invalid.message("Search is limited to 8 KiB.") }
        var tokens: [Lexeme] = []
        var start = input.startIndex
        while start < input.endIndex {
            if input[start].isWhitespace { start = input.index(after: start); continue }
            var end = start, quoted = false, value = ""
            while end < input.endIndex {
                let c = input[end]
                if c == "\"" { quoted.toggle() }
                else if c.isWhitespace && !quoted { break }
                else { value.append(c) }
                end = input.index(after: end)
            }
            guard !quoted else { throw Invalid.message("Close the quoted search phrase.") }
            tokens.append(.init(raw: String(input[start..<end]), value: value, quoted: input[start] == "\""))
            start = end
        }
        return tokens
    }

    static func metadataTokens(_ tokens: [Lexeme]) throws -> (Metadata, [Lexeme]) {
        var repo: String?, path: String?, side = false, content: [Lexeme] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]; i += 1
            let lower = token.value.lowercased()
            if !token.quoted, lower == "#side" { side = true; continue }
            if !token.quoted, lower.hasPrefix("repo:") || lower.hasPrefix("path:") {
                var value = String(token.value.dropFirst(5))
                if value.isEmpty, token.raw.contains("\"\"") { throw Invalid.message("Add a nonempty metadata value.") }
                if value.isEmpty, i < tokens.count, !tokens[i].value.contains(":") {
                    value = tokens[i].value; i += 1
                }
                guard !value.isEmpty else { throw Invalid.message("Add a value after repo: or path:.") }
                if lower.hasPrefix("repo:") { repo = value } else { path = value }
            } else { content.append(token) }
        }
        return (.init(freeText: content.map(\.raw).joined(separator: " "), repo: repo, path: path, sideChatsOnly: side), content)
    }

    init(_ input: String, tokenizer: SearchTokenizer) throws {
        let (meta, lexemes) = try Self.metadataTokens(Self.lex(input))
        metadata = .init(repo: meta.repo, path: meta.path, sideChatsOnly: meta.sideChatsOnly)
        freeText = meta.freeText
        let hasBoolean = lexemes.contains { !$0.quoted && ["AND", "OR", "NOT"].contains($0.value.uppercased()) }
        var atoms: [Atom] = []
        var i = 0
        func term() throws -> Predicate {
            guard i < lexemes.count else { throw Invalid.message("Add a term after the search operator.") }
            let lexeme = lexemes[i]; i += 1
            let upper = lexeme.value.uppercased()
            if !lexeme.quoted, upper == "NOT" { return .not(try term()) }
            guard lexeme.quoted || !["AND", "OR", "NEAR"].contains(upper) else { throw Invalid.message("Misplaced or unsupported search operator.") }
            guard lexeme.quoted || !lexeme.value.contains(where: { "():".contains($0) }) else { throw Invalid.message("Parentheses, NEAR and column selectors are not supported.") }
            var value = lexeme.value
            let explicitPrefix = lexeme.raw.hasSuffix("*")
            if explicitPrefix { value.removeLast() }
            guard !value.contains("*") else { throw Invalid.message("Use * only at the end of a term or phrase.") }
            let tokens = try tokenizer.tokens(value)
            guard !tokens.isEmpty else { throw Invalid.message("Search terms must contain letters or numbers.") }
            guard atoms.count < 128 else { throw Invalid.message("Search is limited to 128 terms or phrases.") }
            let prefix = explicitPrefix || (!lexeme.quoted && !hasBoolean && (tokens.last?.unicodeScalars.count ?? 0) >= 3)
            atoms.append(.init(tokens: tokens, prefix: prefix))
            return .atom(atoms.count - 1)
        }
        func conjunction() throws -> Predicate {
            var result = try term()
            while i < lexemes.count {
                let token = lexemes[i]
                if !token.quoted, token.value.uppercased() == "OR" { break }
                if !token.quoted, token.value.uppercased() == "AND" { i += 1 }
                result = .and(result, try term())
            }
            return result
        }
        var predicate: Predicate?
        if !lexemes.isEmpty {
            var result = try conjunction()
            while i < lexemes.count { i += 1; result = .or(result, try conjunction()) }
            predicate = result
        }
        self.atoms = atoms; self.predicate = predicate
    }

    /// Positive superset only: sampled FTS cannot establish any negative condition.
    var ftsCandidate: String? {
        func compile(_ p: Predicate) -> String? {
            switch p {
            case .atom(let i): return atoms[i].fts
            case .not: return nil
            case .and(let a, let b):
                switch (compile(a), compile(b)) {
                case (let a?, let b?): return "(\(a) AND \(b))"
                case (let a?, nil): return a
                case (nil, let b?): return b
                default: return nil
                }
            case .or(let a, let b):
                guard let a = compile(a), let b = compile(b) else { return nil }
                return "(\(a) OR \(b))"
            }
        }
        return predicate.flatMap(compile)
    }

    var hasPositiveAtom: Bool {
        func containsPositive(_ predicate: Predicate, negated: Bool) -> Bool {
            switch predicate {
            case .atom: return !negated
            case .not(let inner): return containsPositive(inner, negated: !negated)
            case .and(let left, let right), .or(let left, let right):
                return containsPositive(left, negated: negated) || containsPositive(right, negated: negated)
            }
        }
        return predicate.map { containsPositive($0, negated: false) } ?? false
    }
    func truth(witnesses: Set<Int>, complete: Bool) -> Truth {
        evidence(witnesses: witnesses, complete: complete).truth
    }

    func evidence(witnesses: Set<Int>, complete: Bool) -> (truth: Truth, atom: Int?) {
        func evaluate(_ p: Predicate) -> (truth: Truth, atom: Int?) {
            switch p {
            case .atom(let i): return witnesses.contains(i) ? (.yes, i) : (complete ? .no : .unknown, nil)
            case .not(.not(let inner)): return evaluate(inner)
            case .not(let inner):
                switch evaluate(inner).truth {
                case .yes: return (.no, nil)
                case .no: return (.yes, nil)
                case .unknown: return (.unknown, nil)
                }
            case .and(let a, let b):
                let a = evaluate(a), b = evaluate(b)
                if a.truth == .no || b.truth == .no { return (.no, nil) }
                if a.truth == .yes && b.truth == .yes { return (.yes, a.atom ?? b.atom) }
                return (.unknown, nil)
            case .or(let a, let b):
                let a = evaluate(a), b = evaluate(b)
                if a.truth == .yes, a.atom != nil { return a }
                if b.truth == .yes { return b }
                if a.truth == .yes { return a }
                return (a.truth == .no && b.truth == .no ? .no : .unknown, nil)
            }
        }
        return predicate.map(evaluate) ?? (.yes, nil)
    }
}

/// Retains only a bounded token window and one bit per query atom, never a transcript.
final class SearchPredicateAccumulator {
    let query: SearchQuery
    private(set) var witnesses: Set<Int> = []
    private let tokenizer: SearchTokenizer
    private let capacity: Int
    private var passages: [Int: SearchExcerpt] = [:]

    init(query: SearchQuery, tokenizer: SearchTokenizer) {
        self.query = query
        self.tokenizer = tokenizer
        capacity = query.atoms.map { $0.tokens.count }.max() ?? 0
    }

    func consume(field: String, capturePassage: Bool = false) throws {
        guard capacity > 0 else { return }
        var window: [(text: String, range: Range<Int>)] = []
        var canPreview: Bool?
        try tokenizer.enumerate(field) { [self] token, range in
            window.append((token, range))
            if window.count > capacity { window.removeFirst() }
            for (index, atom) in query.atoms.enumerated() where !witnesses.contains(index) && atom.tokens.count <= window.count {
                let candidate = window.suffix(atom.tokens.count)
                let matches = zip(candidate, atom.tokens).enumerated().allSatisfy { i, pair in
                    atom.prefix && i == atom.tokens.count - 1 ? pair.0.text.hasPrefix(pair.1) : pair.0.text == pair.1
                }
                guard matches else { continue }
                witnesses.insert(index)
                if capturePassage, let first = candidate.first {
                    if canPreview == nil { canPreview = !SearchTextSafety.mayContainCommonSecret(field) }
                    if canPreview == true {
                        passages[index] = SearchExcerpt(field: field, range: first.range.lowerBound..<range.upperBound)
                    }
                }
            }
        }
    }

    func excerpt(for atom: Int?) -> SearchExcerpt? { atom.flatMap { passages[$0] } }
    func truth(complete: Bool) -> SearchQuery.Truth { query.truth(witnesses: witnesses, complete: complete) }
}
