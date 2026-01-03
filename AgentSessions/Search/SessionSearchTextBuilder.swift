import Foundation

enum SessionSearchTextBuilder {
    static func build(session: Session, maxCharacters: Int = 200_000, perFieldLimit: Int = 8_000) -> String {
        var parts: [String] = []
        parts.reserveCapacity(160)
        let toolOutputMax = FeatureFlags.instantToolOutputIndexMaxChars

        func normalized(_ value: String?) -> String? {
            guard var value, !value.isEmpty else { return nil }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.count > perFieldLimit {
                value = String(value.prefix(perFieldLimit))
            }
            guard !value.isEmpty else { return nil }
            return value
        }

        func append(_ value: String?, into out: inout [String], remaining: inout Int) {
            guard remaining > 0 else { return }
            guard var value = normalized(value) else { return }
            if value.count > remaining {
                value = String(value.prefix(remaining))
            }
            guard !value.isEmpty else { return }
            out.append(value)
            remaining -= value.count
        }

        var headRemaining = maxCharacters
        append(session.title, into: &parts, remaining: &headRemaining)
        append(session.repoName, into: &parts, remaining: &headRemaining)
        append(session.cwd, into: &parts, remaining: &headRemaining)
        append(session.model, into: &parts, remaining: &headRemaining)

        // Include both early and late transcript content to reduce false negatives where
        // a query appears near the end of a large session.
        let tailBudget = max(0, min(maxCharacters / 2, headRemaining / 2))
        headRemaining -= tailBudget
        var tailRemaining = tailBudget
        var tailParts: [String] = []
        tailParts.reserveCapacity(96)

        func appendEventFields(_ ev: SessionEvent, into out: inout [String], remaining: inout Int) {
            append(ev.text, into: &out, remaining: &remaining)
            append(ev.toolName, into: &out, remaining: &remaining)
            append(ev.toolInput, into: &out, remaining: &remaining)
            if let toolOut = ev.toolOutput, toolOut.count <= toolOutputMax {
                append(toolOut, into: &out, remaining: &remaining)
            }
        }

        if !session.events.isEmpty {
            for ev in session.events {
                appendEventFields(ev, into: &parts, remaining: &headRemaining)
                if headRemaining <= 0 { break }
            }

            if tailRemaining > 0 {
                for ev in session.events.reversed() {
                    appendEventFields(ev, into: &tailParts, remaining: &tailRemaining)
                    if tailRemaining <= 0 { break }
                }
            }
        }

        if !tailParts.isEmpty {
            parts.append("…")
            parts.append(contentsOf: tailParts.reversed())
        }

        return parts.joined(separator: "\n")
    }
}
