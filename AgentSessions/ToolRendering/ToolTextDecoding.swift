import Foundation

/// Maps a rendered range back to the range of the string the text decoders started from (the
/// "source": the text value, the joined content items, or the fallback string). UTF-16 offsets.
/// Entries are monotone: rendered ranges are in order and do not overlap, and source locations
/// never go backwards. A rendered character that the decoder inserted (pretty-print indentation,
/// the `[image]` marker, the binary placeholder) has a zero-length source range at the place it was
/// inserted. When a decoder cannot align characters (for example it re-ordered JSON keys), one
/// coarse entry maps the whole rendered text to the whole source.
struct SourceMapEntry: Equatable, Sendable {
    var rendered: NSRange
    var source: NSRange
}

enum TextShape: Equatable, Sendable {
    case plain
    case lineNumbered(gutter: [Int?])
    case jsonLines
    case json
    case markdown
    case image
    case binary(bytes: Int)
}

struct DecodedText: Equatable, Sendable {
    var text: String
    var sourceMap: [SourceMapEntry]
    var shape: TextShape
}

/// Shared tool-output decoders (spec §6.4 steps 2–4 and 6–7). Step 5 (agent envelopes) is
/// `ToolEnvelopes`. A decode that fails at any step returns its input unchanged (anti-goal A2).
enum ToolTextDecoding {
    /// Whole-string JSON is pretty-printed only up to this size; larger text stays plain.
    static let prettyJSONMaxBytes = 256 * 1024
    static let maxJSONStringDepth = 3

    // MARK: Entry point

    static func decode(value: ToolPayloadValue?, fallback: String?) -> DecodedText {
        guard let start = value ?? fallback.map({ ToolPayloadValue.string($0) }) else {
            return DecodedText(text: "", sourceMap: [], shape: .plain)
        }
        switch start {
        case .string(let s):
            return decodeText(s)
        case .array:
            if let parts = ToolJSON.contentItemParts(start) { return decodeParts(parts) }
            return decodeStructured(start, fallback: fallback)
        case .object(let o):
            if let parts = ToolJSON.contentItemParts(.array([start])) { return decodeParts(parts) }
            if let url = o["image_url"]?.stringValue, url.hasPrefix("data:image") { return imageResult() }
            if let bytes = base64Bytes(o) { return binaryResult(bytes: bytes) }
            return decodeStructured(start, fallback: fallback)
        case .number(let n):
            return decodeText(n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n))
        case .bool(let b):
            return decodeText(b ? "true" : "false")
        case .null:
            return DecodedText(text: "", sourceMap: [], shape: .plain)
        }
    }

    // MARK: Content items, images, binary

    private static func decodeParts(_ parts: [ToolJSON.ContentItemPart]) -> DecodedText {
        if parts.allSatisfy({ $0 == .image }) { return imageResult() }
        return decodeText(ToolJSON.joinedText(parts))
    }

    private static func imageResult() -> DecodedText {
        let marker = "[image]"
        return DecodedText(text: marker,
                           sourceMap: [SourceMapEntry(rendered: NSRange(location: 0, length: marker.utf16.count),
                                                      source: NSRange(location: 0, length: 0))],
                           shape: .image)
    }

    /// Decoded size of `{"encoding":"base64","data":"…"}`; nil for any other shape.
    private static func base64Bytes(_ o: [String: ToolPayloadValue]) -> Int? {
        guard o["encoding"]?.stringValue?.lowercased() == "base64", let data = o["data"]?.stringValue else { return nil }
        let chars = data.utf8.filter { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 }
        let padding = chars.reversed().prefix { $0 == 0x3D }.count
        return max(0, chars.count * 3 / 4 - padding)
    }

    private static func binaryResult(bytes: Int) -> DecodedText {
        let kb = max(1, (bytes + 512) / 1024)
        let text = String(localized: "binary data (\(kb) KB)",
                          comment: "Placeholder shown in place of base64 binary tool output. The number is the size in kilobytes.")
        return DecodedText(text: text,
                           sourceMap: [SourceMapEntry(rendered: NSRange(location: 0, length: text.utf16.count),
                                                      source: NSRange(location: 0, length: 0))],
                           shape: .binary(bytes: bytes))
    }

    // MARK: Structured values

    private static func decodeStructured(_ value: ToolPayloadValue, fallback: String?) -> DecodedText {
        let object = value.foundationObject
        if let pretty = ToolJSON.string(from: object, pretty: true), pretty.utf8.count <= prettyJSONMaxBytes {
            return DecodedText(text: pretty, sourceMap: identityMap(pretty), shape: .json)
        }
        if let compact = ToolJSON.string(from: object, pretty: false) {
            return DecodedText(text: compact, sourceMap: identityMap(compact), shape: .plain)
        }
        if let fallback { return decodeText(fallback) }
        return DecodedText(text: "", sourceMap: [], shape: .plain)
    }

    // MARK: Text

    private static func decodeText(_ s: String) -> DecodedText {
        let sourceLength = s.utf16.count
        if let resolved = resolveJSON(s, maxDepth: maxJSONStringDepth) {
            if resolved.value is [String: Any] || resolved.value is [Any] {
                if s.utf8.count <= prettyJSONMaxBytes,
                   let pretty = ToolJSON.string(from: resolved.value, pretty: true) {
                    let map = (resolved.direct ? alignPretty(source: s, pretty: pretty) : nil)
                        ?? coarseMap(renderedLength: pretty.utf16.count, sourceLength: sourceLength)
                    return DecodedText(text: pretty, sourceMap: map, shape: .json)
                }
            } else if let inner = resolved.value as? String {
                var d = plainPipeline(inner)
                d.sourceMap = coarseMap(renderedLength: d.text.utf16.count, sourceLength: sourceLength)
                return d
            }
        }
        return plainPipeline(s)
    }

    /// Steps 4, 6, 7 for text that is not whole-string JSON.
    private static func plainPipeline(_ s: String) -> DecodedText {
        let (normalized, map) = normalizeMapped(s)
        if isJSONLines(normalized) {
            return DecodedText(text: normalized, sourceMap: map, shape: .jsonLines)
        }
        if let stripped = stripLineNumbersMapped(normalized) {
            return DecodedText(text: stripped.text, sourceMap: compose(stripped.map, map),
                               shape: .lineNumbered(gutter: stripped.gutter))
        }
        return DecodedText(text: normalized, sourceMap: map, shape: looksLikeMarkdown(normalized) ? .markdown : .plain)
    }

    // MARK: Normalize

    /// CRLF → LF, ANSI CSI/OSC sequences removed, trailing blank lines trimmed. Tabs stay.
    static func normalize(_ s: String) -> String {
        normalizeMapped(s).text
    }

    private static func normalizeMapped(_ s: String) -> (text: String, map: [SourceMapEntry]) {
        let u = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var map: [SourceMapEntry] = []
        var runSource = -1, runRendered = 0
        func closeRun() {
            guard runSource >= 0 else { return }
            let n = out.count - runRendered
            if n > 0 {
                map.append(SourceMapEntry(rendered: NSRange(location: runRendered, length: n),
                                          source: NSRange(location: runSource, length: n)))
            }
            runSource = -1
        }
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 0x1B, let skip = ansiSequenceLength(u, i) {
                closeRun()
                i += skip
                continue
            }
            if c == 0x0D, i + 1 < u.count, u[i + 1] == 0x0A {
                closeRun()
                i += 1
                continue
            }
            if runSource < 0 { runSource = i; runRendered = out.count }
            out.append(c)
            i += 1
        }
        closeRun()

        // Trim trailing blank lines: cut at the first newline after the last non-blank character.
        var k = out.count - 1
        while k >= 0, out[k] == 0x0A || out[k] == 0x20 || out[k] == 0x09 { k -= 1 }
        var end = out.count
        if k < 0 {
            end = 0
        } else {
            var m = k + 1
            while m < end, out[m] != 0x0A { m += 1 }
            end = m
        }
        if end < out.count {
            out.removeSubrange(end...)
            map = map.compactMap { e in
                guard e.rendered.location < end else { return nil }
                let n = min(e.rendered.length, end - e.rendered.location)
                return SourceMapEntry(rendered: NSRange(location: e.rendered.location, length: n),
                                      source: NSRange(location: e.source.location, length: n))
            }
        }
        return (String(decoding: out, as: UTF16.self), map)
    }

    /// Length of the ANSI CSI or OSC sequence that starts at `i` (an ESC), or nil if there is none.
    private static func ansiSequenceLength(_ u: [UInt16], _ i: Int) -> Int? {
        guard i + 1 < u.count else { return nil }
        var j = i + 2
        switch u[i + 1] {
        case 0x5B:  // CSI: parameter bytes 0x20–0x3F, final byte 0x40–0x7E
            while j < u.count {
                let b = u[j]
                if (0x40...0x7E).contains(b) { return j - i + 1 }
                if !(0x20...0x3F).contains(b) { return nil }
                j += 1
            }
            return nil
        case 0x5D:  // OSC: ends at BEL or ESC \
            while j < u.count {
                if u[j] == 0x07 { return j - i + 1 }
                if u[j] == 0x1B, j + 1 < u.count, u[j + 1] == 0x5C { return j - i + 2 }
                j += 1
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: JSON

    /// Decodes a whole-string JSON object, array or string literal, unwrapping string literals up to
    /// `maxDepth` layers. Returns the final value, or nil when the string is not whole-string JSON.
    static func decodeJSONString(_ s: String, maxDepth: Int) -> ToolPayloadValue? {
        guard let resolved = resolveJSON(s, maxDepth: maxDepth) else { return nil }
        return ToolPayloadValue(jsonObject: resolved.value)
    }

    /// `direct` is true when the object or array was parsed from `s` itself, without unwrapping a string literal.
    private static func resolveJSON(_ s: String, maxDepth: Int) -> (value: Any, direct: Bool)? {
        var current = s
        var depth = 0
        while true {
            guard let first = current.first(where: { !$0.isWhitespace }), first == "{" || first == "[" || first == "\"" else { break }
            guard let parsed = parseJSON(current) else { break }
            if parsed is [String: Any] || parsed is [Any] { return (parsed, depth == 0) }
            guard let str = parsed as? String else { break }
            depth += 1
            current = str
            if depth >= maxDepth { break }
        }
        return depth == 0 ? nil : (current, false)
    }

    private static func parseJSON(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// At least two non-empty lines, each a JSON object, all with the same key set.
    private static func isJSONLines(_ s: String) -> Bool {
        var keys: Set<String>?
        var count = 0
        for sub in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = sub.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("{"), line.hasSuffix("}"),
                  let obj = parseJSON(line) as? [String: Any] else { return false }
            let k = Set(obj.keys)
            if let keys, keys != k { return false }
            keys = k
            count += 1
        }
        return count >= 2
    }

    /// Aligns pretty-printed JSON with its source text. Inserted whitespace maps to a zero-length
    /// source range; skipped source whitespace and `\/` escapes are handled. Returns nil on any other
    /// difference (re-ordered keys, `\u` escapes), and the caller uses a coarse entry.
    private static func alignPretty(source: String, pretty: String) -> [SourceMapEntry]? {
        let s = Array(source.utf16), p = Array(pretty.utf16)
        func isWS(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        var map: [SourceMapEntry] = []
        var si = 0, pi = 0
        var runS = -1, runP = 0
        func closeRun() {
            guard runS >= 0 else { return }
            map.append(SourceMapEntry(rendered: NSRange(location: runP, length: pi - runP),
                                      source: NSRange(location: runS, length: pi - runP)))
            runS = -1
        }
        while pi < p.count {
            if si < s.count, s[si] == p[pi] {
                if runS < 0 { runS = si; runP = pi }
                si += 1; pi += 1
            } else if isWS(p[pi]) {
                closeRun()
                if let last = map.last, last.source.length == 0, NSMaxRange(last.rendered) == pi, last.source.location == si {
                    map[map.count - 1].rendered.length += 1
                } else {
                    map.append(SourceMapEntry(rendered: NSRange(location: pi, length: 1), source: NSRange(location: si, length: 0)))
                }
                pi += 1
            } else if si < s.count, isWS(s[si]) {
                closeRun()
                si += 1
            } else if si + 1 < s.count, s[si] == 0x5C, s[si + 1] == 0x2F, p[pi] == 0x2F {
                closeRun()
                map.append(SourceMapEntry(rendered: NSRange(location: pi, length: 1), source: NSRange(location: si, length: 2)))
                si += 2; pi += 1
            } else {
                return nil
            }
        }
        closeRun()
        while si < s.count { guard isWS(s[si]) else { return nil }; si += 1 }
        return map
    }

    // MARK: Line numbers

    private enum GutterForm: Int { case arrow, tab, colon, pipe, spacedPipe }

    /// Strips a line-number gutter. Forms: `  N→`, `N<tab>`, `N:`, `N|`, `N | `. Applies only when every
    /// non-blank line has the same form and the numbers rise by exactly 1 from the first (any start ≥ 0),
    /// with at least 2 numbered lines. Blank lines keep a nil gutter entry. Otherwise nil.
    static func stripLineNumbers(_ s: String) -> (text: String, gutter: [Int?])? {
        stripLineNumbersMapped(s).map { ($0.text, $0.gutter) }
    }

    private static func stripLineNumbersMapped(_ s: String) -> (text: String, gutter: [Int?], map: [SourceMapEntry])? {
        let u = Array(s.utf16)
        var form: GutterForm?
        var gutter: [Int?] = []
        var out: [UInt16] = []
        var map: [SourceMapEntry] = []
        var numbered = 0
        var expected: Int?
        var lineStart = 0
        while lineStart <= u.count {
            var lineEnd = lineStart
            while lineEnd < u.count, u[lineEnd] != 0x0A { lineEnd += 1 }
            let hasNewline = lineEnd < u.count
            let line = u[lineStart..<lineEnd]
            var contentStart = lineStart
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                gutter.append(nil)
            } else {
                guard let prefix = parseGutterPrefix(u, lineStart, lineEnd) else { return nil }
                if let form, form != prefix.form { return nil }
                form = prefix.form
                if let expected, prefix.number != expected { return nil }
                expected = prefix.number + 1
                numbered += 1
                gutter.append(prefix.number)
                contentStart = prefix.contentStart
            }
            let take = (hasNewline ? lineEnd + 1 : lineEnd) - contentStart
            if take > 0 {
                map.append(SourceMapEntry(rendered: NSRange(location: out.count, length: take),
                                          source: NSRange(location: contentStart, length: take)))
                out.append(contentsOf: u[contentStart..<(contentStart + take)])
            }
            if !hasNewline { break }
            lineStart = lineEnd + 1
        }
        guard numbered >= 2 else { return nil }
        return (String(decoding: out, as: UTF16.self), gutter, map)
    }

    private static func parseGutterPrefix(_ u: [UInt16], _ start: Int, _ end: Int) -> (form: GutterForm, number: Int, contentStart: Int)? {
        var p = start
        while p < end, u[p] == 0x20 { p += 1 }
        let digitsStart = p
        var number = 0
        while p < end, (0x30...0x39).contains(u[p]), p - digitsStart < 9 {
            number = number * 10 + Int(u[p] - 0x30)
            p += 1
        }
        guard p > digitsStart, p < end else { return nil }
        switch u[p] {
        case 0x2192: return (.arrow, number, p + 1)
        case 0x09: return (.tab, number, p + 1)
        case 0x3A: return (.colon, number, p + 1)
        case 0x7C: return (.pipe, number, p + 1)
        case 0x20:
            if p + 2 < end, u[p + 1] == 0x7C, u[p + 2] == 0x20 { return (.spacedPipe, number, p + 3) }
            return nil
        default: return nil
        }
    }

    // MARK: Markdown

    /// Conservative: a heading plus a list, fence or link, or two fence lines. Shell comments (`# x`) stay plain.
    private static func looksLikeMarkdown(_ s: String) -> Bool {
        var heading = false, other = false, fences = 0
        for sub in s.split(separator: "\n", omittingEmptySubsequences: true) {
            if sub.hasPrefix("```") { fences += 1; continue }
            if !heading, sub.hasPrefix("#") {
                let hashes = sub.prefix { $0 == "#" }.count
                if hashes <= 6, sub.dropFirst(hashes).first == " " { heading = true; continue }
            }
            let trimmed = sub.drop { $0 == " " }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || sub.contains("](") { other = true }
        }
        return fences >= 2 || (heading && (other || fences > 0))
    }

    // MARK: Source map helpers

    private static func identityMap(_ s: String) -> [SourceMapEntry] {
        coarseMap(renderedLength: s.utf16.count, sourceLength: s.utf16.count)
    }

    private static func coarseMap(renderedLength: Int, sourceLength: Int) -> [SourceMapEntry] {
        renderedLength == 0 ? [] : [SourceMapEntry(rendered: NSRange(location: 0, length: renderedLength),
                                                   source: NSRange(location: 0, length: sourceLength))]
    }

    /// `outer` maps final → middle text; `inner` maps middle → source. Returns final → source.
    /// A 1:1 outer entry is split along the inner entries it spans, so equal-length runs stay exact.
    private static func compose(_ outer: [SourceMapEntry], _ inner: [SourceMapEntry]) -> [SourceMapEntry] {
        var result: [SourceMapEntry] = []
        var j = 0
        for o in outer {
            let mid = o.source
            if o.rendered.length != mid.length || mid.length == 0 {
                let start = mapPoint(mid.location, inner, isEnd: false)
                let end = mid.length == 0 ? start : max(start, mapPoint(NSMaxRange(mid), inner, isEnd: true))
                result.append(SourceMapEntry(rendered: o.rendered, source: NSRange(location: start, length: end - start)))
                continue
            }
            while j > 0, NSMaxRange(inner[j - 1].rendered) > mid.location { j -= 1 }
            while j < inner.count, NSMaxRange(inner[j].rendered) <= mid.location { j += 1 }
            var k = j
            while k < inner.count, inner[k].rendered.location < NSMaxRange(mid) {
                let i = inner[k]
                let lo = max(mid.location, i.rendered.location)
                let hi = min(NSMaxRange(mid), NSMaxRange(i.rendered))
                if hi > lo {
                    let rendered = NSRange(location: o.rendered.location + (lo - mid.location), length: hi - lo)
                    let source = i.rendered.length == i.source.length
                        ? NSRange(location: i.source.location + (lo - i.rendered.location), length: hi - lo)
                        : i.source
                    result.append(SourceMapEntry(rendered: rendered, source: source))
                }
                k += 1
            }
        }
        return result
    }

    private static func mapPoint(_ p: Int, _ inner: [SourceMapEntry], isEnd: Bool) -> Int {
        var previousEnd = 0
        for e in inner {
            if p < e.rendered.location { return isEnd ? previousEnd : e.source.location }
            if p < NSMaxRange(e.rendered) || (isEnd && p == NSMaxRange(e.rendered)) {
                if e.rendered.length == e.source.length { return e.source.location + (p - e.rendered.location) }
                return isEnd ? NSMaxRange(e.source) : e.source.location
            }
            previousEnd = NSMaxRange(e.source)
        }
        return previousEnd
    }
}

extension ToolPayloadValue {
    /// A Foundation object tree for `JSONSerialization`.
    fileprivate var foundationObject: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? NSNumber(value: Int(n)) : NSNumber(value: n)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let a): return a.map { $0.foundationObject }
        case .object(let o): return o.mapValues { $0.foundationObject }
        }
    }
}
