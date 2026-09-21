import Foundation
import SwiftUI

// App-only half of `SessionTranscriptBuilder`: themed `AttributedString` rendering. The
// plain-text, ANSI, and block-coalescing builders stay in SessionTranscriptBuilder.swift,
// which is UI-free and shared with the Linux core.
extension SessionTranscriptBuilder {
    static func buildAttributed(session: Session, theme: TranscriptTheme, filters: TranscriptFilters) -> AttributedString {
        let opts = options(from: filters, mode: .normal, source: session.source)
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

    fileprivate static func attributedLine(for e: SessionEvent, colors: TranscriptColors, options: Options) -> AttributedString {
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
}
