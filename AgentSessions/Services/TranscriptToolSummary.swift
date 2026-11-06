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
            if toolName == "exec", let cmd = execScriptCommand(prefix) { return cmd }
            let fields = LargeInputScanner.scan(prefix)
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
    private static func execScriptCommand(_ script: String) -> String? {
        if let fast = ExecFirstCommandScan.firstCommand(in: script) { return fast }
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

    private static func boundedPrefix(_ input: String) -> String {
        String(decoding: input.utf8.prefix(scanPrefixBytes), as: UTF8.self)
    }

    /// `summary` for a large input: same priority order, fed by a bounded scan of the top-level fields.
    private static func largeInputSummary(toolName: String?, input: String) -> String {
        let prefix = boundedPrefix(input)
        if toolName == "exec", let cmd = execScriptCommand(prefix) { return cmd }
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
/// summaries. It reads the bytes of the first `tools.<name>(`, its `{` object and the first
/// top-level `cmd` key, and decodes that one string literal. It returns nil whenever it cannot decide
/// (no call, computed key, expression value, `${}` in a template, unbalanced input, non-ASCII where
/// syntax is expected); the caller then falls back to `CodexExecScript.parse(_:maxCalls: 1)`.
enum ExecFirstCommandScan {
    static func firstCommand(in script: String) -> String? {
        if let result = script.utf8.withContiguousStorageIfAvailable({ scan($0) }) { return result }
        return Array(script.utf8).withUnsafeBufferPointer { scan($0) }
    }

    private static func isIdent(_ c: UInt8) -> Bool {
        c == 0x5F || c == 0x24 || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>) -> String? {
        let n = b.count
        let needle: [UInt8] = Array("tools.".utf8)
        var search = 0
        while search + needle.count < n {
            // Find "tools."
            var hit = -1
            var k = search
            while k + needle.count <= n {
                if b[k] == needle[0], b[k + 1] == needle[1], b[k + 2] == needle[2], b[k + 3] == needle[3],
                   b[k + 4] == needle[4], b[k + 5] == needle[5] { hit = k; break }
                k += 1
            }
            if hit < 0 { return nil }
            let afterHit = hit + needle.count
            if hit > 0 {
                let prev = b[hit - 1]
                if isIdent(prev) || prev == 0x2E || prev >= 0x80 { search = afterHit; continue }
            }
            var p = afterHit
            while p < n, isIdent(b[p]) { p += 1 }
            guard p > afterHit else { search = afterHit; continue }
            if p < n, b[p] >= 0x80 { return nil }
            while p < n, isSpace(b[p]) { p += 1 }
            guard p < n else { return nil }
            guard b[p] == 0x28 else { search = afterHit; continue }
            var i = p + 1
            return readCommand(b, &i)
        }
        return nil
    }

    /// Skips whitespace and comments. False when a byte the parser would treat differently shows up.
    private static func skipTrivia(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        let n = b.count
        while i < n {
            let c = b[i]
            if isSpace(c) { i += 1 }
            else if c >= 0x80 { return false }
            else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F {
                while i < n, b[i] != 0x0A { i += 1 }
            } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A {
                i += 2
                var closed = false
                while i + 1 < n {
                    if b[i] == 0x2A, b[i + 1] == 0x2F { i += 2; closed = true; break }
                    i += 1
                }
                if !closed { return false }
            } else { return true }
        }
        return true
    }

    /// `i` is just after the call's `(`.
    private static func readCommand(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> String? {
        let n = b.count
        guard skipTrivia(b, &i), i < n, b[i] == 0x7B else { return nil }
        i += 1
        while true {
            guard skipTrivia(b, &i), i < n else { return nil }
            let c = b[i]
            if c == 0x7D { return nil }   // no cmd in the object
            if c == 0x2C { i += 1; continue }
            let key: [UInt8]
            if c == 0x22 || c == 0x27 {
                guard let k = readQuoted(b, &i) else { return nil }
                key = k
            } else if isIdent(c) {
                let from = i
                while i < n, isIdent(b[i]) { i += 1 }
                if i < n, b[i] >= 0x80 { return nil }
                key = Array(b[from..<i])
            } else {
                return nil
            }
            guard skipTrivia(b, &i), i < n else { return nil }
            let isCmd = key == Array("cmd".utf8)
            if b[i] == 0x3A {
                i += 1
                guard skipTrivia(b, &i), i < n else { return nil }
                if isCmd {
                    let bytes: [UInt8]?
                    if b[i] == 0x22 || b[i] == 0x27 { bytes = readQuoted(b, &i) }
                    else if b[i] == 0x60 { bytes = readTemplate(b, &i) }
                    else { bytes = nil }
                    guard let bytes, !bytes.isEmpty else { return nil }
                    // The literal must end the value.
                    guard skipTrivia(b, &i), i < n, b[i] == 0x2C || b[i] == 0x7D else { return nil }
                    return String(decoding: bytes, as: UTF8.self)
                }
                guard skipExpression(b, &i) else { return nil }
            } else if isCmd {
                return nil   // shorthand `{cmd}`
            }
            guard skipTrivia(b, &i), i < n else { return nil }
            if b[i] == 0x2C { i += 1 } else if b[i] != 0x7D { return nil }
        }
    }

    /// Skips a value up to a top-level `,` or an unmatched closer, as the parser's `skipExpression`.
    private static func skipExpression(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        let n = b.count
        var depth = 0
        while i < n {
            let c = b[i]
            switch c {
            case 0x22, 0x27:
                guard readQuoted(b, &i) != nil else { return false }
            case 0x60:
                guard readTemplate(b, &i) != nil else { return false }
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

    /// Reads a quoted literal at `b[i]`; moves `i` past the closing quote. Nil when unterminated.
    private static func readQuoted(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> [UInt8]? {
        let quote = b[i]
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == quote { i += 1; return out }
            i += 1
            if c == 0x5C {
                guard i < b.count else { return nil }
                appendEscape(b, &i, to: &out)
            } else {
                out.append(c)
            }
        }
        return nil
    }

    /// Reads a template literal without `${}` at `b[i] == '`'`. Nil for an interpolation or no end.
    private static func readTemplate(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> [UInt8]? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == 0x60 { i += 1; return out }
            if c == 0x24, i + 1 < b.count, b[i + 1] == 0x7B { return nil }
            i += 1
            if c == 0x5C {
                guard i < b.count else { return nil }
                appendEscape(b, &i, to: &out)
            } else {
                out.append(c)
            }
        }
        return nil
    }

    /// `i` is on the byte after a backslash.
    private static func appendEscape(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int, to out: inout [UInt8]) {
        let e = b[i]
        i += 1
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
            if i < b.count, b[i] == 0x0A { i += 1 } else { out.append(0x0D) }
        case UInt8(ascii: "x"):
            if let v = hex(b, &i, 2) { append(v, to: &out) }
        case UInt8(ascii: "u"):
            if i < b.count, b[i] == 0x7B {
                i += 1
                let from = i
                while i < b.count, b[i] != 0x7D { i += 1 }
                let text = String(decoding: b[from..<i], as: UTF8.self)
                if i < b.count { i += 1 }
                if let v = UInt32(text, radix: 16) { append(v, to: &out) }
            } else if let v = hex(b, &i, 4) {
                append(v, to: &out)
            }
        default:
            out.append(e)
        }
    }

    private static func hex(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int, _ count: Int) -> UInt32? {
        guard i + count <= b.count else { return nil }
        var v: UInt32 = 0
        for k in i..<(i + count) {
            guard let d = Character(UnicodeScalar(b[k])).hexDigitValue else { return nil }
            v = v * 16 + UInt32(d)
        }
        i += count
        return v
    }

    private static func append(_ value: UInt32, to out: inout [UInt8]) {
        if let scalar = Unicode.Scalar(value) { out.append(contentsOf: Array(String(Character(scalar)).utf8)) }
    }
}
