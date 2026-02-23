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

    private static let openingFenceRegex = try! NSRegularExpression(pattern: #"(?m)^[ \t]*```([^\n`]*)$"#)
    private static let closingFenceRegex = try! NSRegularExpression(pattern: #"(?m)^[ \t]*```[ \t]*$"#)

    static func firstFence(in text: String, from start: String.Index) -> CodeFenceRange? {
        let openingSearchRange = NSRange(start..<text.endIndex, in: text)
        guard let openingMatch = openingFenceRegex.firstMatch(in: text, options: [], range: openingSearchRange),
              let fenceStart = Range(openingMatch.range, in: text) else {
            return nil
        }
        let languageRaw: String = {
            guard let languageRange = Range(openingMatch.range(at: 1), in: text) else { return "" }
            return String(text[languageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        var contentStart = fenceStart.upperBound
        if contentStart < text.endIndex, text[contentStart] == "\r" {
            contentStart = text.index(after: contentStart)
        }
        if contentStart < text.endIndex, text[contentStart] == "\n" {
            contentStart = text.index(after: contentStart)
        }

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
