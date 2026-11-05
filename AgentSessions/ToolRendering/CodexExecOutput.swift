import Foundation

/// Maps the output of a Codex code-mode `exec` call (spec §7.4) to status, per-command chunks and loose text.
///
/// The output is a content-item array. Item 0 is a header (`Script completed|failed|running with cell ID N`,
/// `Wall time X seconds`, `Output:`). Later items are an optional truncation header and JSON-line chunks
/// `{chunk_id, wall_time_seconds, exit_code, original_token_count, session_id?, output}`. Anything else
/// (the script's own `text(...)` printing, malformed JSON) is loose text. Nothing here throws or traps
/// (anti-goal A2).
///
/// Pipeline per item: unescape a JSON-encoded string item once → `ToolEnvelopes.lift` (header,
/// truncation warning, "aborted by user") → split the body at `{"chunk_id"` boundaries → decode.
struct CodexExecOutput: Equatable, Sendable {
    enum ScriptStatus: Equatable, Sendable { case completed, failed, running(cellID: String), aborted(seconds: Double) }
    struct Chunk: Equatable, Sendable {
        var exitCode: Int?
        var wallTimeSeconds: Double?
        var originalTokenCount: Int?
        var output: DecodedText
        var facts: [AgentFact]
    }
    var status: ScriptStatus?
    var wallTimeSeconds: Double?
    /// JSON-line records in order.
    var chunks: [Chunk]
    /// Items that are not chunks (custom `text(...)` output), decoded. Nil when there are none.
    var looseText: DecodedText?
    /// Facts from the header and from top-level truncation warnings. The wall time is in `wallTimeSeconds`
    /// and the script status is in `status`, so neither is repeated here.
    var facts: [AgentFact]

    static func parse(value: ToolPayloadValue?, fallback: String?) -> CodexExecOutput {
        var result = CodexExecOutput(status: nil, wallTimeSeconds: nil, chunks: [], looseText: nil, facts: [])
        var loose: [String] = []
        for (index, raw) in itemTexts(value: value, fallback: fallback).enumerated() {
            let text = unescapeOnce(raw)
            let lifted = ToolEnvelopes.lift(text, source: .codex, toolName: "exec")
            if index == 0 { result.status = scriptStatus(of: text) }
            for fact in lifted.facts {
                switch fact.kind {
                case .wallTime(let t):
                    if result.wallTimeSeconds == nil { result.wallTimeSeconds = t }
                case .note(let note):
                    if let seconds = abortedSeconds(note) {
                        result.status = .aborted(seconds: seconds)
                    } else if !note.hasPrefix("Script ") {
                        result.facts.append(fact)
                    }
                default:
                    result.facts.append(fact)
                }
            }
            split(lifted.body, chunks: &result.chunks, loose: &loose)
        }
        let joined = loose.reduce(into: "") { acc, piece in
            if !acc.isEmpty && !acc.hasSuffix("\n") { acc += "\n" }
            acc += piece
        }
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.looseText = ToolTextDecoding.decode(value: nil, fallback: joined)
        }
        return result
    }

    /// Chunk i belongs to call i only when the counts match, every call is `exec_command` or `write_stdin`,
    /// and the script printed no text of its own (loose text means the chunks cannot be trusted to line up).
    static func assign(_ output: CodexExecOutput, to script: CodexExecScript) -> [Int: Chunk] {
        guard !script.calls.isEmpty,
              output.chunks.count == script.calls.count,
              output.looseText == nil,
              script.calls.allSatisfy({ $0.tool == "exec_command" || $0.tool == "write_stdin" })
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: output.chunks.enumerated().map { ($0.offset, $0.element) })
    }

    // MARK: Items

    /// The item texts, in order. Prefers the content-item array; falls back to the joined text as one item.
    private static func itemTexts(value: ToolPayloadValue?, fallback: String?) -> [String] {
        if let value {
            if let parts = ToolJSON.contentItemParts(value) {
                return parts.map {
                    switch $0 {
                    case .text(let t): return t
                    case .image: return "[image]"
                    }
                }
            }
            if case .string(let s) = value { return [s] }
        }
        return fallback.map { [$0] } ?? []
    }

    /// A text that starts with `"` is a JSON-encoded string: unescape it once.
    private static func unescapeOnce(_ text: String) -> String {
        guard text.first(where: { !$0.isWhitespace }) == "\"",
              case .string(let s)? = ToolTextDecoding.decodeJSONString(text, maxDepth: 1) else { return text }
        return s
    }

    // MARK: Status

    private static let scriptHeader = try! NSRegularExpression(pattern: #"^\s*Script (completed|failed|running with cell ID (\S+))"#)
    private static let abortedRegex = try! NSRegularExpression(pattern: #"^aborted by user after ([0-9.]+)s$"#)

    private static func scriptStatus(of text: String) -> ScriptStatus? {
        let head = String(text.prefix(200))
        let ns = head as NSString
        guard let m = scriptHeader.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) else { return nil }
        switch ns.substring(with: m.range(at: 1)) {
        case "completed": return .completed
        case "failed": return .failed
        default: return .running(cellID: m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : "")
        }
    }

    private static func abortedSeconds(_ note: String) -> Double? {
        let ns = note as NSString
        guard let m = abortedRegex.firstMatch(in: note, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Double(ns.substring(with: m.range(at: 1)))
    }

    // MARK: Chunks

    private static let chunkStart = #"{"chunk_id""#

    /// Splits a body at `{"chunk_id"` boundaries. A segment that parses as a chunk object becomes a chunk;
    /// every other segment is loose text.
    private static func split(_ body: String, chunks: inout [Chunk], loose: inout [String]) {
        guard !body.isEmpty else { return }
        var starts: [String.Index] = []
        var cursor = body.startIndex
        while let r = body.range(of: chunkStart, range: cursor..<body.endIndex) {
            starts.append(r.lowerBound)
            cursor = r.upperBound
        }
        guard let first = starts.first else {
            loose.append(body)
            return
        }
        if first > body.startIndex { loose.append(String(body[body.startIndex..<first])) }
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : body.endIndex
            let segment = String(body[start..<end])
            if let chunk = makeChunk(segment) {
                chunks.append(chunk)
            } else {
                loose.append(segment)
            }
        }
    }

    private static func makeChunk(_ segment: String) -> Chunk? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["chunk_id"] != nil else { return nil }
        var facts: [AgentFact] = []
        var decoded = DecodedText(text: "", sourceMap: [], shape: .plain)
        switch object["output"] {
        case let s as String:
            let lifted = ToolEnvelopes.lift(s, source: .codex, toolName: "exec")
            facts = lifted.facts
            decoded = ToolTextDecoding.decode(value: nil, fallback: lifted.body)
        case let other? where !(other is NSNull):
            if let v = ToolPayloadValue(jsonObject: other) { decoded = ToolTextDecoding.decode(value: v, fallback: nil) }
        default:
            break
        }
        return Chunk(exitCode: int(object["exit_code"]),
                     wallTimeSeconds: (object["wall_time_seconds"] as? NSNumber)?.doubleValue,
                     originalTokenCount: int(object["original_token_count"]),
                     output: decoded,
                     facts: facts)
    }

    private static func int(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }
}
