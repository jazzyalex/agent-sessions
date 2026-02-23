import Foundation

struct UnifiedDiffParser {
    struct DiffBlockModel: Equatable, Sendable {
        let files: [String]
        let hunks: [String]
        let rawText: String
    }

    static func parse(_ text: String) -> DiffBlockModel? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        let hasGitHeader = lines.contains(where: { $0.hasPrefix("diff --git ") })
        let hasHunk = lines.contains(where: { $0.hasPrefix("@@") })
        let hasPatchFiles = lines.contains(where: { $0.hasPrefix("--- ") }) && lines.contains(where: { $0.hasPrefix("+++ ") })

        guard (hasGitHeader && (hasHunk || hasPatchFiles)) || (hasHunk && hasPatchFiles) else {
            return nil
        }

        let files = lines.compactMap { line -> String? in
            guard line.hasPrefix("+++ ") || line.hasPrefix("--- ") else { return nil }
            let value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if value == "/dev/null" { return nil }
            if value.hasPrefix("a/") || value.hasPrefix("b/") {
                return String(value.dropFirst(2))
            }
            return value
        }

        let hunks = lines.filter { $0.hasPrefix("@@") }

        return DiffBlockModel(files: Array(Set(files)).sorted(), hunks: hunks, rawText: text)
    }

    static func looksLikeUnifiedDiff(_ text: String) -> Bool {
        parse(text) != nil
    }
}
