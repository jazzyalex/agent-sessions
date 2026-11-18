import Foundation

/// One-line tool-call summaries + consecutive-tool-run merging for the Rich
/// block list (Task 6). Pure, stateless — safe to call from the table
/// controller's `apply` path on every rebuild.
enum TranscriptToolSummary {

    /// Best-effort one-line summary of a tool call, derived from its raw JSON
    /// `toolInput`. Priority order (binding, per controller resolution — the
    /// brief's test semantics won over its prose): parsed JSON `command`
    /// (string, or array → drop `bash -lc`-style wrapper elements and join)
    /// → `description` → `file_path`/`path` last path component →
    /// `pattern`/`query`/`url` → `toolName` → first non-empty line of the
    /// raw `toolInput` (trimmed, capped at 80 chars; only reachable when
    /// `toolName` is nil/empty) → "Tool call". Rationale: real agent
    /// toolInput is JSON; when it isn't parseable, junk shouldn't beat a
    /// real tool name, but the raw-line rung still serves nameless tools.
    static func summary(toolName: String?, toolInput: String?) -> String {
        if let input = toolInput, isLarge(input) {
            return largeInputSummary(toolName: toolName, input: input)
        }
        if toolName == "exec", let input = toolInput, let cmd = execScriptCommand(input) {
            return cmd
        }
        if let input = toolInput, let json = parseJSON(input) {
            if let command = commandSummary(from: json) {
                return command
            }
            if let description = string(json["description"]), !description.isEmpty {
                return description
            }
            if let path = string(json["file_path"]) ?? string(json["path"]), !path.isEmpty {
                return lastPathComponent(path)
            }
            if let pattern = string(json["pattern"]), !pattern.isEmpty {
                return pattern
            }
            if let query = string(json["query"]), !query.isEmpty {
                return query
            }
            if let url = string(json["url"]), !url.isEmpty {
                return url
            }
        }

        if let toolName, !toolName.isEmpty {
            return toolName
        }

        if let input = toolInput, let firstLine = firstNonEmptyLine(input) {
            return cap(firstLine, at: 80)
        }

        return "Tool call"
    }

    /// Primary argument shown in a tool-call label (not the summary): the first
    /// non-empty string among `command`, `cmd`, `file_path`, `path`, `filePath`,
    /// `target_file`, `pattern`, `query`, `url`, `description`. For a Codex `exec`
    /// script it is the first call's `cmd`. Nil when there is none.
    static func callLabelArgument(toolName: String?, toolInput: String?) -> String? {
        guard let input = toolInput, !input.isEmpty else { return nil }
        if isLarge(input) {
            let prefix = boundedPrefix(input)
            if toolName == "exec", let cmd = execScriptCommand(prefix.text, cutByPrefix: prefix.cut) { return cmd }
            let fields = LargeInputScanner.scan(prefix.text)
            if let command = fields.command { return command }
            for key in ["file_path", "filePath", "target_file", "pattern", "query", "url", "path", "description"] {
                if let value = fields.strings[key], !value.isEmpty { return value }
            }
            return nil
        }
        if toolName == "exec", let cmd = execScriptCommand(input) {
            return cmd
        }
        guard let json = parseJSON(input) else { return nil }
        if let command = commandSummary(from: json) {
            return command
        }
        // `path` ranks after `pattern`/`query`/`url` so `Grep {pattern, path}` reads as the pattern.
        for key in ["file_path", "filePath", "target_file", "pattern", "query", "url", "path", "description"] {
            if let value = string(json[key]), !value.isEmpty { return value }
        }
        return nil
    }

    /// First non-empty `cmd` of a Codex `exec` script, or nil when the script does not parse.
    /// `cutByPrefix`: the script is the bounded prefix of a longer input, so a `cmd` literal that is
    /// still open at its end keeps the part that was read.
    private static func execScriptCommand(_ script: String, cutByPrefix: Bool = false) -> String? {
        if let fast = ExecFirstCommandScan.firstCommand(in: script, cutByPrefix: cutByPrefix) { return fast }
        guard let parsed = CodexExecScript.parse(script, maxCalls: 1) else { return nil }
        guard let cmd = parsed.calls.first?.arguments["cmd"]?.stringValue, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Number of tool calls in a merged run: `.toolCall` blocks, minimum 1
    /// (an orphan-output run still reads as one call).
    static func callCount(in blocks: [SessionTranscriptBuilder.LogicalBlock]) -> Int {
        max(1, blocks.reduce(0) { $0 + ($1.kind == .toolCall ? 1 : 0) })
    }

    /// Header text for a collapsed tool card. Two or more calls form a group titled
    /// "N tool calls" (no tool name: the calls may differ). Otherwise the card is a
    /// single-call header built from the call block, or from the first output block
    /// when the run has no call.
    static func cardHeader(for blocks: [SessionTranscriptBuilder.LogicalBlock])
        -> (isGroup: Bool, toolName: String?, summary: String) {
        let count = callCount(in: blocks)
        if count >= 2 {
            let title = String(localized: "\(count) tool calls",
                               comment: "Header of a collapsed transcript card that groups several tool calls. The number is the call count.")
            return (true, nil, title)
        }
        guard let lead = blocks.first(where: { $0.kind == .toolCall }) ?? blocks.first else {
            return (false, nil, summary(toolName: nil, toolInput: nil))
        }
        return (false,
                displayToolName(name: lead.toolName, namespace: lead.toolNamespace),
                summary(toolName: lead.toolName, toolInput: lead.toolInput))
    }

    /// Tool name for display, with the Codex namespace as a "server › tool" prefix.
    /// `mcp__node_repl__` + `js` -> `node_repl › js`. Nil/empty namespace keeps `name`.
    static func displayToolName(name: String?, namespace: String?) -> String? {
        guard let name else { return nil }
        guard var server = namespace, !server.isEmpty else { return name }
        if server.hasPrefix("mcp__") { server.removeFirst("mcp__".count) }
        if server.hasSuffix("__") { server.removeLast(2) }
        server = server.replacingOccurrences(of: "::", with: " › ")
                       .replacingOccurrences(of: "__", with: " › ")
        guard !server.isEmpty else { return name }
        return "\(server) › \(name)"
    }

    // MARK: - Large inputs

    /// Inputs above this size (UTF-8 bytes) are never fully parsed for a label or summary.
    static let largeInputBytes = 8 * 1024
    /// A large input is read up to this many UTF-8 bytes.
    static let scanPrefixBytes = 16 * 1024

    private static func isLarge(_ input: String) -> Bool { input.utf8.count > largeInputBytes }

    /// The first `scanPrefixBytes` of a large input. `cut` is true when the input goes on past them.
    private static func boundedPrefix(_ input: String) -> (text: String, cut: Bool) {
        let utf8 = input.utf8
        return (String(decoding: utf8.prefix(scanPrefixBytes), as: UTF8.self), utf8.count > scanPrefixBytes)
    }

    /// `summary` for a large input: same priority order, fed by a bounded scan of the top-level fields.
    private static func largeInputSummary(toolName: String?, input: String) -> String {
        let bounded = boundedPrefix(input)
        let prefix = bounded.text
        if toolName == "exec", let cmd = execScriptCommand(prefix, cutByPrefix: bounded.cut) { return cmd }
        let fields = LargeInputScanner.scan(prefix)
        if let command = fields.command { return command }
        let strings = fields.strings
        if let description = strings["description"], !description.isEmpty { return description }
        if let path = strings["file_path"] ?? strings["path"], !path.isEmpty { return lastPathComponent(path) }
        for key in ["pattern", "query", "url"] {
            if let value = strings[key], !value.isEmpty { return value }
        }
        if let toolName, !toolName.isEmpty { return toolName }
        if let firstLine = firstNonEmptyLine(String(prefix.prefix(2_000))) { return cap(firstLine, at: 80) }
        return "Tool call"
    }

    /// Reads the top-level string fields of a JSON object prefix without building the object.
    /// Values are decoded to at most `maxValueBytes`; a literal cut off by the prefix keeps what was read.
    private enum LargeInputScanner {
        static let maxValueBytes = 4096
        static let targets: Set<String> = ["command", "cmd", "file_path", "filePath", "target_file", "pattern",
                                           "query", "url", "path", "description"]

        struct Fields {
            var strings: [String: String] = [:]
            var command: String?
        }

        static func scan(_ text: String) -> Fields {
            let b = Array(text.utf8)
            var fields = Fields()
            var rawCommand: String?
            var rawCmd: String?
            var i = 0
            func skipSpace() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
            skipSpace()
            guard i < b.count, b[i] == UInt8(ascii: "{") else { return fields }
            i += 1
            while i < b.count {
                skipSpace()
                while i < b.count, b[i] == UInt8(ascii: ",") { i += 1; skipSpace() }
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { break }
                let key = readString(b, &i, limit: 64)
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { break }
                i += 1
                skipSpace()
                guard i < b.count else { break }
                let isTarget = targets.contains(key.value)
                if b[i] == UInt8(ascii: "\"") {
                    let value = readString(b, &i, limit: isTarget ? maxValueBytes : 0)
                    if isTarget {
                        if key.value == "command" { rawCommand = rawCommand ?? value.value }
                        else if key.value == "cmd" { rawCmd = rawCmd ?? value.value }
                        else if fields.strings[key.value] == nil { fields.strings[key.value] = value.value }
                    }
                    if !value.terminated { break }
                } else if b[i] == UInt8(ascii: "["), key.value == "command" || key.value == "cmd" {
                    i += 1
                    var parts: [String] = []
                    var closed = false
                    while i < b.count {
                        skipSpace()
                        while i < b.count, b[i] == UInt8(ascii: ",") { i += 1; skipSpace() }
                        guard i < b.count else { break }
                        if b[i] == UInt8(ascii: "]") { i += 1; closed = true; break }
                        guard b[i] == UInt8(ascii: "\"") else { break }
                        let part = readString(b, &i, limit: maxValueBytes)
                        parts.append(part.value)
                        if !part.terminated { break }
                    }
                    let filtered = Array(parts.drop(while: { ["bash", "sh", "zsh", "-lc", "-c"].contains($0) }))
                    let joined = (filtered.isEmpty ? parts : filtered).joined(separator: " ")
                    if !joined.isEmpty {
                        if key.value == "command" { rawCommand = rawCommand ?? joined } else { rawCmd = rawCmd ?? joined }
                    }
                    if !closed { break }
                } else if !skipValue(b, &i) {
                    break
                }
            }
            if let c = rawCommand, !c.isEmpty { fields.command = c }
            else if let c = rawCmd, !c.isEmpty { fields.command = c }
            return fields
        }

        /// Skips a non-string value (object, array, number, literal). False when the prefix ends inside it.
        private static func skipValue(_ b: [UInt8], _ i: inout Int) -> Bool {
            var depth = 0
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    let s = readString(b, &i, limit: 0)
                    if !s.terminated { return false }
                    if depth == 0 { return true }
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    if depth == 0 { return true }
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                } else if c == UInt8(ascii: ","), depth == 0 { return true }
                i += 1
            }
            return false
        }

        /// Reads the string literal at `b[i] == '"'` and moves `i` past its closing quote.
        /// Keeps at most `limit` decoded UTF-8 bytes.
        static func readString(_ b: [UInt8], _ i: inout Int, limit: Int) -> (value: String, terminated: Bool) {
            i += 1
            var out: [UInt8] = []
            func put(_ scalar: UnicodeScalar) {
                guard out.count < limit else { return }
                out.append(contentsOf: Array(String(scalar).utf8))
            }
            func hex4(_ at: Int) -> UInt32? {
                guard at + 4 <= b.count else { return nil }
                var v: UInt32 = 0
                for k in at..<(at + 4) {
                    guard let d = Character(UnicodeScalar(b[k])).hexDigitValue else { return nil }
                    v = v * 16 + UInt32(d)
                }
                return v
            }
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return (String(decoding: out, as: UTF8.self), true)
                }
                if c == UInt8(ascii: "\\") {
                    guard i + 1 < b.count else { break }
                    let e = b[i + 1]
                    i += 2
                    switch e {
                    case UInt8(ascii: "n"): put("\n")
                    case UInt8(ascii: "t"): put("\t")
                    case UInt8(ascii: "r"): put("\r")
                    case UInt8(ascii: "b"): put("\u{08}")
                    case UInt8(ascii: "f"): put("\u{0C}")
                    case UInt8(ascii: "u"):
                        guard var v = hex4(i) else { return (String(decoding: out, as: UTF8.self), false) }
                        i += 4
                        if (0xD800..<0xDC00).contains(v), i + 6 <= b.count, b[i] == UInt8(ascii: "\\"),
                           b[i + 1] == UInt8(ascii: "u"), let low = hex4(i + 2), (0xDC00..<0xE000).contains(low) {
                            v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                            i += 6
                        }
                        put(UnicodeScalar(v) ?? "\u{FFFD}")
                    default: put(UnicodeScalar(e))   // \" \\ \/
                    }
                    continue
                }
                if out.count < limit { out.append(c) }
                i += 1
            }
            return (String(decoding: out, as: UTF8.self), false)
        }
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// `command` may be a plain string, or an argv-style array. For arrays,
    /// drop leading shell-wrapper elements (`bash`, `sh`, `zsh`, `-lc`, `-c`)
    /// and join the remainder — that remainder is normally the single
    /// human-readable command string emitted by `bash -lc "..."` invocations.
    private static func commandSummary(from json: [String: Any]) -> String? {
        guard let raw = json["command"] ?? json["cmd"] else { return nil }

        if let str = raw as? String, !str.isEmpty {
            return str
        }

        if let arr = raw as? [Any] {
            let parts = arr.compactMap { $0 as? String }
            // Drop only the LEADING run of wrapper tokens; stop at the first
            // non-wrapper token and keep everything after it verbatim. A wrapper
            // token appearing later (e.g. `grep -c TODO`) is a real argument.
            let filtered = Array(parts.drop(while: { isShellWrapperToken($0) }))
            let joined = (filtered.isEmpty ? parts : filtered).joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private static func isShellWrapperToken(_ token: String) -> Bool {
        switch token {
        case "bash", "sh", "zsh", "-lc", "-c":
            return true
        default:
            return false
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func firstNonEmptyLine(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func cap(_ text: String, at maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength))
    }
}

/// UTF-8 fast path for the `cmd` of the first call in a Codex `exec` script, used only by labels and
/// summaries. It reads the bytes of the first `tools.<name>(` and its `{…}` object: the `cmd` key at the
/// top of that object, and the rest of the object, to check that no second `cmd` follows (the parser
/// keeps the last one). It must never disagree with `CodexExecScript.parse(_:maxCalls: 1)`. Whenever it
/// could read the script differently it returns nil, and the caller runs the full parser. That covers: no
/// call; a spread, computed key or shorthand `cmd`; a `cmd` that is not one plain literal; `${}` in a
/// template; input the parser rejects; a second `cmd`; and spots where the parser's Characters differ from
/// these bytes (see `findCall`, `skipTrivia`, `appendEscape` and `hasCharacterHazard`).
enum ExecFirstCommandScan {
    /// `cutByPrefix`: `script` is the bounded prefix of a longer input. A `cmd` literal or call object that
    /// is still open at the end of the prefix then keeps what was read (a label is cut at 120 characters).
    static func firstCommand(in script: String, cutByPrefix: Bool = false) -> String? {
        if let result = script.utf8.withContiguousStorageIfAvailable({ run($0, cutByPrefix: cutByPrefix) }) {
            return result
        }
        return Array(script.utf8).withUnsafeBufferPointer { run($0, cutByPrefix: cutByPrefix) }
    }

    private static func run(_ b: UnsafeBufferPointer<UInt8>, cutByPrefix: Bool) -> String? {
        var reader = Reader(b: b)
        guard reader.findCall(), let bytes = reader.readCommand(cutByPrefix: cutByPrefix),
              !reader.hasCharacterHazard(through: reader.i) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Reader {
        let b: UnsafeBufferPointer<UInt8>
        var i = 0
        /// Set where the parser may read the script differently. The scan then gives up.
        var odd = false
        /// Nesting limit for skipped values. The parser's limit is 64; deeper input goes to the parser.
        static let maxDepth = 16
        static let cmdKey: [UInt8] = Array("cmd".utf8)

        init(b: UnsafeBufferPointer<UInt8>) { self.b = b }

        private var n: Int { b.count }

        static func isIdent(_ c: UInt8) -> Bool {
            c == 0x5F || c == 0x24 || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        // MARK: Call

        /// Moves `i` past the `(` of the first `tools.<name>(` that the parser takes. False when there is
        /// none, or when a byte around a candidate could read differently as a Character: a non-ASCII byte
        /// just before `tools.` (the parser skips only letters and digits there), a non-ASCII byte at the
        /// start or end of the name (the parser takes letters), or VT, FF or a non-ASCII byte before `(`
        /// (the parser skips them as whitespace).
        mutating func findCall() -> Bool {
            var search = 0
            while let hit = find(from: search) {
                let afterHit = hit + 6
                search = afterHit
                if hit > 0 {
                    let prev = b[hit - 1]
                    if prev >= 0x80 { return false }
                    if Reader.isIdent(prev) || prev == 0x2E { continue }
                }
                var p = afterHit
                while p < n, Reader.isIdent(b[p]) { p += 1 }
                if p < n, b[p] >= 0x80 { return false }
                guard p > afterHit else { continue }
                while p < n, Reader.isSpace(b[p]) { p += 1 }
                guard p < n else { return false }
                let c = b[p]
                if c >= 0x80 || c == 0x0B || c == 0x0C { return false }
                guard c == 0x28 else { continue }
                i = p + 1
                return true
            }
            return false
        }

        /// Index of the first `tools.` at or after `from`.
        private func find(from: Int) -> Int? {
            var k = from
            while k + 6 <= n {
                if b[k] == 0x74, b[k + 1] == 0x6F, b[k + 2] == 0x6F, b[k + 3] == 0x6C, b[k + 4] == 0x73,
                   b[k + 5] == 0x2E { return k }
                k += 1
            }
            return nil
        }

        /// `i` is just after the call's `(`. Returns the decoded `cmd` of the call's `{…}` object.
        mutating func readCommand(cutByPrefix: Bool) -> [UInt8]? {
            guard skipTrivia(), i < n, b[i] == 0x7B else { return nil }
            i += 1
            var command: [UInt8]?
            while true {
                guard skipTrivia(), i < n else { break }
                let c = b[i]
                if c == 0x7D { return command }
                if c == 0x2C { i += 1; continue }
                let key: [UInt8]
                if c == 0x22 || c == 0x27 {
                    let quoted = readQuoted()
                    guard quoted.closed else { break }
                    key = quoted.bytes
                } else if Reader.isIdent(c) {
                    let from = i
                    while i < n, Reader.isIdent(b[i]) { i += 1 }
                    if i < n, b[i] >= 0x80 { return nil }
                    key = Array(b[from..<i])
                } else {
                    return nil   // spread, computed key, non-ASCII
                }
                let isCmd = key == Reader.cmdKey
                if isCmd, command != nil { return nil }   // the parser keeps the last `cmd`
                guard skipTrivia(), i < n else { break }
                if b[i] == 0x3A {
                    i += 1
                    guard skipTrivia(), i < n else { break }
                    if isCmd {
                        let literal: (bytes: [UInt8], closed: Bool)?
                        switch b[i] {
                        case 0x22, 0x27: literal = readQuoted()
                        case 0x60: literal = readTemplate()
                        default: literal = nil   // an expression
                        }
                        guard let literal, !odd else { return nil }
                        if !literal.closed {
                            // The literal is open at the end of the script: keep it only when a prefix cut it.
                            return cutByPrefix && !literal.bytes.isEmpty ? literal.bytes : nil
                        }
                        guard !literal.bytes.isEmpty else { return nil }
                        command = literal.bytes
                    } else if !skipValue(depth: 0) {
                        break
                    }
                } else if isCmd {
                    return nil   // shorthand `{cmd}`
                }
                // The value must end here (a literal followed by `+ x` is an expression).
                guard skipTrivia(), i < n else { break }
                if b[i] == 0x2C { i += 1 } else if b[i] != 0x7D { return nil }
            }
            // Stopped early: odd or malformed input, or the end of the script. At the end of a cut prefix the
            // `cmd` read so far stands (the parser also keeps the pairs read before an open object ends).
            return !odd && i >= n && cutByPrefix ? command : nil
        }

        // MARK: Trivia

        /// Skips whitespace and comments. False, with `odd` set, where the parser may read differently: a
        /// non-ASCII byte (it may be a space or a letter to the parser), VT or FF (spaces to the parser), or
        /// a `//` comment that ends in CRLF (one Character to the parser, so its comment runs on). A `/*`
        /// that is never closed moves `i` to the end.
        mutating func skipTrivia() -> Bool {
            while i < n {
                let c = b[i]
                if Reader.isSpace(c) {
                    i += 1
                } else if c >= 0x80 || c == 0x0B || c == 0x0C {
                    odd = true
                    return false
                } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F {
                    while i < n, b[i] != 0x0A { i += 1 }
                    if i < n, b[i - 1] == 0x0D { odd = true; return false }
                } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < n, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                    i = i + 1 < n ? i + 2 : n
                } else {
                    return true
                }
            }
            return true
        }

        // MARK: Values (mirror the parser's readValue, readObject, readArray and skipExpression)

        /// Skips the value at `i` as the parser's `readValue` reads it. False where the parser throws or
        /// may throw (the caller then gives up), or at the end of the script.
        mutating func skipValue(depth: Int) -> Bool {
            guard skipTrivia(), i < n else { return false }
            switch b[i] {
            case 0x22, 0x27:
                guard readQuoted().closed else { return false }
                return skipAfterLiteral()
            case 0x60:
                guard let template = readTemplate(), template.closed else { return false }
                return skipAfterLiteral()
            case 0x7B, 0x5B:
                guard depth < Reader.maxDepth else { return false }
                return b[i] == 0x7B ? skipObject(depth: depth + 1) : skipArray(depth: depth + 1)
            default:
                return skipExpression()
            }
        }

        /// After a literal the value may go on as an expression (`"a" + b`), as in `literalOrExpression`.
        private mutating func skipAfterLiteral() -> Bool {
            guard skipTrivia() else { return false }
            guard i < n else { return true }
            switch b[i] {
            case 0x2C, 0x7D, 0x5D, 0x29: return true
            default: return skipExpression()
            }
        }

        private mutating func skipObject(depth: Int) -> Bool {
            i += 1
            while true {
                guard skipTrivia(), i < n else { return false }
                let c = b[i]
                if c == 0x7D { i += 1; return true }
                if c == 0x2C { i += 1; continue }
                if c == 0x2E {   // spread
                    guard skipExpression() else { return false }
                    continue
                }
                if c == 0x5B {   // computed key: the parser skips it as an expression
                    guard skipExpression() else { return false }
                } else if c == 0x22 || c == 0x27 {
                    guard readQuoted().closed else { return false }
                } else if Reader.isIdent(c) {
                    while i < n, Reader.isIdent(b[i]) { i += 1 }
                    if i < n, b[i] >= 0x80 { return false }
                } else {
                    return false
                }
                guard skipTrivia(), i < n else { return false }
                if b[i] == 0x3A {
                    i += 1
                    guard skipValue(depth: depth), skipTrivia(), i < n else { return false }
                }
                if b[i] == 0x2C { i += 1 } else if b[i] != 0x7D { return false }
            }
        }

        private mutating func skipArray(depth: Int) -> Bool {
            i += 1
            while true {
                guard skipTrivia(), i < n else { return false }
                if b[i] == 0x5D { i += 1; return true }
                if b[i] == 0x2C { i += 1; continue }
                guard skipValue(depth: depth), skipTrivia(), i < n else { return false }
                if b[i] == 0x2C { i += 1 } else if b[i] != 0x5D { return false }
            }
        }

        /// The parser's `skipExpression(stopAtComma: true)`: stops before a top-level `,` or an unmatched
        /// closer. False at the end of the script (the parser's caller fails there) or on a literal it
        /// cannot read.
        private mutating func skipExpression() -> Bool {
            var depth = 0
            while i < n {
                switch b[i] {
                case 0x22, 0x27:
                    guard readQuoted().closed else { return false }
                case 0x60:
                    guard let template = readTemplate(), template.closed else { return false }
                case 0x28, 0x5B, 0x7B:
                    depth += 1; i += 1
                case 0x29, 0x5D, 0x7D:
                    if depth == 0 { return true }
                    depth -= 1; i += 1
                case 0x2C:
                    if depth == 0 { return true }
                    i += 1
                default:
                    i += 1
                }
            }
            return false
        }

        // MARK: Literals

        /// Reads and decodes the quoted literal at `b[i]`. `closed` is false when the script ends inside it
        /// (`i` is then at the end) or when an escape is odd (`odd` is set).
        mutating func readQuoted() -> (bytes: [UInt8], closed: Bool) {
            let quote = b[i]
            i += 1
            var out: [UInt8] = []
            while i < n {
                let c = b[i]
                i += 1
                if c == quote { return (out, true) }
                if c == 0x5C {
                    guard i < n else { break }
                    guard Reader.appendEscape(b, &i, end: n, to: &out) else { odd = true; return (out, false) }
                } else {
                    out.append(c)
                }
            }
            i = n
            return (out, false)
        }

        /// Reads the template literal at `b[i]`. Its end is found as the parser's `skipTemplate` finds it
        /// (a backslash skips the next byte); then the body is decoded as `decodeTemplate` does. Nil for
        /// `${}` (the parser keeps such a value as source text) or an odd escape (`odd` is set).
        mutating func readTemplate() -> (bytes: [UInt8], closed: Bool)? {
            i += 1
            let start = i
            while i < n {
                let c = b[i]
                if c == 0x60 {
                    i += 1
                    return decodeTemplate(start, i - 1).map { ($0, true) }
                }
                if c == 0x24, i + 1 < n, b[i + 1] == 0x7B { return nil }
                i += c == 0x5C ? 2 : 1
            }
            i = n
            return decodeTemplate(start, n).map { ($0, false) }
        }

        private mutating func decodeTemplate(_ from: Int, _ end: Int) -> [UInt8]? {
            var out: [UInt8] = []
            var k = from
            while k < end {
                let c = b[k]
                k += 1
                if c == 0x5C, k < end {
                    guard Reader.appendEscape(b, &k, end: end, to: &out) else { odd = true; return nil }
                } else {
                    out.append(c)
                }
            }
            return out
        }

        /// Decodes the escape whose letter is at `b[k]` (after a backslash), as the parser's `appendEscape`.
        /// False when a `\x` or `\u` escape has a non-ASCII byte where the parser reads hex digits: it reads
        /// them as Characters and also takes fullwidth digits.
        static func appendEscape(_ b: UnsafeBufferPointer<UInt8>, _ k: inout Int, end: Int,
                                 to out: inout [UInt8]) -> Bool {
            let e = b[k]
            k += 1
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "0"): out.append(0x00)
            case 0x0A: break
            case 0x0D:
                if k < end, b[k] == 0x0A { k += 1 } else { out.append(0x0D) }
            case UInt8(ascii: "x"):
                guard isASCII(b, from: k, count: 2, end: end) else { return false }
                if let v = hex(b, &k, 2, end: end) { append(v, to: &out) }
            case UInt8(ascii: "u"):
                if k < end, b[k] == 0x7B {
                    k += 1
                    let from = k
                    while k < end, b[k] != 0x7D { k += 1 }
                    let text = String(decoding: b[from..<k], as: UTF8.self)
                    if k < end { k += 1 }
                    if let v = UInt32(text, radix: 16) { append(v, to: &out) }
                } else {
                    guard isASCII(b, from: k, count: 4, end: end) else { return false }
                    if let v = hex(b, &k, 4, end: end) { append(v, to: &out) }
                }
            default:
                out.append(e)
            }
            return true
        }

        private static func isASCII(_ b: UnsafeBufferPointer<UInt8>, from k: Int, count: Int, end: Int) -> Bool {
            var p = k
            while p < Swift.min(k + count, end) {
                if b[p] >= 0x80 { return false }
                p += 1
            }
            return true
        }

        private static func hex(_ b: UnsafeBufferPointer<UInt8>, _ k: inout Int, _ count: Int, end: Int) -> UInt32? {
            guard k + count <= end else { return nil }
            var v: UInt32 = 0
            for p in k..<(k + count) {
                guard let d = Character(UnicodeScalar(b[p])).hexDigitValue else { return nil }
                v = v * 16 + UInt32(d)
            }
            k += count
            return v
        }

        private static func append(_ value: UInt32, to out: inout [UInt8]) {
            if let scalar = Unicode.Scalar(value) { out.append(contentsOf: Array(String(Character(scalar)).utf8)) }
        }

        // MARK: Characters

        /// True when `b[0...end]` (and the byte after it) holds a spot where the parser's Characters and
        /// these bytes differ: a scalar that merges with a neighbouring ASCII byte into one Character (a
        /// combining mark or joiner after it, a prepended mark before it), or U+1FEF, which Swift compares
        /// equal to "`". Only scalars from U+0300 up can merge.
        func hasCharacterHazard(through end: Int) -> Bool {
            guard let base = b.baseAddress else { return false }
            let raw = UnsafeRawPointer(base)
            let limit = Swift.min(end + 2, n)
            var k = 0
            while k < limit {
                // ASCII runs, eight bytes at a time.
                while k + 8 <= limit, raw.loadUnaligned(fromByteOffset: k, as: UInt64.self) & 0x8080_8080_8080_8080 == 0 {
                    k += 8
                }
                guard k < limit else { break }
                let c = b[k]
                guard c >= 0x80 else { k += 1; continue }
                let to = Swift.min(k + (c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2), n)
                if c == 0xE1, to - k == 3, b[k + 1] == 0xBF, b[k + 2] == 0xAF { return true }   // U+1FEF
                if c >= 0xCC {
                    if k > 0, b[k - 1] < 0x80, Reader.isOneCharacter([0x41] + b[k..<to]) { return true }
                    if to < n, b[to] < 0x80, Reader.isOneCharacter(Array(b[k..<to]) + [0x41]) { return true }
                }
                k = to
            }
            return false
        }

        private static func isOneCharacter(_ bytes: [UInt8]) -> Bool {
            String(decoding: bytes, as: UTF8.self).count == 1
        }
    }
}
