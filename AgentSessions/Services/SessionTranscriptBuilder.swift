import Foundation
import SwiftUI

// swiftlint:disable type_body_length
struct SessionTranscriptBuilder {
    static let outPrefix = "⟪out⟫"
    static let toolPrefix = "› tool:"
    static let userPrefix = "> "
    static let errorPrefix = "! error"

    struct ANSI {
        static let reset = "\u{001B}[0m"
        static let cyan = "\u{001B}[36m"
        static let green = "\u{001B}[32m"
        static let magenta = "\u{001B}[35m"
        static let red = "\u{001B}[31m"
        static let dim = "\u{001B}[2m"
        static let bold = "\u{001B}[1m"
    }

    struct Options { var showTimestamps: Bool; var showMeta: Bool; var renderMode: TranscriptRenderMode }

    // MARK: Public API

    /// New plain terminal transcript builder (no truncation, no styling)
    static func buildPlainTerminalTranscript(session: Session, filters: TranscriptFilters, mode: TranscriptRenderMode = .normal) -> String {
        let opts = options(from: filters, mode: mode)
        let blocks = coalesce(session: session, includeMeta: opts.showMeta)
        var out = ""
        // Intentionally omit session header and divider for a cleaner transcript view
        for b in blocks {
            out += render(block: b, options: opts)
            out += "\n"
        }
        return out
    }

    /// Terminal mode helper that also returns NSRanges for command lines and user text to enable styling in the UI.
    static func buildTerminalPlainWithRanges(session: Session, filters: TranscriptFilters) -> (String, [NSRange], [NSRange]) {
        let opts = options(from: filters, mode: .terminal)
        let blocks = coalesce(session: session, includeMeta: opts.showMeta)
        var out = ""
        var commandRanges: [NSRange] = []
        var userRanges: [NSRange] = []
        func markRange(_ s: String, into array: inout [NSRange]) {
            let start = (out as NSString).length
            out += s
            let len = (s as NSString).length
            if len > 0 { array.append(NSRange(location: start, length: len)) }
        }
        for b in blocks {
            switch b.kind {
            case .toolCall:
                let rendered = renderTerminalToolCall(name: b.toolName, toolInput: b.toolInput, fallback: b.text)
                // Mark each command line as a command range
                let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
                for (i, line) in lines.enumerated() {
                    markRange(String(line), into: &commandRanges)
                    if i < lines.count - 1 { out += "\n" }
                }
            case .user:
                // Render exactly like render(block:) but also record user text ranges (exclude prefix/timestamp)
                let head = timestampPrefix(b.timestamp, options: opts)
                let prefix = userPrefix
                out += head + prefix
                markRange(b.text, into: &userRanges)
            default:
                out += render(block: b, options: opts)
            }
            out += "\n"
        }
        return (out, commandRanges, userRanges)
    }

    static func buildANSI(session: Session, filters: TranscriptFilters) -> String {
        let opts = options(from: filters, mode: .normal)
        var out = ""
        out += ANSI.bold + headerLine(session: session) + ANSI.reset + "\n"
        out += String(repeating: "─", count: 80) + "\n"
        for e in session.events {
            if e.kind == .meta && !opts.showMeta { continue }
            out += ansiLine(for: e, options: opts) + "\n"
        }
        return out
    }

    static func buildAttributed(session: Session, theme: TranscriptTheme, filters: TranscriptFilters) -> AttributedString {
        let opts = options(from: filters, mode: .normal)
        let colors = theme.colors
        var attr = AttributedString("")

        var header = AttributedString(headerLine(session: session) + "\n")
        header.foregroundColor = colors.dim
        header.font = .system(.body, design: .monospaced)
        attr += header

        var rule = AttributedString(String(repeating: "─", count: 80) + "\n")
        rule.foregroundColor = colors.dim
        rule.font = .system(.body, design: .monospaced)
        attr += rule

        for e in session.events {
            if e.kind == .meta && !opts.showMeta { continue }
            attr += attributedLine(for: e, colors: colors, options: opts)
            attr += AttributedString("\n")
        }
        return attr
    }

    // MARK: Line helpers

    private static func timestampTail(_ ts: Date?, options: Options) -> String {
        guard options.showTimestamps, let ts = ts else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return " @" + f.string(from: ts)
    }

    private static func timestampPrefix(_ ts: Date?, options: Options) -> String {
        guard options.showTimestamps, let ts = ts else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: ts) + " "
    }

    // Legacy builders kept for compatibility in case other views still call them
    static func buildPlain(session: Session, filters: TranscriptFilters) -> String {
        let opts = options(from: filters, mode: .normal)
        var lines: [String] = []
        lines.append(headerLine(session: session))
        lines.append(String(repeating: "-", count: 80))
        for e in session.events {
            if e.kind == .meta && !opts.showMeta { continue }
            let b = block(from: e)
            lines.append(render(block: b, options: opts))
        }
        return lines.joined(separator: "\n")
    }

    private static func ansiLine(for e: SessionEvent, options: Options) -> String {
        func wrap(_ s: String, _ code: String) -> String { code + s + ANSI.reset }
        switch e.kind {
        case .user:
            return wrap(userPrefix, ANSI.cyan) + (e.text ?? "") + wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
        case .assistant:
            var line = (e.text ?? "")
            if !line.isEmpty { line += "  " }
            line += wrap("[assistant]", ANSI.green)
            line += wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
            return line
        case .tool_call:
            let args: String
            if let input = e.toolInput, input.count <= 80 {
                args = " " + wrap(input, ANSI.dim)
            } else if e.toolInput != nil {
                args = " " + wrap("(args…)", ANSI.dim)
            } else { args = "" }
            return wrap(toolPrefix, ANSI.magenta) + " " + (e.toolName ?? "?") + args + wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
        case .tool_result:
            if let output = formattedOutput(e.toolOutput) {
                return wrap(outPrefix, ANSI.dim) + " " + output + wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
            }
            return wrap(outPrefix, ANSI.dim) + wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
        case .error:
            return wrap(errorPrefix, ANSI.red) + " " + (e.text ?? "") + wrap(timestampTail(e.timestamp, options: options), ANSI.dim)
        case .meta:
            return wrap(e.text ?? e.rawJSON, ANSI.dim)
        }
    }

    private static func attributedLine(for e: SessionEvent, colors: TranscriptColors, options: Options) -> AttributedString {
        var line = AttributedString("")
        func append(_ text: String, color: Color? = nil) {
            var piece = AttributedString(text)
            piece.font = .system(.body, design: .monospaced)
            if let color { piece.foregroundColor = color }
            line += piece
        }
        switch e.kind {
        case .user:
            append(userPrefix, color: colors.user)
            append(e.text ?? "")
            append(timestampTail(e.timestamp, options: options), color: colors.dim)
        case .assistant:
            append(e.text ?? "")
            if !(e.text ?? "").isEmpty { append("  ") }
            append("[assistant]", color: colors.assistant)
            append(timestampTail(e.timestamp, options: options), color: colors.dim)
        case .tool_call:
            append(toolPrefix + " ", color: colors.tool)
            append(e.toolName ?? "?")
            if let input = e.toolInput {
                if input.count <= 80 {
                    append(" " + input, color: colors.dim)
                } else {
                    append(" (args…)", color: colors.dim)
                }
            }
            append(timestampTail(e.timestamp, options: options), color: colors.dim)
        case .tool_result:
            append(outPrefix + " ", color: colors.dim)
            if let output = formattedOutput(e.toolOutput) { append(output) }
            append(timestampTail(e.timestamp, options: options), color: colors.dim)
        case .error:
            append(errorPrefix + " ", color: colors.error)
            append(e.text ?? "")
            append(timestampTail(e.timestamp, options: options), color: colors.dim)
        case .meta:
            append(e.text ?? e.rawJSON, color: colors.dim)
        }
        return line
    }

    // MARK: Formatting helpers

    private static func options(from filters: TranscriptFilters, mode: TranscriptRenderMode) -> Options {
        switch filters {
        case let .current(showTimestamps, showMeta):
            return Options(showTimestamps: showTimestamps, showMeta: showMeta, renderMode: mode)
        }
    }

    // Terminal rendering for tool_call events
    private static func renderTerminalToolCall(name: String?, toolInput: String?, fallback: String) -> String {
        guard let tool = name else { return "\(toolPrefix) \(fallback)" }
        guard let input = toolInput, !input.isEmpty else { return "\(toolPrefix) \(tool)" }
        if tool.lowercased() == "shell" {
            if let data = input.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let arr = obj["command"] as? [Any] {
                    let parts = arr.compactMap { $0 as? String }
                    if parts.count >= 3, parts[0] == "bash" {
                        let header = parts[0...1].joined(separator: " ")
                        let cmd = parts.dropFirst(2).joined(separator: " ")
                        return header + "\n" + cmd
                    } else if parts.count >= 1 {
                        return parts.joined(separator: " ")
                    }
                }
                if let script = obj["script"] as? String { return script }
            }
            return "\(toolPrefix) shell \(compactJSONOneLine(input))"
        }
        return "\(toolPrefix) \(tool) \(compactJSONOneLine(input))"
    }

    private static func headerLine(session: Session) -> String {
        let short = session.shortID
        let model = session.model ?? "—"
        let branch = session.gitBranch ?? "—"
        let msgs = session.nonMetaCount
        let modified = session.modifiedRelative
        return "Session \(short)  •  model \(model)  •  branch \(branch)  •  msgs \(msgs)  •  modified \(modified)"
    }

    private static func formattedOutput(_ s: String?) -> String? {
        guard var text = s, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            // Pretty print JSON if possible
            text = PrettyJSON.prettyPrinted(text)
        }
        return text
    }

    // MARK: New coalescer + renderer

    private struct LogicalBlock: Equatable {
        enum Kind { case user, assistant, toolCall, toolOut, error, meta }
        var kind: Kind
        var text: String
        var timestamp: Date?
        var messageID: String?
        var toolName: String?
        var isDelta: Bool
        var toolInput: String?
    }

    private static func block(from e: SessionEvent) -> LogicalBlock {
        switch e.kind {
        case .user:
            return LogicalBlock(kind: .user, text: e.text ?? "", timestamp: e.timestamp, messageID: e.messageID, toolName: nil, isDelta: e.isDelta)
        case .assistant:
            return LogicalBlock(kind: .assistant, text: e.text ?? "", timestamp: e.timestamp, messageID: e.messageID, toolName: nil, isDelta: e.isDelta)
        case .tool_call:
            let rendered = renderToolCallLabel(name: e.toolName, args: e.toolInput)
            return LogicalBlock(kind: .toolCall, text: rendered, timestamp: e.timestamp, messageID: e.messageID ?? e.parentID, toolName: e.toolName, isDelta: e.isDelta, toolInput: e.toolInput)
        case .tool_result:
            return LogicalBlock(kind: .toolOut, text: e.toolOutput ?? "", timestamp: e.timestamp, messageID: e.messageID ?? e.parentID, toolName: e.toolName, isDelta: e.isDelta)
        case .error:
            // If text is empty, fall back to pretty textified raw JSON
            let txt = (e.text?.isEmpty == false) ? e.text! : PrettyJSON.prettyPrinted(e.rawJSON)
            return LogicalBlock(kind: .error, text: txt, timestamp: e.timestamp, messageID: e.messageID, toolName: nil, isDelta: e.isDelta)
        case .meta:
            let txt = e.text ?? PrettyJSON.prettyPrinted(e.rawJSON)
            return LogicalBlock(kind: .meta, text: txt, timestamp: e.timestamp, messageID: e.messageID, toolName: nil, isDelta: e.isDelta)
        }
    }

    private static func canMerge(_ a: LogicalBlock, _ b: LogicalBlock) -> Bool {
        // Only merge assistant/toolOut/meta streams
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .assistant, .toolOut:
            if let am = a.messageID, let bm = b.messageID { return am == bm }
            if a.isDelta && b.isDelta {
                // Fall back when message IDs are missing but these are delta chunks
                if a.kind == .toolOut { return a.toolName == b.toolName }
                return true
            }
            return false
        case .meta:
            return false
        default:
            return false
        }
    }

    private static func coalesce(session: Session, includeMeta: Bool) -> [LogicalBlock] {
        var blocks: [LogicalBlock] = []
        blocks.reserveCapacity(session.events.count)
        for e in session.events {
            if e.kind == .meta && !includeMeta { continue }
            let b = block(from: e)
            if let last = blocks.last, canMerge(last, b) {
                var merged = last
                merged.text += b.text
                merged.timestamp = merged.timestamp ?? b.timestamp
                blocks.removeLast()
                blocks.append(merged)
            } else {
                blocks.append(b)
            }
        }
        return blocks
    }

    private static func render(block b: LogicalBlock, options: Options) -> String {
        switch b.kind {
        case .user:
            let head = timestampPrefix(b.timestamp, options: options)
            if let nl = b.text.firstIndex(of: "\n") {
                let first = String(b.text[..<nl])
                let rest = String(b.text[nl...])
                return head + userPrefix + first + rest
            } else {
                return head + userPrefix + b.text
            }
        case .assistant:
            let head = timestampPrefix(b.timestamp, options: options)
            if let nl = b.text.firstIndex(of: "\n") {
                let first = String(b.text[..<nl])
                let rest = String(b.text[nl...])
                return head + first + rest
            } else {
                return head + b.text
            }
        case .toolCall:
            let head = timestampPrefix(b.timestamp, options: options)
            if options.renderMode == .terminal {
                return head + renderTerminalToolCall(name: b.toolName, toolInput: b.toolInput, fallback: b.text)
            } else {
                return head + "\(toolPrefix) \(b.text)"
            }
        case .toolOut:
            guard !b.text.isEmpty else { return timestampPrefix(b.timestamp, options: options) + outPrefix }
            if let nl = b.text.firstIndex(of: "\n") {
                let first = String(b.text[..<nl])
                let rest = String(b.text[nl...])
                return timestampPrefix(b.timestamp, options: options) + "\(outPrefix) \(first)" + rest
            } else {
                return timestampPrefix(b.timestamp, options: options) + "\(outPrefix) \(b.text)"
            }
        case .error:
            let head = timestampPrefix(b.timestamp, options: options)
            if let nl = b.text.firstIndex(of: "\n") {
                let first = String(b.text[..<nl])
                let rest = String(b.text[nl...])
                return head + errorPrefix + " " + first + rest
            } else {
                return head + errorPrefix + " " + b.text
            }
        case .meta:
            let head = timestampPrefix(b.timestamp, options: options)
            if let nl = b.text.firstIndex(of: "\n") {
                let first = String(b.text[..<nl])
                let rest = String(b.text[nl...])
                return head + "· meta " + first + rest
            } else {
                return head + "· meta " + b.text
            }
        }
    }

    private static func renderToolCallLabel(name: String?, args: String?) -> String {
        var label = name ?? "?"
        if let a = args, !a.isEmpty {
            let compact = compactJSONOneLine(a)
            let truncated = truncateTo(compact, max: 120)
            label += " " + truncated
        }
        return label
    }

    private static func compactJSONOneLine(_ s: String) -> String {
        guard let data = s.data(using: .utf8) else { return s }
        if let obj = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let min = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                return String(data: min, encoding: .utf8) ?? s
            }
        }
        // Not JSON – compress whitespace by splitting on whitespace/newlines
        let pieces = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return pieces.joined(separator: " ")
    }

    private static func truncateTo(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let end = s.index(s.startIndex, offsetBy: max)
        return String(s[..<end]) + "…"
    }
}
// swiftlint:enable type_body_length
