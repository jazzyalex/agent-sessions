import Foundation

enum SessionSearchTextBuilder {
    // Redact embedded binary-ish blobs (base64, data: URLs) from search corpora.
    // This protects Instant search and Tool I/O FTS from ballooning DB size and from
    // indexing meaningless tokens (e.g., screenshots from Chrome MCP).
    private static let base64RunMinChars = 2_048
    private static let dataURLMinChars = 256

    private static func sanitizeForIndexing(_ text: String) -> String {
        // Fast path: avoid scanning small strings.
        if text.count < 512 { return text }

        var out = text
        out = redactDataURLs(in: out)
        out = redactLongBase64Runs(in: out)
        return out
    }

    private static func redactDataURLs(in text: String) -> String {
        // Only bother if we see obvious markers.
        if !(text.contains("data:") && text.contains(";base64,")) { return text }

        var out = ""
        out.reserveCapacity(min(text.utf16.count, 32_768))

        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix("data:"),
               let base64Range = text.range(of: ";base64,", range: i..<text.endIndex) {
                // Extract media type if present (data:<mediaType>;base64,...)
                let mediaStart = text.index(i, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
                let mediaType = (mediaStart < base64Range.lowerBound) ? String(text[mediaStart..<base64Range.lowerBound]) : "application/octet-stream"

                let payloadStart = base64Range.upperBound
                var end = payloadStart
                var payloadChars = 0

                func isTerminator(_ ch: Character) -> Bool {
                    switch ch {
                    case " ", "\t", "\n", "\r", "\"", "'", ")", "]", "}", ">":
                        return true
                    default:
                        return false
                    }
                }

                while end < text.endIndex {
                    let ch = text[end]
                    if isTerminator(ch) { break }
                    payloadChars += 1
                    end = text.index(after: end)
                }

                // Only redact when the payload is meaningfully large; keep tiny data URLs intact.
                let totalLen = text.distance(from: i, to: end)
                if totalLen >= dataURLMinChars {
                    let approxBytes = max(0, (payloadChars * 3) / 4)
                    let approxKB = Int((Double(approxBytes) / 1024.0).rounded())
                    out += "[data-url omitted: \(mediaType), approx \(approxKB) KB]"
                    i = end
                    continue
                }
            }

            out.append(text[i])
            i = text.index(after: i)
        }

        return out
    }

    private static func redactLongBase64Runs(in text: String) -> String {
        // If there are no base64-ish characters, bail quickly.
        if text.count < base64RunMinChars { return text }

        func isBase64Char(_ ch: Character) -> Bool {
            switch ch {
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=", "-", "_":
                return true
            default:
                return false
            }
        }

        func isSpecialBase64Marker(_ ch: Character) -> Bool {
            switch ch {
            case "+", "/", "=", "-", "_":
                return true
            default:
                return false
            }
        }

        var out = ""
        out.reserveCapacity(min(text.utf16.count, 32_768))

        var i = text.startIndex
        while i < text.endIndex {
            if isBase64Char(text[i]) {
                let start = i
                var end = i
                var count = 0
                var sawSpecial = false

                while end < text.endIndex, isBase64Char(text[end]) {
                    count += 1
                    if isSpecialBase64Marker(text[end]) { sawSpecial = true }
                    end = text.index(after: end)
                }

                // To avoid false positives, require both a long run and at least one
                // base64 marker char that rarely appears in normal text/code.
                if count >= base64RunMinChars && sawSpecial {
                    let approxBytes = max(0, (count * 3) / 4)
                    let approxKB = Int((Double(approxBytes) / 1024.0).rounded())
                    out += "[base64 omitted: approx \(approxKB) KB]"
                    i = end
                    continue
                }

                out += text[start..<end]
                i = end
                continue
            }

            out.append(text[i])
            i = text.index(after: i)
        }

        return out
    }

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
            value = sanitizeForIndexing(value)
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

        func appendSampledLargeText(_ raw: String, maxOut: Int, into out: inout [String], remaining: inout Int) {
            guard remaining > 0 else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let budget = min(maxOut, remaining)
            guard budget > 0 else { return }

            if trimmed.count <= budget {
                append(trimmed, limit: budget, into: &out, remaining: &remaining)
                return
            }

            // Include head + middle + tail so Instant can match terms that only appear
            // in the middle of long assistant messages or tool inputs without indexing the full blob.
            if budget < 32 {
                append(String(trimmed.prefix(budget)), limit: budget, into: &out, remaining: &remaining)
                return
            }

            let usable = max(0, budget - 2) // reserve for two separators
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
            appendSampledLargeText(toolOut, maxOut: maxOut, into: &out, remaining: &remaining)
        }

        func appendEventFields(_ ev: SessionEvent, into out: inout [String], remaining: inout Int) {
            if let t = ev.text, !t.isEmpty {
                appendSampledLargeText(t, maxOut: perFieldLimit, into: &out, remaining: &remaining)
            }
            append(ev.toolName, into: &out, remaining: &remaining)
            if let ti = ev.toolInput, !ti.isEmpty {
                appendSampledLargeText(ti, maxOut: perFieldLimit, into: &out, remaining: &remaining)
            }
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

    /// Builds a tool-only corpus intended for FTS indexing (no head/middle/tail sampling).
    /// Bounded by `maxCharacters` to avoid unbounded DB growth.
    static func buildToolIO(session: Session, maxCharacters: Int = FeatureFlags.toolIOIndexMaxCharsPerSession, perFieldLimit: Int = FeatureFlags.toolIOIndexMaxCharsPerEvent) -> String {
        guard !session.events.isEmpty else { return "" }
        var parts: [String] = []
        parts.reserveCapacity(256)

        func normalized(_ value: String?, limit: Int) -> String? {
            guard var value, !value.isEmpty else { return nil }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.count > limit { value = String(value.prefix(limit)) }
            value = sanitizeForIndexing(value)
            return value.isEmpty ? nil : value
        }

        func append(_ value: String?, limit: Int = perFieldLimit, into out: inout [String], remaining: inout Int) {
            guard remaining > 0 else { return }
            guard var value = normalized(value, limit: limit) else { return }
            if value.count > remaining { value = String(value.prefix(remaining)) }
            guard !value.isEmpty else { return }
            out.append(value)
            remaining -= value.count
        }

        var remaining = maxCharacters
        for ev in session.events {
            guard remaining > 0 else { break }
            switch ev.kind {
            case .tool_call:
                append(ev.toolName, into: &parts, remaining: &remaining)
                append(ev.toolInput, into: &parts, remaining: &remaining)
            case .tool_result:
                append(ev.toolName, into: &parts, remaining: &remaining)
                append(ev.toolOutput ?? ev.text, into: &parts, remaining: &remaining)
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }
}
