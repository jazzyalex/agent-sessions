import Foundation

enum SessionSearchTextBuilder {
    static func build(session: Session, maxCharacters: Int = 200_000, perFieldLimit: Int = 8_000) -> String {
        var parts: [String] = []
        parts.reserveCapacity(128)

        var remaining = maxCharacters
        let toolOutputMax = FeatureFlags.instantToolOutputIndexMaxChars

        func append(_ value: String?) {
            guard remaining > 0 else { return }
            guard var value, !value.isEmpty else { return }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            if value.count > perFieldLimit {
                value = String(value.prefix(perFieldLimit))
            }
            if value.count > remaining {
                value = String(value.prefix(remaining))
            }
            guard !value.isEmpty else { return }
            parts.append(value)
            remaining -= value.count
        }

        append(session.title)
        append(session.repoName)
        append(session.cwd)
        append(session.model)

        for ev in session.events {
            append(ev.text)
            append(ev.toolName)
            append(ev.toolInput)
            if let out = ev.toolOutput, out.count <= toolOutputMax {
                append(out)
            }
            if remaining <= 0 { break }
        }

        return parts.joined(separator: "\n")
    }
}
