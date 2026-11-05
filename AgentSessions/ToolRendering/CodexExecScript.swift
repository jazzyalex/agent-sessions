import Foundation

/// Reads the `tools.<name>({…})` calls out of a Codex `exec` JavaScript script.
///
/// The reader is tolerant. It never throws and never loops forever. On malformed
/// input (unbalanced braces, unterminated strings) it keeps what it read so far.
/// It returns nil only when the source holds no `tools.<name>(` call.
///
/// Covered: object and array literals, unquoted / quoted keys, double-quoted and
/// single-quoted strings with escapes, template literals without `${}`, numbers,
/// booleans, null, shorthand properties. Any other value (identifier, `${}`
/// template, function call, spread) is kept as `.string(<source text>)`.
struct CodexExecScript: Equatable, Sendable {
    struct Call: Equatable, Sendable {
        var tool: String
        var arguments: [String: ToolPayloadValue]
        /// Span of `tools.<name>({…})` in the script.
        var sourceRange: Range<String.Index>
    }

    var calls: [Call]

    static func parse(_ source: String) -> CodexExecScript? {
        var reader = ScriptReader(source)
        let calls = reader.readCalls()
        return calls.isEmpty ? nil : CodexExecScript(calls: calls)
    }
}

private struct ScriptReader {
    struct Failure: Error {}

    let s: String
    var i: String.Index

    init(_ source: String) {
        s = source
        i = source.startIndex
    }

    private var atEnd: Bool { i >= s.endIndex }
    private var cur: Character? { atEnd ? nil : s[i] }

    private func isIdent(_ c: Character) -> Bool { c == "_" || c == "$" || c.isLetter || c.isNumber }

    private func peekNext() -> Character? {
        guard i < s.endIndex else { return nil }
        let n = s.index(after: i)
        return n < s.endIndex ? s[n] : nil
    }

    private mutating func advance() {
        if i < s.endIndex { i = s.index(after: i) }
    }

    // MARK: Calls

    mutating func readCalls() -> [CodexExecScript.Call] {
        var calls: [CodexExecScript.Call] = []
        var search = s.startIndex
        while search < s.endIndex,
              let hit = s.range(of: "tools.", range: search..<s.endIndex) {
            let start = hit.lowerBound
            // Must not be the tail of a longer identifier or a member access.
            if start > s.startIndex {
                let prev = s[s.index(before: start)]
                if isIdent(prev) || prev == "." { search = hit.upperBound; continue }
            }
            var p = hit.upperBound
            while p < s.endIndex, isIdent(s[p]) { p = s.index(after: p) }
            guard p > hit.upperBound else { search = hit.upperBound; continue }
            let name = String(s[hit.upperBound..<p])
            while p < s.endIndex, s[p].isWhitespace { p = s.index(after: p) }
            guard p < s.endIndex, s[p] == "(" else { search = hit.upperBound; continue }

            i = s.index(after: p)
            skipTrivia()
            var args: [String: ToolPayloadValue] = [:]
            var end = s.endIndex
            do {
                if cur == "{" {
                    try readObject(into: &args)
                } else {
                    try skipExpression(stopAtComma: false)
                }
                skipTrivia()
                end = (cur == ")") ? s.index(after: i) : i
            } catch {
                calls.append(.init(tool: name, arguments: args, sourceRange: start..<s.endIndex))
                break
            }
            calls.append(.init(tool: name, arguments: args, sourceRange: start..<end))
            if end >= s.endIndex { break }
            search = end
        }
        return calls
    }

    // MARK: Values

    private mutating func skipTrivia() {
        while let c = cur {
            if c.isWhitespace {
                advance()
            } else if c == "/", peekNext() == "/" {
                while let d = cur, d != "\n" { advance() }
            } else if c == "/", peekNext() == "*" {
                advance(); advance()
                while !atEnd {
                    if s[i] == "*", peekNext() == "/" { advance(); advance(); break }
                    advance()
                }
            } else {
                return
            }
        }
    }

    /// Reads `{…}` starting at `i`. On failure the pairs read so far stay in `dict`.
    private mutating func readObject(into dict: inout [String: ToolPayloadValue]) throws {
        advance() // "{"
        while true {
            skipTrivia()
            guard let c = cur else { throw Failure() }
            if c == "}" { advance(); return }
            if c == "," { advance(); continue }
            if c == "." { // spread: ...expr
                try skipExpression(stopAtComma: true)
                continue
            }
            let key: String
            if c == "\"" || c == "'" {
                key = try readQuoted()
            } else if c == "[" { // computed key: keep the source text
                let from = i
                try skipExpression(stopAtComma: true)
                key = String(s[from..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if isIdent(c) {
                let from = i
                while let d = cur, isIdent(d) { advance() }
                key = String(s[from..<i])
            } else {
                throw Failure()
            }
            skipTrivia()
            if cur == ":" {
                advance()
                dict[key] = try readValue()
            } else {
                dict[key] = .string(key) // shorthand `{cmd}`
            }
            skipTrivia()
            guard let d = cur else { throw Failure() }
            if d == "," { advance() } else if d != "}" { throw Failure() }
        }
    }

    private mutating func readArray() throws -> [ToolPayloadValue] {
        advance() // "["
        var items: [ToolPayloadValue] = []
        while true {
            skipTrivia()
            guard let c = cur else { throw Failure() }
            if c == "]" { advance(); return items }
            if c == "," { advance(); continue }
            items.append(try readValue())
            skipTrivia()
            guard let d = cur else { throw Failure() }
            if d == "," { advance() } else if d != "]" { throw Failure() }
        }
    }

    private mutating func readValue() throws -> ToolPayloadValue {
        skipTrivia()
        guard let c = cur else { throw Failure() }
        switch c {
        case "\"", "'":
            return try literalOrExpression(.string(try readQuoted()))
        case "`":
            let from = i
            let interpolated = try skipTemplate()
            if interpolated { return try literalOrExpression(.string(String(s[from..<i]))) }
            let body = String(s[s.index(after: from)..<s.index(before: i)])
            return try literalOrExpression(.string(decodeTemplate(body)))
        case "{":
            var d: [String: ToolPayloadValue] = [:]
            try readObject(into: &d)
            return .object(d)
        case "[":
            return .array(try readArray())
        default:
            break
        }
        let from = i
        try skipExpression(stopAtComma: true)
        let text = String(s[from..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        if let first = text.first, first.isNumber || first == "-" || first == "+" || first == ".",
           let n = Double(text.replacingOccurrences(of: "_", with: "")) {
            return .number(n)
        }
        return .string(text)
    }

    /// After a string literal the value may continue as an expression (`"a" + b`).
    /// Then the whole value is unreadable; keep the literal followed by the rest as text.
    private mutating func literalOrExpression(_ literal: ToolPayloadValue) throws -> ToolPayloadValue {
        let afterLiteral = i
        skipTrivia()
        guard let c = cur, c != ",", c != "}", c != "]", c != ")" else { return literal }
        try skipExpression(stopAtComma: true)
        let rest = String(s[afterLiteral..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
        return .string((literal.stringValue ?? "") + " " + rest)
    }

    // MARK: Strings

    private mutating func readQuoted() throws -> String {
        guard let quote = cur else { throw Failure() }
        advance()
        var out = ""
        while let c = cur {
            if c == quote { advance(); return out }
            advance()
            if c == "\\" {
                guard let e = cur else { throw Failure() }
                advance()
                appendEscape(e, to: &out)
            } else {
                out.append(c)
            }
        }
        throw Failure() // unterminated
    }

    private mutating func appendEscape(_ e: Character, to out: inout String) {
        switch e {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "b": out.append("\u{8}")
        case "f": out.append("\u{c}")
        case "v": out.append("\u{b}")
        case "0": out.append("\u{0}")
        case "\n", "\r\n": break // line continuation
        case "x":
            if let v = takeHex(2) { out.unicodeScalars.append(v) }
        case "u":
            if cur == "{" {
                advance()
                let from = i
                while let c = cur, c != "}" { advance() }
                let hex = String(s[from..<i])
                advance()
                if let n = UInt32(hex, radix: 16), let v = Unicode.Scalar(n) { out.unicodeScalars.append(v) }
            } else if let v = takeHex(4) {
                out.unicodeScalars.append(v)
            }
        default: out.append(e)
        }
    }

    private mutating func takeHex(_ count: Int) -> Unicode.Scalar? {
        var digits = ""
        var p = i
        for _ in 0..<count {
            guard p < s.endIndex, s[p].isHexDigit else { return nil }
            digits.append(s[p])
            p = s.index(after: p)
        }
        i = p
        guard let n = UInt32(digits, radix: 16) else { return nil }
        return Unicode.Scalar(n)
    }

    /// Decodes escapes of a template literal body that has no `${}`.
    private func decodeTemplate(_ body: String) -> String {
        guard body.contains("\\") else { return body }
        var sub = ScriptReader(body)
        var out = ""
        while let c = sub.cur {
            sub.advance()
            if c == "\\", let e = sub.cur {
                sub.advance()
                sub.appendEscape(e, to: &out)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Skips a template literal at `i`. Returns true when it holds `${}`.
    @discardableResult
    private mutating func skipTemplate() throws -> Bool {
        advance() // opening backtick
        var interpolated = false
        while let c = cur {
            if c == "\\" {
                advance(); advance()
            } else if c == "`" {
                advance()
                return interpolated
            } else if c == "$", peekNext() == "{" {
                interpolated = true
                advance(); advance()
                try skipExpression(stopAtComma: false)
                guard cur == "}" else { throw Failure() }
                advance()
            } else {
                advance()
            }
        }
        throw Failure()
    }

    /// Skips an expression. Stops (without consuming) at an unmatched `)`, `]`, `}`,
    /// at a top-level `,` when `stopAtComma`, or at the end of the source.
    private mutating func skipExpression(stopAtComma: Bool) throws {
        var depth = 0
        while let c = cur {
            switch c {
            case "\"", "'":
                _ = try readQuoted()
            case "`":
                try skipTemplate()
            case "(", "[", "{":
                depth += 1
                advance()
            case ")", "]", "}":
                if depth == 0 { return }
                depth -= 1
                advance()
            case ",":
                if depth == 0 && stopAtComma { return }
                advance()
            default:
                advance()
            }
        }
        if depth > 0 { throw Failure() }
    }
}
