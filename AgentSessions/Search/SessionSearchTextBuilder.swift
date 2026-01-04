import Foundation

enum SessionSearchTextBuilder {
    static func build(session: Session, maxCharacters: Int = 200_000, perFieldLimit: Int = 8_000) -> String {
        var parts: [String] = []
        parts.reserveCapacity(220)
        let toolOutputMax = FeatureFlags.instantToolOutputIndexMaxChars

        func normalized(_ value: String?, limit: Int) -> String? {
            guard var value, !value.isEmpty else { return nil }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.count > limit {
                value = String(value.prefix(limit))
            }
            guard !value.isEmpty else { return nil }
            return value
        }

        func append(_ value: String?, limit: Int = perFieldLimit, into out: inout [String], remaining: inout Int) {
            guard remaining > 0 else { return }
            guard var value = normalized(value, limit: limit) else { return }
            if value.count > remaining {
                value = String(value.prefix(remaining))
            }
            guard !value.isEmpty else { return }
            out.append(value)
            remaining -= value.count
        }

        var remaining = maxCharacters
        append(session.title, into: &parts, remaining: &remaining)
        append(session.repoName, into: &parts, remaining: &remaining)
        append(session.cwd, into: &parts, remaining: &remaining)
        append(session.model, into: &parts, remaining: &remaining)

        // Keep the Instant index fast but reduce false negatives by mixing:
        // - early events (head)
        // - a thin mid-session sample (middle)
        // - late events (tail)
        let headBudget = max(0, remaining * 2 / 5)
        let tailBudget = max(0, remaining * 2 / 5)
        let middleBudget = max(0, remaining - headBudget - tailBudget)

        var headRemaining = headBudget
        var middleRemaining = middleBudget
        var tailRemaining = tailBudget

        var tailParts: [String] = []
        tailParts.reserveCapacity(96)
        var middleParts: [String] = []
        middleParts.reserveCapacity(64)

        func appendToolOutput(_ toolOut: String, into out: inout [String], remaining: inout Int) {
            guard remaining > 0 else { return }
            let maxOut = min(toolOutputMax, remaining)
            guard maxOut > 0 else { return }
            let trimmed = toolOut.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            if trimmed.count <= maxOut {
                append(trimmed, limit: maxOut, into: &out, remaining: &remaining)
                return
            }

            // Include head + middle + tail so "Instant" can match terms that only appear
            // in the middle of a long tool output (without indexing the full blob).
            if maxOut < 32 {
                append(String(trimmed.prefix(maxOut)), limit: maxOut, into: &out, remaining: &remaining)
                return
            }

            let usable = max(0, maxOut - 2) // reserve for two separators
            let headCount = max(0, usable / 3)
            let middleCount = max(0, usable / 3)
            let tailCount = max(0, usable - headCount - middleCount)

            if headCount > 0 {
                append(String(trimmed.prefix(headCount)), limit: headCount, into: &out, remaining: &remaining)
            }
            if remaining > 0 { out.append("…"); remaining -= 1 }

            if middleCount > 0, remaining > 0 {
                let total = trimmed.count
                let midStart = max(0, min(total, (total / 2) - (middleCount / 2)))
                let start = trimmed.index(trimmed.startIndex, offsetBy: midStart)
                let end = trimmed.index(start, offsetBy: min(middleCount, total - midStart))
                append(String(trimmed[start..<end]), limit: middleCount, into: &out, remaining: &remaining)
            }
            if remaining > 0 { out.append("…"); remaining -= 1 }

            if tailCount > 0, remaining > 0 {
                append(String(trimmed.suffix(tailCount)), limit: tailCount, into: &out, remaining: &remaining)
            }
        }

        func appendEventFields(_ ev: SessionEvent, into out: inout [String], remaining: inout Int) {
            append(ev.text, into: &out, remaining: &remaining)
            append(ev.toolName, into: &out, remaining: &remaining)
            append(ev.toolInput, into: &out, remaining: &remaining)
            if let toolOut = ev.toolOutput {
                appendToolOutput(toolOut, into: &out, remaining: &remaining)
            }
        }

        if !session.events.isEmpty {
            // Head (first ~40% budget)
            if headRemaining > 0 {
                for ev in session.events {
                    appendEventFields(ev, into: &parts, remaining: &headRemaining)
                    if headRemaining <= 0 { break }
                }
            }

            // Middle sample (avoid scanning everything by sampling the middle half)
            if middleRemaining > 0, session.events.count >= 6 {
                let start = session.events.count / 4
                let end = (session.events.count * 3) / 4
                if end > start {
                    let rangeCount = end - start
                    let sampleCount = min(48, rangeCount)
                    let stride = max(1, rangeCount / sampleCount)
                    var i = start
                    while i < end && middleRemaining > 0 {
                        appendEventFields(session.events[i], into: &middleParts, remaining: &middleRemaining)
                        i += stride
                    }
                }
            }

            // Tail (last ~40% budget)
            if tailRemaining > 0 {
                for ev in session.events.reversed() {
                    appendEventFields(ev, into: &tailParts, remaining: &tailRemaining)
                    if tailRemaining <= 0 { break }
                }
            }
        }

        if !middleParts.isEmpty {
            parts.append("…")
            parts.append(contentsOf: middleParts)
        }
        if !tailParts.isEmpty {
            parts.append("…")
            parts.append(contentsOf: tailParts.reversed())
        }

        return parts.joined(separator: "\n")
    }
}
