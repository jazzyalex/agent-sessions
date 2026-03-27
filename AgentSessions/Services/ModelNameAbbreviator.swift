import Foundation

/// Abbreviates long LLM model IDs into short display names for badge pills.
enum ModelNameAbbreviator {
    static func abbreviate(_ modelID: String?) -> String? {
        guard let modelID, !modelID.isEmpty else { return nil }
        let lower = modelID.lowercased()

        // Claude models
        if lower.contains("haiku") {
            if lower.contains("4-5") || lower.contains("4.5") { return "Haiku 4.5" }
            return "Haiku"
        }
        if lower.contains("sonnet") {
            if lower.contains("4-6") || lower.contains("4.6") { return "Sonnet 4.6" }
            if lower.contains("4-5") || lower.contains("4.5") { return "Sonnet 4.5" }
            if lower.contains("3-5") || lower.contains("3.5") { return "Sonnet 3.5" }
            return "Sonnet"
        }
        if lower.contains("opus") {
            if lower.contains("4-6") || lower.contains("4.6") { return "Opus 4.6" }
            return "Opus"
        }

        // "Claude Code <version>" fallback — strip to just the version
        if lower.hasPrefix("claude code ") {
            return "CC " + String(modelID.dropFirst(12))
        }

        // GPT models
        if lower.hasPrefix("gpt-") || lower.hasPrefix("gpt_") {
            return modelID.uppercased()
                .replacingOccurrences(of: "GPT-", with: "GPT-")
                .replacingOccurrences(of: "GPT_", with: "GPT-")
        }
        if lower.contains("o1") || lower.contains("o3") || lower.contains("o4") {
            // OpenAI reasoning models: o1, o3, o4-mini etc.
            return modelID
        }

        // Gemini models
        if lower.contains("gemini") {
            if lower.contains("2.5") { return "Gemini 2.5" }
            if lower.contains("2.0") { return "Gemini 2.0" }
            if lower.contains("1.5") { return "Gemini 1.5" }
            return "Gemini"
        }

        // Short enough already
        if modelID.count <= 16 { return modelID }

        // Truncate preserving meaningful prefix
        return String(modelID.prefix(14)) + "..."
    }
}
