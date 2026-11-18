import Foundation

/// How a tool invocation ended (spec §6.2). `unknown` = the source never records results (Cursor).
enum ToolStatus: Equatable, Sendable {
    case success, failed(exitCode: Int?), rejected, interrupted, noResult, pending, unknown
}

/// The cheap status pass (spec §6.2 pass 1, §6.8 Errors filter). It reads sidecars, flags,
/// dispositions and short header lines. It decodes no output body. Codex code mode reads only
/// each chunk's metadata, the keys before its `output` (spec §6.8).
///
/// Precedence:
/// 1. No output: Cursor → `unknown`. A turn_aborted or interrupt notice after the call in its
///    turn → `interrupted`. No later turn in the session → `pending`. Otherwise `noResult`.
/// 2. Exit code. A sidecar `exitCode` on any member block wins. Codex code mode (`exec`): the
///    first chunk with a non-zero `exit_code` → `failed(exitCode: N)`, except exit 1 with an
///    empty `output` (no matches); a `Script failed` header → `failed(exitCode: nil)`. Other
///    tools: the exit forms on the first line of each output (Codex `Chunk ID:` / `Wall time:`
///    envelope lines before it are skipped), and `<exit_code>N</exit_code>` in the first 200
///    bytes. Exit 0 → `success`. A grep-family command with exit 1 and an empty body →
///    `success` ("no matches"). Other codes → `failed`.
/// 3. A `rejected` disposition → `rejected`.
/// 4. `isErrorOutput`, a `runtimeError` disposition or `sidecar.isError` → `failed(exitCode: nil)`.
/// 5. `sidecar.interrupted` → `interrupted`.
/// 6. A "Process running with session ID" / "Script running with cell ID" header, or a code-mode
///    chunk with a `session_id` and no `exit_code` → `pending` (spec §7.4).
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
        status(call: call, outputs: outputs, source: source, laterBlocksExist: laterBlocksExist,
               turnAbortedAfter: turnAbortedAfter, precomputedCodeModeFacts: nil)
    }

    /// `precomputedCodeModeFacts`: one entry per output, already read by
    /// `ToolInvocationIndex.build` for a code-mode call, so the chunks are scanned once.
    static func status(call: SessionTranscriptBuilder.LogicalBlock?,
                       outputs: [SessionTranscriptBuilder.LogicalBlock],
                       source: SessionSource,
                       laterBlocksExist: Bool,
                       turnAbortedAfter: Bool,
                       precomputedCodeModeFacts: [CodeModeFacts]?) -> ToolStatus {
        guard !outputs.isEmpty else {
            if source == .cursor { return .unknown }
            if turnAbortedAfter { return .interrupted }
            return laterBlocksExist ? .noResult : .pending
        }

        let codeMode = isCodeMode(toolName: call?.toolName, source: source)
        if let code = sidecarExitCode(call: call, outputs: outputs) {
            return status(exitCode: code, call: call, outputs: outputs, isCodeMode: codeMode)
        }
        var hasRunningChunk = false
        if codeMode {
            let facts = precomputedCodeModeFacts ?? outputs.map { codeModeFacts(in: $0.text) }
            if let code = facts.lazy.compactMap(\.failureExitCode).first { return .failed(exitCode: code) }
            if outputs.contains(where: { hasScriptFailedHeader($0.text) }) { return .failed(exitCode: nil) }
            hasRunningChunk = facts.contains { $0.hasRunningChunk }
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
        if hasRunningChunk || outputs.contains(where: { runningProcessID(in: $0.text) != nil }) { return .pending }
        return .success
    }

    /// Codex code mode: the custom tool `exec`, whose output is a header plus JSON chunk items.
    static func isCodeMode(toolName: String?, source: SessionSource) -> Bool {
        source == .codex && toolName == "exec"
    }

    /// Calls that poll a running process or cell. They never own a process (Task 9 resolves a
    /// poll to the command that started the process).
    static func isPoll(toolName: String?) -> Bool {
        toolName == "write_stdin" || toolName == "wait"
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

    private static let scriptFailedHeader = Array("script failed".utf8)

    /// What the probe reads from one code-mode output's chunk metadata.
    struct CodeModeFacts: Equatable, Sendable {
        /// The first chunk exit code that is a failure: non-zero, and not exit 1 with an empty
        /// `output` (a grep-family "no matches").
        var failureExitCode: Int?
        /// A chunk has a `session_id` and no `exit_code`: its process still runs.
        var hasRunningChunk = false
        /// Every chunk `session_id`, in order.
        var sessionIDs: [String] = []
        /// Every chunk's metadata, in order (Task 9: per-command status and poll targets).
        var chunks: [ChunkFacts] = []
    }

    /// The metadata of one code-mode chunk: the keys before its `output`.
    struct ChunkFacts: Equatable, Sendable {
        var exitCode: Int?
        var sessionID: String?
        /// The chunk's `output` is the empty string.
        var outputIsEmpty = false

        /// The chunk's own status: exit 0, or exit 1 with an empty `output` (a search with no
        /// matches), is a success; another code is a failure. Nil without an exit code (the
        /// process still runs, or the chunk does not say).
        var status: ToolStatus? {
            guard let exitCode else { return nil }
            if exitCode == 0 || (exitCode == 1 && outputIsEmpty) { return .success }
            return .failed(exitCode: exitCode)
        }
    }

    /// Chunk metadata is short; a chunk's `output` key past this many bytes ends its metadata.
    private static let chunkMetadataLimit = 512
    /// `"chunk_id"` and `\"chunk_id\"` after the opening `{` of a chunk item.
    private static let plainChunkTail = Array(#""chunk_id""#.utf8)
    private static let encodedChunkTail = Array(#"\"chunk_id\""#.utf8)
    private static let plainOutputKey = Array(#""output":"#.utf8)
    private static let encodedOutputKey = Array(#"\"output\":"#.utf8)
    private static let plainEmptyString = Array("\"\"".utf8)
    private static let encodedEmptyString = Array(#"\"\""#.utf8)
    private static let exitCodeName = Array("exit_code".utf8)
    private static let sessionIDName = Array("session_id".utf8)

    /// Reads every chunk item in a code-mode output: `{"chunk_id":…}` and the JSON-encoded string
    /// form `"{\"chunk_id\":…}"`. Content items are joined with no separator, so a chunk can
    /// start anywhere. Only the metadata before the chunk's `output` key is read (Codex writes
    /// `exit_code` and `session_id` there), so text inside an output body is never taken for a
    /// chunk fact. The scan jumps between `{` bytes (rare) with `memchr`.
    static func codeModeFacts(in text: String) -> CodeModeFacts {
        withUTF8(text) { buf -> CodeModeFacts in
            var facts = CodeModeFacts()
            guard let base = buf.baseAddress else { return facts }
            var from = 0
            while from < buf.count,
                  let found = memchr(base + from, Int32(UInt8(ascii: "{")), buf.count - from) {
                let brace = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                from = brace + 1
                guard let chunk = chunkStart(buf, brace: brace) else { continue }
                let window = min(buf.count, chunk.start + chunkMetadataLimit)
                let outputKey = chunk.encoded ? encodedOutputKey : plainOutputKey
                let outputAt = find(outputKey, in: buf, from: chunk.start, to: window)
                let metadata = chunk.start..<(outputAt ?? window)
                let exitCode = chunkValueStart(buf, metadata, key: exitCodeName).flatMap { start -> Int? in
                    var i = start
                    return parseInt(buf, &i, end: metadata.upperBound)
                }
                let sessionID = chunkValueStart(buf, metadata, key: sessionIDName).flatMap {
                    chunkToken(buf, from: $0, end: metadata.upperBound)
                }
                var outputIsEmpty = false
                if let outputAt {
                    var i = outputAt + outputKey.count
                    skipSpaces(buf, &i, end: buf.count)
                    outputIsEmpty = matches(buf, at: i, chunk.encoded ? encodedEmptyString : plainEmptyString)
                }
                if let exitCode, exitCode != 0, !(exitCode == 1 && outputIsEmpty), facts.failureExitCode == nil {
                    facts.failureExitCode = exitCode
                }
                if let sessionID {
                    facts.sessionIDs.append(sessionID)
                    if exitCode == nil { facts.hasRunningChunk = true }
                }
                facts.chunks.append(ChunkFacts(exitCode: exitCode, sessionID: sessionID, outputIsEmpty: outputIsEmpty))
                from = max(from, metadata.upperBound)
            }
            return facts
        }
    }

    /// The start of a chunk item whose `{` sits at `brace`. A plain item is `{"chunk_id"` (an
    /// output body cannot hold that: its quotes are escaped). A JSON-encoded item is
    /// `"{\"chunk_id\"` that opens an item: at the start, after a newline, or right after the
    /// previous item's closing `}` or `"`. That rules out a body that starts with the same text.
    private static func chunkStart(_ buf: UnsafeBufferPointer<UInt8>, brace: Int) -> (start: Int, encoded: Bool)? {
        if matches(buf, at: brace + 1, plainChunkTail) { return (brace, false) }
        guard brace >= 1, buf[brace - 1] == quote, matches(buf, at: brace + 1, encodedChunkTail) else { return nil }
        if brace >= 2 {
            let before = buf[brace - 2]
            guard before == newline || before == closingBrace || before == quote else { return nil }
        }
        return (brace - 1, true)
    }

    /// Where the value of `key` starts inside chunk metadata: after `"key":` or `\"key\":`.
    private static func chunkValueStart(_ buf: UnsafeBufferPointer<UInt8>, _ metadata: Range<Int>,
                                        key: [UInt8]) -> Int? {
        var from = metadata.lowerBound
        while let hit = find(key, in: buf, from: from, to: metadata.upperBound) {
            from = hit + 1
            guard hit > metadata.lowerBound, buf[hit - 1] == quote else { continue }
            var i = hit + key.count
            if i < metadata.upperBound, buf[i] == backslash { i += 1 }
            guard i < metadata.upperBound, buf[i] == quote else { continue }
            i += 1
            skipSpaces(buf, &i, end: metadata.upperBound)
            guard i < metadata.upperBound, buf[i] == colon else { continue }
            i += 1
            skipSpaces(buf, &i, end: metadata.upperBound)
            return i
        }
        return nil
    }

    /// A number or (escaped) string value token at `from`.
    private static func chunkToken(_ buf: UnsafeBufferPointer<UInt8>, from: Int, end: Int) -> String? {
        var start = from
        if start < end, buf[start] == backslash { start += 1 }
        if start < end, buf[start] == quote { start += 1 }
        var stop = start
        while stop < end, isTokenByte(buf[stop]) { stop += 1 }
        guard stop > start else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: buf[start..<stop]), as: UTF8.self)
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
    private static let closingBrace = UInt8(ascii: "}")

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// Exact byte match of `bytes` at `index`.
    private static func matches(_ buf: UnsafeBufferPointer<UInt8>, at index: Int, _ bytes: [UInt8]) -> Bool {
        guard index >= 0, index + bytes.count <= buf.count else { return false }
        var k = 0
        while k < bytes.count {
            if buf[index + k] != bytes[k] { return false }
            k += 1
        }
        return true
    }

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

    /// The first offset of `needle` in `buf[from..<end]` (`memmem`); `end` defaults to the buffer end.
    private static func find(_ needle: [UInt8], in buf: UnsafeBufferPointer<UInt8>, from: Int, to end: Int? = nil) -> Int? {
        let stop = min(end ?? buf.count, buf.count)
        guard let base = buf.baseAddress, from >= 0, from < stop, !needle.isEmpty else { return nil }
        return needle.withUnsafeBytes { little -> Int? in
            guard let hit = memmem(base + from, stop - from, little.baseAddress, little.count) else {
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
