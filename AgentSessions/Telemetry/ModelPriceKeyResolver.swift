import Foundation

/// A candidate price-table key for a raw model string, plus whether the raw
/// string named a free or promotional route.
struct ResolvedPriceKey: Equatable, Sendable {
    let key: String
    let viaFreeRoute: Bool
}

/// Maps the model strings agents write to price-table keys.
///
/// Never guesses: a string no step recognizes passes through unchanged and the
/// price lookup decides. Free-route detection is separate from key resolution so
/// an alias hit cannot erase it.
enum ModelPriceKeyResolver {
    private static let reasoningSuffixes: Set<String> =
        ["minimal", "low", "medium", "high", "xhigh", "thinking"]
    /// Only the free marker is stripped. `muse-spark-1.3-contributor-free` keeps its
    /// `-contributor` part, because the contributor route's base model is
    /// `muse-spark-1.3-contributor`, which Meta prices separately.
    private static let freeSuffixes = [":free", "-free"]
    private static let freePrefix = "cline-free/"
    private static let providerPrefixes: Set<String> =
        // Kimi Code writes `moonshot-ai/…`; OpenRouter-style ids use `moonshotai/…`.
        ["anthropic", "openai", "google", "z-ai", "moonshotai", "moonshot-ai", "deepseek", "minimax",
         "x-ai", "qwen", "meta", "opencode", "openrouter", "poolside"]

    static func resolve(_ raw: String?, aliases: [String: String]) -> ResolvedPriceKey? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        // 2. One trailing "(effort)" group, only for known effort words.
        if value.hasSuffix(")"), let open = value.lastIndex(of: "(") {
            let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
            if reasoningSuffixes.contains(String(inner)) {
                value = String(value[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        // 3. Free route.
        var viaFreeRoute = false
        if value.hasPrefix(freePrefix) {
            viaFreeRoute = true
            value = String(value.dropFirst(freePrefix.count))
        }
        if let suffix = freeSuffixes.first(where: { value.hasSuffix($0) }) {
            viaFreeRoute = true
            value = String(value.dropLast(suffix.count))
        }

        // 4. Exactly one provider prefix, from the allowlist.
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, providerPrefixes.contains(String(parts[0])) {
            value = String(parts[1])
        }
        guard !value.isEmpty else { return nil }

        // 5. Alias.
        if let alias = aliases[value] { value = alias }

        // 6. Claude dot variant: "4.5" → "4-5" between digits.
        if value.hasPrefix("claude-") {
            let chars = Array(value)
            var out = ""
            for (index, char) in chars.enumerated() {
                let betweenDigits = char == "." && index > 0 && index < chars.count - 1
                    && chars[index - 1].isNumber && chars[index + 1].isNumber
                out.append(betweenDigits ? "-" : char)
            }
            value = out
        }
        return ResolvedPriceKey(key: value, viaFreeRoute: viaFreeRoute)
    }
}
