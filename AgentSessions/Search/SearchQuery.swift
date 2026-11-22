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
        let consume: (String) throws -> Void
        init(_ consume: @escaping (String) throws -> Void) { self.consume = consume }
    }
    func enumerate(_ text: String, consume: @escaping (String) throws -> Void) throws {
        // Split only on ASCII whitespace, a native unicode61 separator. The caller's
        // phrase window spans chunks. An indivisible >64-KiB run is explicit incomplete
        // coverage rather than an uninterruptible tokenizer traversal.
        let bytes = text.utf8
        var start = bytes.startIndex
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
            try enumerateChunk(String(decoding: bytes[start..<end], as: UTF8.self), consume: consume)
            start = end
        }
    }
    private func enumerateChunk(_ text: String, consume: @escaping (String) throws -> Void) throws {
        let sink = Sink(consume)
        let result = text.utf8CString.withUnsafeBufferPointer { bytes in
            tokenizer.xTokenize(instance, Unmanaged.passUnretained(sink).toOpaque(), 0x0004,
                                bytes.baseAddress, Int32(bytes.count - 1)) { context, _, token, count, _, _ in
                guard let context, let token else { return SQLITE_ERROR }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                do {
                    try Task.checkCancellation()
                    try sink.consume(String(decoding: UnsafeRawBufferPointer(start: token, count: Int(count)), as: UTF8.self))
                    return SQLITE_OK
                } catch { sink.failure = error; return SQLITE_ABORT }
            }
        }
        if let failure = sink.failure { throw failure }
        guard result == SQLITE_OK else { throw Failure.tokenization }
    }
    func tokens(_ text: String) throws -> [String] {
        var tokens: [String] = []
        try enumerate(text) { tokens.append($0) }
        return tokens
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
    func truth(witnesses: Set<Int>, complete: Bool) -> Truth {
        func evaluate(_ p: Predicate) -> Truth {
            switch p {
            case .atom(let i): return witnesses.contains(i) ? .yes : (complete ? .no : .unknown)
            case .not(let p): switch evaluate(p) { case .yes: return .no; case .no: return .yes; case .unknown: return .unknown }
            case .and(let a, let b):
                let a = evaluate(a), b = evaluate(b)
                if a == .no || b == .no { return .no }; return a == .yes && b == .yes ? .yes : .unknown
            case .or(let a, let b):
                let a = evaluate(a), b = evaluate(b)
                if a == .yes || b == .yes { return .yes }; return a == .no && b == .no ? .no : .unknown
            }
        }
        return predicate.map(evaluate) ?? .yes
    }
}

/// Retains only a bounded token window and one bit per query atom, never a transcript.
final class SearchPredicateAccumulator {
    let query: SearchQuery
    private(set) var witnesses: Set<Int> = []
    private let tokenizer: SearchTokenizer
    init(query: SearchQuery, tokenizer: SearchTokenizer) { self.query = query; self.tokenizer = tokenizer }
    func consume(field: String) throws {
        var window: [String] = []
        let capacity = query.atoms.map { $0.tokens.count }.max() ?? 0
        guard capacity > 0 else { return }
        try tokenizer.enumerate(field) { [self] token in
            window.append(token)
            if window.count > capacity { window.removeFirst() }
            for (index, atom) in query.atoms.enumerated() where !witnesses.contains(index) && atom.tokens.count <= window.count {
                let candidate = window.suffix(atom.tokens.count)
                let matches = zip(candidate, atom.tokens).enumerated().allSatisfy { i, pair in
                    atom.prefix && i == atom.tokens.count - 1 ? pair.0.hasPrefix(pair.1) : pair.0 == pair.1
                }
                if matches { witnesses.insert(index) }
            }
        }
    }
    func truth(complete: Bool) -> SearchQuery.Truth { query.truth(witnesses: witnesses, complete: complete) }
}
