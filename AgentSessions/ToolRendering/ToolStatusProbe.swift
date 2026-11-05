import Foundation

/// How a tool invocation ended (spec §6.2). `unknown` = the source never records results (Cursor).
enum ToolStatus: Equatable, Sendable {
    case success, failed(exitCode: Int?), rejected, interrupted, noResult, pending, unknown
}

/// The cheap status pass (spec §6.2 pass 1, §6.8 Errors filter). It reads sidecars, flags,
/// dispositions and short header lines. It decodes no output body. The one whole-text read is
/// the Codex code-mode `"exit_code":` substring scan (spec §6.8).
///
/// Precedence:
/// 1. No output: Cursor → `unknown`. A turn_aborted or interrupt notice after the call in its
///    turn → `interrupted`. No later turn in the session → `pending`. Otherwise `noResult`.
/// 2. Exit code. A sidecar `exitCode` on any member block wins. Codex code mode (`exec`): any
///    non-zero `"exit_code":` value → `failed(exitCode: N)`, a `Script failed` header →
///    `failed(exitCode: nil)`. Other tools: the exit forms on the first line of each output
///    (Codex `Chunk ID:` / `Wall time:` envelope lines before it are skipped), and
///    `<exit_code>N</exit_code>` in the first 200 bytes. Exit 0 → `success`. A grep-family
///    command with exit 1 and an empty body → `success` ("no matches"). Other codes → `failed`.
/// 3. A `rejected` disposition → `rejected`.
/// 4. `isErrorOutput`, a `runtimeError` disposition or `sidecar.isError` → `failed(exitCode: nil)`.
/// 5. `sidecar.interrupted` → `interrupted`.
/// 6. A "Process running with session ID" / "Script running with cell ID" header → `pending` (spec §7.4).
/// 7. Otherwise `success`.
enum ToolStatusProbe {

    /// - Parameters:
    ///   - laterBlocksExist: true when the session continues past the call's turn.
    ///   - turnAbortedAfter: true when a turn_aborted or interrupt notice follows the call in its turn.
    static func status(call: SessionTranscriptBuilder.LogicalBlock?,
                       outputs: [SessionTranscriptBuilder.LogicalBlock],
                       source: SessionSource,
                       laterBlocksExist: Bool,
                       turnAbortedAfter: Bool) -> ToolStatus {
        guard !outputs.isEmpty else {
            if source == .cursor { return .unknown }
            if turnAbortedAfter { return .interrupted }
            return laterBlocksExist ? .noResult : .pending
        }

        let isCodeMode = source == .codex && call?.toolName == "exec"
        if let code = sidecarExitCode(call: call, outputs: outputs) {
            return status(exitCode: code, call: call, outputs: outputs, isCodeMode: isCodeMode)
        }
        if isCodeMode {
            for output in outputs {
                if let code = codeModeNonZeroExitCode(in: output.text) { return .failed(exitCode: code) }
            }
            if outputs.contains(where: { hasScriptFailedHeader($0.text) }) { return .failed(exitCode: nil) }
        } else if let code = headerExitCode(outputs: outputs) {
            return status(exitCode: code, call: call, outputs: outputs, isCodeMode: false)
        }

        if outputs.contains(where: { $0.toolDisposition == .rejected }) { return .rejected }
        if outputs.contains(where: { $0.isErrorOutput || $0.toolDisposition == .runtimeError
            || $0.toolSidecar?.isError == true }) {
            return .failed(exitCode: nil)
        }
        if call?.toolSidecar?.interrupted == true
            || outputs.contains(where: { $0.toolSidecar?.interrupted == true }) {
            return .interrupted
        }
        if outputs.contains(where: { runningProcessID(in: $0.text) != nil }) { return .pending }
        return .success
    }

    // MARK: Exit codes

    private static func status(exitCode code: Int,
                               call: SessionTranscriptBuilder.LogicalBlock?,
                               outputs: [SessionTranscriptBuilder.LogicalBlock],
                               isCodeMode: Bool) -> ToolStatus {
        if code == 0 { return .success }
        if code == 1, !isCodeMode, outputs.allSatisfy({ isEmptyBody($0.text) }), isGrepFamily(call) {
            return .success
        }
        return .failed(exitCode: code)
    }

    /// The first non-zero sidecar exit code over the call and its outputs, else 0 when one is 0.
    private static func sidecarExitCode(call: SessionTranscriptBuilder.LogicalBlock?,
                                        outputs: [SessionTranscriptBuilder.LogicalBlock]) -> Int? {
        var sawZero = false
        if let code = call?.toolSidecar?.exitCode {
            if code != 0 { return code }
            sawZero = true
        }
        for output in outputs {
            guard let code = output.toolSidecar?.exitCode else { continue }
            if code != 0 { return code }
            sawZero = true
        }
        return sawZero ? 0 : nil
    }

    /// The first non-zero header exit code over the outputs, else 0 when one is 0.
    private static func headerExitCode(outputs: [SessionTranscriptBuilder.LogicalBlock]) -> Int? {
        var sawZero = false
        for output in outputs {
            guard let code = headerExitCode(in: output.text) else { continue }
            if code != 0 { return code }
            sawZero = true
        }
        return sawZero ? 0 : nil
    }

    /// Bytes read from the start of an output for header facts. Headers are short; a body
    /// mention past this window is not a header.
    static let headerScanLimit = 512
    /// `<exit_code>N</exit_code>` (Claude `TaskOutput`) counts only in this many leading bytes.
    private static let exitTagScanLimit = 200

    /// The exit code on the first line of `text`, after up to three Codex envelope lines
    /// (`Chunk ID:`, `Wall time:`) and blank lines; else a `<exit_code>N</exit_code>` tag in the
    /// first 200 bytes. Nil when neither is present.
    static func headerExitCode(in text: String) -> Int? {
        withHead(text, limit: headerScanLimit) { buf -> Int? in
            var lineStart = 0
            var skipped = 0
            while lineStart < buf.count {
                let lineEnd = indexOf(newline, in: buf, from: lineStart) ?? buf.count
                let line = trimmed(buf, lineStart, lineEnd)
                if line.isEmpty || (skipped < 3 && isEnvelopeLine(buf, line)) {
                    if !line.isEmpty { skipped += 1 }
                    lineStart = lineEnd + 1
                    continue
                }
                if let code = exitCode(buf, line) { return code }
                break
            }
            let tagWindow = UnsafeBufferPointer(rebasing: buf.prefix(exitTagScanLimit))
            guard let hit = find(exitTagOpen, in: tagWindow, from: 0) else { return nil }
            var i = hit + exitTagOpen.count
            skipSpaces(tagWindow, &i, end: tagWindow.count)
            return parseInt(tagWindow, &i, end: tagWindow.count)
        }
    }

    /// `Exit code N` and `Exit code: N`.
    private static let exitCodePrefix = Array("exit code".utf8)
    /// Claude keeps a failed Bash result's `toolUseResult` string: `Error: Exit code N`.
    private static let errorExitCodePrefix = Array("error: exit code".utf8)
    /// Lowercased exit-line prefixes. Each starts with "p", "c" or "e".
    private static let exitLinePrefixes: [[UInt8]] = [
        "process exited with code",
        "command exited with code",
        "error: command failed (exit code:",
        "exit:",
    ].map { Array($0.utf8) } + [exitCodePrefix, errorExitCodePrefix]
    private static let exitTagOpen = Array("<exit_code>".utf8)

    /// The code in one trimmed header line (case-insensitive): `Exit code N` / `Exit code: N`
    /// (also after `Error: `), `Process exited with code N`, `exit: N`,
    /// `Command exited with code N.`, `Error: Command failed (exit code: N)`.
    private static func exitCode(_ buf: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> Int? {
        guard let first = line.first.map({ lower(buf[$0]) }),
              first == UInt8(ascii: "p") || first == UInt8(ascii: "c") || first == UInt8(ascii: "e")
        else { return nil }
        for prefix in exitLinePrefixes where hasPrefix(buf, line, prefix) {
            var i = line.lowerBound + prefix.count
            skipSpaces(buf, &i, end: line.upperBound)
            if prefix == exitCodePrefix || prefix == errorExitCodePrefix, i < line.upperBound, buf[i] == colon {
                i += 1
                skipSpaces(buf, &i, end: line.upperBound)
            }
            return parseInt(buf, &i, end: line.upperBound)
        }
        return nil
    }

    private static let envelopePrefixes: [[UInt8]] = ["chunk id:", "wall time:"].map { Array($0.utf8) }
    private static let outputLabel = Array("output:".utf8)
    private static let originalTokenCountPrefix = Array("original token count:".utf8)

    private static func isEnvelopeLine(_ buf: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> Bool {
        envelopePrefixes.contains { hasPrefix(buf, line, $0) }
    }

    // MARK: Codex code mode

    private static let exitCodeKey = Array("exit_code".utf8)
    private static let scriptFailedHeader = Array("script failed".utf8)

    /// The first non-zero `"exit_code": N` value in `text` (also inside a JSON-encoded string,
    /// `\"exit_code\":N`). A substring scan: no JSON decode. It jumps between `x` bytes (rare in
    /// real Codex output) with `memchr`, which is about 5x faster than `memmem` there.
    static func codeModeNonZeroExitCode(in text: String) -> Int? {
        let key = exitCodeKey
        return withUTF8(text) { buf -> Int? in
            guard let base = buf.baseAddress else { return nil }
            let anchorOffset = 1   // the `x` of "exit_code"
            var from = anchorOffset
            while from < buf.count,
                  let found = memchr(base + from, Int32(UInt8(ascii: "x")), buf.count - from) {
                let anchor = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                from = anchor + 1
                let hit = anchor - anchorOffset
                guard hit + key.count <= buf.count, buf[hit + 4] == UInt8(ascii: "_"),
                      key.withUnsafeBufferPointer({ memcmp(base + hit, $0.baseAddress!, $0.count) }) == 0
                else { continue }
                guard hit > 0, buf[hit - 1] == quote else { continue }
                var i = hit + key.count
                if i < buf.count, buf[i] == backslash { i += 1 }
                guard i < buf.count, buf[i] == quote else { continue }
                i += 1
                skipSpaces(buf, &i, end: buf.count)
                guard i < buf.count, buf[i] == colon else { continue }
                i += 1
                skipSpaces(buf, &i, end: buf.count)
                if let code = parseInt(buf, &i, end: buf.count), code != 0 { return code }
            }
            return nil
        }
    }

    /// True when `text` starts (after whitespace) with the code-mode `Script failed` header.
    private static func hasScriptFailedHeader(_ text: String) -> Bool {
        withHead(text, limit: 64) { buf -> Bool in
            var start = 0
            while start < buf.count, isSpace(buf[start]) || buf[start] == newline || buf[start] == carriageReturn {
                start += 1
            }
            return hasPrefix(buf, start..<buf.count, scriptFailedHeader)
        }
    }

    // MARK: Running processes

    private static let runningWith = Array(" running with ".utf8)
    /// (text before " running with ", text after it) for the two running headers.
    private static let runningMarkers: [([UInt8], [UInt8])] = [
        (Array("Process".utf8), Array("session ID ".utf8)),
        (Array("Script".utf8), Array("cell ID ".utf8)),
    ]

    /// The session or cell id from a "Process running with session ID N" or
    /// "Script running with cell ID N" header in the first `headerScanLimit` bytes.
    static func runningProcessID(in text: String) -> String? {
        withHead(text, limit: headerScanLimit) { buf -> String? in
            var from = 0
            while let hit = find(runningWith, in: buf, from: from) {
                from = hit + 1
                let after = hit + runningWith.count
                for (before, idLabel) in runningMarkers {
                    guard hit >= before.count, after + idLabel.count <= buf.count,
                          zip(buf[(hit - before.count)..<hit], before).allSatisfy({ $0 == $1 }),
                          zip(buf[after..<(after + idLabel.count)], idLabel).allSatisfy({ $0 == $1 })
                    else { continue }
                    let start = after + idLabel.count
                    var end = start
                    while end < buf.count, isTokenByte(buf[end]) { end += 1 }
                    guard end > start else { continue }
                    return String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                }
            }
            return nil
        }
    }

    // MARK: Grep family

    private static let grepFamily: Set<Substring> = ["rg", "grep", "egrep", "fgrep", "ag", "ack"]
    private static let shellWrappers: Set<Substring> = ["bash", "sh", "zsh"]

    /// True when the call's command, after a `bash|sh|zsh -lc|-c` wrapper and a leading
    /// `cd X &&` / `cd X;`, starts with rg, grep, egrep, fgrep, ag, ack or `git grep`.
    static func isGrepFamily(_ call: SessionTranscriptBuilder.LogicalBlock?) -> Bool {
        guard let call else { return false }
        return isGrepFamily(command: TranscriptToolSummary.summary(toolName: call.toolName,
                                                                   toolInput: call.toolInput))
    }

    static func isGrepFamily(command: String) -> Bool {
        var rest = Substring(command).drop(while: \.isWhitespace)
        let head = rest.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        if head.count == 3, shellWrappers.contains(baseName(head[0])), head[1] == "-lc" || head[1] == "-c" {
            rest = head[2].drop(while: \.isWhitespace)
            if let first = rest.first, first == "'" || first == "\"" { rest = rest.dropFirst() }
        }
        if rest.hasPrefix("cd ") {
            let cuts = [rest.range(of: "&&"), rest.range(of: ";")].compactMap { $0 }
            guard let cut = cuts.min(by: { $0.lowerBound < $1.lowerBound }) else { return false }
            rest = rest[cut.upperBound...].drop(while: \.isWhitespace)
        }
        let words = rest.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let first = words.first.map(baseName) else { return false }
        if grepFamily.contains(first) { return true }
        return first == "git" && words.count > 1 && words[1] == "grep"
    }

    private static func baseName(_ word: Substring) -> Substring {
        word.split(separator: "/", omittingEmptySubsequences: true).last ?? word
    }

    /// True when `text` is only header lines (exit forms, `Output:`, Codex envelope lines)
    /// and whitespace.
    static func isEmptyBody(_ text: String) -> Bool {
        withHead(text, limit: headerScanLimit + 1) { buf -> Bool in
            guard buf.count <= headerScanLimit else { return false }
            var lineStart = 0
            while lineStart < buf.count {
                let lineEnd = indexOf(newline, in: buf, from: lineStart) ?? buf.count
                let line = trimmed(buf, lineStart, lineEnd)
                lineStart = lineEnd + 1
                if line.isEmpty || isEnvelopeLine(buf, line) || exitCode(buf, line) != nil
                    || hasPrefix(buf, line, originalTokenCountPrefix)
                    || (line.count == outputLabel.count && hasPrefix(buf, line, outputLabel)) {
                    continue
                }
                return false
            }
            return true
        }
    }

    // MARK: Bytes

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    private static func lower(_ byte: UInt8) -> UInt8 { (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }

    /// `start..<end` without leading/trailing spaces, tabs and carriage returns.
    private static func trimmed(_ buf: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Range<Int> {
        var from = start
        var to = end
        while from < to, isSpace(buf[from]) || buf[from] == carriageReturn { from += 1 }
        while to > from, isSpace(buf[to - 1]) || buf[to - 1] == carriageReturn { to -= 1 }
        return from..<to
    }

    /// Case-insensitive (ASCII) prefix test against a lowercased `prefix`.
    private static func hasPrefix(_ buf: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ prefix: [UInt8]) -> Bool {
        guard range.count >= prefix.count else { return false }
        var k = 0
        while k < prefix.count {
            if lower(buf[range.lowerBound + k]) != prefix[k] { return false }
            k += 1
        }
        return true
    }

    private static func skipSpaces(_ buf: UnsafeBufferPointer<UInt8>, _ i: inout Int, end: Int) {
        while i < end, isSpace(buf[i]) { i += 1 }
    }

    /// An optional `-` and 1–9 digits at `i`, before `end`.
    private static func parseInt(_ buf: UnsafeBufferPointer<UInt8>, _ i: inout Int, end: Int) -> Int? {
        var negative = false
        if i < end, buf[i] == UInt8(ascii: "-") { negative = true; i += 1 }
        var value = 0
        var digits = 0
        while i < end, digits < 9, buf[i] >= 0x30, buf[i] <= 0x39 {
            value = value * 10 + Int(buf[i] - 0x30)
            digits += 1
            i += 1
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    private static func indexOf(_ byte: UInt8, in buf: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard let base = buf.baseAddress, from < buf.count,
              let hit = memchr(base + from, Int32(byte), buf.count - from) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
    }

    /// The first offset of `needle` in `buf` at or after `from` (`memmem`).
    private static func find(_ needle: [UInt8], in buf: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard let base = buf.baseAddress, from >= 0, from < buf.count, !needle.isEmpty else { return nil }
        return needle.withUnsafeBytes { little -> Int? in
            guard let hit = memmem(base + from, buf.count - from, little.baseAddress, little.count) else {
                return nil
            }
            return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Runs `body` over at most the first `limit` UTF-8 bytes of `text`. A native string is read in
    /// place. A bridged `NSString` (parser output) has its head transcoded by one CoreFoundation
    /// call: walking its UTF-8 view byte by byte is far slower.
    private static func withHead<R>(_ text: String, limit: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = text.utf8.withContiguousStorageIfAvailable({
            body(UnsafeBufferPointer(rebasing: $0.prefix(limit)))
        }) {
            return result
        }
        let string = text as NSString as CFString
        let units = min(CFStringGetLength(string), limit)
        var head = [UInt8](repeating: 0, count: limit)
        var used = 0
        _ = CFStringGetBytes(string, CFRange(location: 0, length: units), CFStringBuiltInEncodings.UTF8.rawValue,
                             0, false, &head, limit, &used)
        return head.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0.prefix(used))) }
    }

    /// The UTF-16 length of a bridged string, or the UTF-8 length of a native one; both O(1).
    /// Used only to skip long text before a short-marker check.
    static func cheapLength(_ text: String) -> Int {
        text.utf8.withContiguousStorageIfAvailable { $0.count } ?? (text as NSString).length
    }

    /// Runs `body` over all UTF-8 bytes of `text`, copying only when the string is not contiguous UTF-8.
    private static func withUTF8<R>(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        var copy = text
        copy.makeContiguousUTF8()
        if let result = copy.utf8.withContiguousStorageIfAvailable(body) { return result }
        return Array(copy.utf8).withUnsafeBufferPointer(body)
    }
}
