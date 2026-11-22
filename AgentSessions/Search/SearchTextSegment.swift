import Foundation

struct SearchTextSegment: Sendable, Equatable {
    enum Kind: Sendable { case title, repository, message, toolName, input, output, error }
    enum Provenance: Sendable { case source, omitted }
    let source: SessionSource
    let eventID: String
    let kind: Kind
    let text: String
    let provenance: Provenance
}

/// Search consumes preserved semantic fields, never a display sanitizer or raw JSON dump.
/// A literal omission-looking string in the source remains ordinary searchable text.
enum SearchSourceText {
    static func segments(event: SessionEvent, source: SessionSource) -> [SearchTextSegment] {
        if source == .deepseekHarness, event.kind == .meta, event.role == "user" { return [] }
        var result: [SearchTextSegment] = []
        func append(_ kind: SearchTextSegment.Kind, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            result.append(.init(source: source, eventID: event.id, kind: kind, text: text, provenance: .source))
        }
        if event.isProvenTyped, event.messageDisplayText != event.text { append(.message, event.messageDisplayText) }
        let textKind: SearchTextSegment.Kind
        switch event.kind {
        case .error: textKind = .error
        case .tool_result: textKind = .output
        case .tool_call: textKind = .input
        default: textKind = .message
        }
        append(textKind, event.text)
        append(.toolName, event.toolName)
        append(.input, event.toolInput)
        if event.toolOutput != event.text { append(event.kind == .error ? .error : .output, event.toolOutput) }
        return result
    }
}
