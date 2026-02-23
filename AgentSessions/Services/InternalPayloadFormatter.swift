import Foundation

struct InternalPayloadFormatter {
    struct ReviewCardModel: Equatable, Sendable {
        let correctness: String
        let explanation: String
        let confidenceScore: Double
        let findingsCount: Int
        let rawJSON: String

        var summaryText: String {
            var lines: [String] = []
            lines.append("Review")
            lines.append("Correctness: \(correctness)")
            lines.append(String(format: "Confidence: %.2f", confidenceScore))
            lines.append("Findings: \(findingsCount)")
            let trimmedExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedExplanation.isEmpty {
                lines.append("")
                lines.append(trimmedExplanation)
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let requiredKeys: Set<String> = [
        "findings",
        "overall_correctness",
        "overall_explanation",
        "overall_confidence_score"
    ]

    private static let allowlistedExtraKeys: Set<String> = [
        "title",
        "summary",
        "notes",
        "version"
    ]

    static func parseReviewCard(rawText: String, source: SessionSource) -> ReviewCardModel? {
        guard source == .codex else { return nil }
        let candidates = reviewJSONCandidates(from: rawText)
        guard !candidates.isEmpty else { return nil }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = obj as? [String: Any] else {
                continue
            }

            guard requiredKeys.isSubset(of: Set(dict.keys)) else { continue }
            var hasDisallowedExtraKey = false
            for key in dict.keys where !requiredKeys.contains(key) {
                if key.hasPrefix("_") { continue }
                if allowlistedExtraKeys.contains(key) { continue }
                hasDisallowedExtraKey = true
                break
            }
            if hasDisallowedExtraKey { continue }

            let correctness = stringValue(dict["overall_correctness"])
            let explanation = stringValue(dict["overall_explanation"])
            let confidence = doubleValue(dict["overall_confidence_score"])
            guard let correctness, let explanation, let confidence else { continue }

            guard let findingsAny = dict["findings"] else { continue }
            let findingsCount: Int = {
                if let arr = findingsAny as? [Any] { return arr.count }
                if let text = findingsAny as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1 }
                if findingsAny is NSNull { return 0 }
                return 1
            }()

            return ReviewCardModel(correctness: correctness,
                                   explanation: explanation,
                                   confidenceScore: confidence,
                                   findingsCount: findingsCount,
                                   rawJSON: candidate)
        }

        return nil
    }

    private static func reviewJSONCandidates(from rawText: String) -> [String] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: [String] = []

        func appendCandidate(_ text: String) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.first == "{", normalized.last == "}" else { return }
            if !candidates.contains(normalized) {
                candidates.append(normalized)
            }
        }

        appendCandidate(trimmed)

        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            guard let fenced = CodeFenceParser.firstFence(in: trimmed, from: cursor) else { break }
            appendCandidate(fenced.model.body)
            cursor = fenced.range.upperBound
        }

        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            appendCandidate(String(trimmed[firstBrace...lastBrace]))
        }

        return candidates
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
