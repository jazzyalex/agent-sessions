import Foundation

struct PlanParser {
    struct ParsedPlan: Equatable, Sendable {
        let title: String
        let body: String
        let sections: [Section]

        struct Section: Equatable, Sendable {
            let heading: String
            let lines: [String]
        }
    }

    static func parse(from rawText: String) -> ParsedPlan? {
        guard let range = wrappedRange(in: rawText) else { return nil }
        let inner = String(rawText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return nil }

        let lines = inner.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = extractTitle(from: lines)

        var sections: [ParsedPlan.Section] = []
        var currentHeading = "Plan"
        var currentLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if !currentLines.isEmpty || !sections.isEmpty {
                    sections.append(.init(heading: currentHeading, lines: currentLines))
                }
                currentHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
                continue
            }
            currentLines.append(line)
        }

        if !currentLines.isEmpty {
            sections.append(.init(heading: currentHeading, lines: currentLines))
        }

        return ParsedPlan(title: title, body: inner, sections: sections)
    }

    static func wrappedRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: "<proposed_plan>"),
              let end = text.range(of: "</proposed_plan>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return start.upperBound..<end.lowerBound
    }

    private static func extractTitle(from lines: [String]) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("# ") {
                let header = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return header.isEmpty ? "Plan" : header
            }
            return trimmed
        }
        return "Plan"
    }
}
