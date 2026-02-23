import Foundation

struct CodeFenceParser {
    struct CodeBlockModel: Equatable, Sendable {
        let language: String?
        let body: String
        let rawText: String
    }

    struct CodeFenceRange: Equatable, Sendable {
        let range: Range<String.Index>
        let model: CodeBlockModel
    }

    private static let closingFenceRegex = try! NSRegularExpression(pattern: #"(?m)^[ \t]*```[ \t]*$"#)

    static func firstFence(in text: String, from start: String.Index) -> CodeFenceRange? {
        guard let fenceStart = text.range(of: "```", range: start..<text.endIndex) else { return nil }
        let languageLineStart = fenceStart.upperBound
        let lineEnd = text[languageLineStart...].firstIndex(of: "\n") ?? text.endIndex
        let languageRaw = String(text[languageLineStart..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let contentStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd

        let searchRange = NSRange(contentStart..<text.endIndex, in: text)
        guard let closingMatch = closingFenceRegex.firstMatch(in: text, options: [], range: searchRange),
              let fenceEnd = Range(closingMatch.range, in: text) else {
            return nil
        }

        let body = String(text[contentStart..<fenceEnd.lowerBound])
        let raw = String(text[fenceStart.lowerBound..<fenceEnd.upperBound])
        let language = languageRaw.isEmpty ? nil : languageRaw.lowercased()

        return CodeFenceRange(range: fenceStart.lowerBound..<fenceEnd.upperBound,
                              model: CodeBlockModel(language: language, body: body, rawText: raw))
    }
}
