import Foundation

/// Classifies Session presentation without changing raw transcript data.
enum MessageOriginClassifier {
    struct Context {
        var source: SessionSource
        var subagentType: String? = nil
        var isFirstUserBlock: Bool
        var parentSessionID: String? = nil
    }
    private static let scanLimit = 65_536

    static func presentation(for block: SessionTranscriptBuilder.LogicalBlock, context: Context) -> MessagePresentation? {
        guard block.kind == .user || block.kind == .assistant || (block.kind == .meta && block.messageOrigin != nil) else { return nil }
        var body = block.messageDisplayText ?? block.text
        if context.source == .codex && context.subagentType == "guardian" {
            if block.kind != .assistant {
                if let request = guardianRequest(body) {
                    return MessagePresentation(origin: .approvalRequest, body: request, summary: nil)
                }
                return MessagePresentation(origin: .context(kinds: ["guardian.history"]), body: body,
                                           summary: MessageOriginText.summary(.context(kinds: ["guardian.history"]), body: body, scanned: "", encrypted: false))
            }
            if body.utf8.prefix(scanLimit + 1).count <= scanLimit,
               let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let outcome = object["outcome"] as? String {
                let label = outcome == "allow" ? MessageOriginText.allowed : (outcome == "deny" ? MessageOriginText.denied : outcome)
                let verdict = MessageOriginText.verdict(label, object["risk_level"] as? String ?? "", object["user_authorization"] as? String ?? "")
                return MessagePresentation(origin: .approvalVerdict(outcome: outcome), body: verdict + "\n\n" + (object["rationale"] as? String ?? ""), summary: nil)
            }
        }
        var bounded = body.utf8.prefix(scanLimit + 1).count <= scanLimit
        var text = String(body[..<byteIndex(body, offset: bounded ? scanLimit : scanLimit / 2)]).trimmingCharacters(in: .whitespacesAndNewlines)
        var origin = block.messageOrigin
        let infer = origin == nil
        var isPeer: Bool { if case .peer = origin { return true }; return false }
        // Claude prompts can prepend harness reminders, with or without `human` provenance
        // (and before a peer envelope). Prove the whole discarded prefix in the same
        // contiguous inspection window; the person's tail is then classified on its own.
        if block.kind == .user && context.source == .claude && (infer || origin == .typed || isPeer),
           let tail = humanTailAfterReminders(body, end: byteIndex(body, offset: bounded ? scanLimit : scanLimit / 2)) {
            body = tail
            if infer { origin = .typed }
            bounded = body.utf8.prefix(scanLimit + 1).count <= scanLimit
            text = String(body[..<byteIndex(body, offset: bounded ? scanLimit : scanLimit / 2)]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Known display envelopes decode independently from provenance.
        // A visible event (notification, peer, command) may correct a hidden-context label:
        // a new or wrong provenance value must never hide what the reader needs.
        func select(_ candidate: MessageOrigin) {
            if infer || (origin?.isHiddenContext == true && !candidate.isHiddenContext && candidate != .typed) {
                origin = candidate
            }
        }
        // Harness command envelopes also correct a `.typed` label: the raw XML is never prose.
        func selectEnvelope(_ candidate: MessageOrigin) {
            if origin == .typed { origin = candidate } else { select(candidate) }
        }
        if block.kind == .assistant {
            if bounded && ["", "(empty)", "[REDACTED]"].contains(text) { origin = .placeholder }
            if context.source == .codex {
                let stripped = stripCitations(body)
                body = stripped.body
                if stripped.count > 0 {
                    if body.isEmpty || (body.utf8.prefix(scanLimit + 1).count <= scanLimit && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { origin = .placeholder }
                    else { body += "\n\n" + MessageOriginText.citations(stripped.count) }
                }
            }
            if !bounded && text.hasPrefix("{") { body = MessageOriginText.largeStructured + "\n\n```json\n" + body + "\n```" }
            if bounded && text.hasPrefix("{"), let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Keep the agent's own key order: multi-line JSON as written, one-line JSON re-indented.
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                body = object.isEmpty ? MessageOriginText.emptyObject
                    : fenced(trimmed.contains("\n") ? trimmed : prettyJSON(trimmed), language: "json")
            }
        } else {
            if ToolInvocationIndex.isInterruptNotice(body)
                || (block.kind == .meta && ToolInvocationIndex.isTurnAbortedNotice(text)) {
                select(.notification(kind: "interruption"))
            }
            if text.hasPrefix("<send_user_message_question_reply>") {
                select(.typed)
                if !bounded { body = MessageOriginText.largeStructuredXML + "\n\n```\n" + body + "\n```" }
            }
            if bounded, text.hasPrefix("<send_user_message_question_reply>"),
               let inner = element("send_user_message_question_reply", text), let data = inner.data(using: .utf8),
               let replies = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !replies.isEmpty, replies.allSatisfy({ $0["question"] is String }) {
                body = replies.map { reply in
                    let answer = reply["answer"] as? String ?? ""
                    return MessageOriginText.question(reply["question"] as? String ?? "", answer.isEmpty ? MessageOriginText.noAnswer : answer)
                }.joined(separator: "\n\n")
                select(.typed)
            }
            switch context.source {
            case .codex:
                if ["<environment_context>", "<user_instructions>", "# AGENTS.md instructions for", "<INSTRUCTIONS>"].contains(where: text.hasPrefix) { select(.context(kinds: ["codex.preamble"])) }
            case .claude:
                if ["<task-notification>", "[SYSTEM NOTIFICATION - NOT USER INPUT]", "<side-sessions-event>"].contains(where: text.hasPrefix) { select(.notification(kind: "task")) }
                for (prefix, from) in [("Another Claude session sent a message:", "another session"), ("The coordinator sent a message while you were working:", "coordinator")] where text.hasPrefix(prefix) {
                    select(.peer(from: from))
                    if let range = body.range(of: prefix, range: body.startIndex..<byteIndex(body, offset: scanLimit)) {
                        body = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // A message another session sent (SendMessage), recorded with `human`, `peer` or
                // no provenance: `<cross-session-message from=… name=…|from-name=… [encoded="1"]>`.
                // Show it as a peer card from the sender's session name, without the envelope.
                if text.hasPrefix("<cross-session-message"),
                   let opener = text.range(of: #"^<cross-session-message(?:\s[^>]*)?>"#, options: .regularExpression) {
                    let attributes = String(text[opener])
                    let name = attribute("from-name", attributes) ?? attribute("name", attributes)
                    let from = name.flatMap { $0.isEmpty ? nil : $0 } ?? "another session"
                    if isPeer { origin = .peer(from: from) } else { selectEnvelope(.peer(from: from)) }
                    if isPeer, let inner = envelope("cross-session-message", body) {
                        body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Current Claude records lead with <command-message>, older ones with <command-name>.
                if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
                    if let name = element("command-name", text) {
                        selectEnvelope(.command(name: name))
                        let args = envelope("command-args", body)
                        if let args { body = "```\n" + name + (args.isEmpty ? "" : " " + args) + "\n```" }
                        else if !text.contains("<command-args") && bounded { body = "```\n" + name + "\n```" }
                        else if !bounded { body = structuredFallback(body) }
                    } else if !bounded { body = structuredFallback(body) }
                }
                if text.hasPrefix("<local-command-caveat>") || text.hasPrefix("Caveat: The messages below were generated") { select(.context(kinds: ["claude.caveat"])) }
            case .grok:
                if let query = envelope("user_query", body) { select(.typed); body = query.isEmpty ? MessageOriginText.emptyInput : query }
                else if !bounded && text.contains("<user_query>") { select(.typed); body = structuredFallback(body) }
                else if bounded, onlyElements(text, allowed: ["user_info", "rules", "git_status", "always_applied_workspace_rules", "skills_referenced"]) != nil { select(.context(kinds: ["grok.context"])) }
            case .cline:
                if text.hasPrefix("<user_input") {
                    select(.typed)
                    if let inner = envelope("user_input", body) { body = inner.isEmpty ? MessageOriginText.emptyInput : inner }
                    else if !bounded { body = structuredFallback(body) }
                }
            case .cursor:
                if text.hasPrefix("<timestamp>") {
                    select(.typed)
                    // This prefix is discarded, so its first closer must be proven
                    // contiguously. A suffix match could be quoted prompt content.
                    let prefixEnd = byteIndex(body, offset: bounded ? scanLimit : scanLimit / 2)
                    let close = body.range(of: "</timestamp>", range: body.startIndex..<prefixEnd)
                    if let close { body = String(body[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if body.isEmpty { body = MessageOriginText.emptyInput }
                    } else if !bounded { body = structuredFallback(body) }
                }
            case .hermes:
                if text.hasPrefix("[SYSTEM: You are running as a scheduled cron job") || text.hasPrefix("[IMPORTANT: You are running as a scheduled cron job") { select(.scheduled(kind: "cron")) }
                if text.hasPrefix("You just executed tool calls but returned an empty response") { select(.harnessRetry) }
            case .openclaw:
                if text.hasPrefix("[OpenClaw heartbeat poll]") || text.hasPrefix("Read HEARTBEAT.md if exists") { select(.scheduled(kind: "heartbeat")) }
                if text.hasPrefix("[cron:") || text.range(of: #"^System: \[\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { select(.scheduled(kind: "cron")) }
                if text.hasPrefix("Conversation info (untrusted metadata):") { select(.context(kinds: ["openclaw.metadata"])) }
            default: break
            }
            if context.source == .claude || context.source == .kimi {
                for tag in ["local-command-stdout", "bash-input", "bash-stdout", "bash-stderr"] where text.hasPrefix("<" + tag + ">") {
                    selectEnvelope(.command(name: tag == "bash-input" ? "!" : "output"))
                    if let inner = envelope(tag, body) { body = "```\n" + inner + "\n```" }
                    else if !bounded { body = structuredFallback(body) }
                }
            }
            if bounded, onlyElements(text, allowed: ["system-reminder"]) != nil { select(.context(kinds: ["system-reminder"])) }
            if infer && origin == nil && bounded, let first = onlyElements(text, allowed: nil) { origin = .context(kinds: [first]) }
            if origin == nil { origin = .typed }
            // Text the person pasted: keep every word, drop only the tags.
            if context.source == .claude && origin == .typed && bounded, let pasted = pastedContent(body) { body = pasted }
        }
        if block.kind == .user && origin == .typed && context.isFirstUserBlock &&
            (context.parentSessionID != nil || context.subagentType != nil) { origin = .parentTask }
        // Peers are transport data: never return an uninspected tail.
        if case .peer = origin {
            var peerEncrypted = block.messageHasEncryptedContent == true
            let overflow = body.utf8.prefix(scanLimit + 1).count > scanLimit
            if overflow { body = String(body[..<byteIndex(body, offset: scanLimit - 16)]) }
            if body.hasPrefix("Message Type:") {
                if let payload = body.range(of: "\nPayload:") {
                    body = String(body[payload.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !body.contains("\n") { body = "" }
            }
            if let marker = body.range(of: "gAAAAA") {
                peerEncrypted = true
                body = String(body[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if overflow { body += "\n\n" + MessageOriginText.omittedPeerTail }
            if peerEncrypted && !body.isEmpty { body += "\n\n" + MessageOriginText.encryptedContent }
        }
        let summary = MessageOriginText.summary(origin, body: body, scanned: text, encrypted: block.messageHasEncryptedContent == true || text.contains("gAAAAA"))
        return MessagePresentation(origin: origin, body: body, summary: summary)
    }
    /// Strip only complete leading legacy reminders when a nonempty tail is proven.
    /// An ambiguous reminder aborts the entire removal; never inspect a distant closer.
    private static func humanTailAfterReminders(_ text: String, end: String.Index) -> String? {
        var cursor = text.startIndex
        var found = false
        while cursor < end {
            while cursor < end && text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            guard cursor < end else { return nil }
            let remaining = text[cursor..<end]
            guard remaining.hasPrefix("<system-reminder>") else {
                // A partial opener at the window edge is not proven human text.
                guard found, !remaining.hasPrefix("<system-reminder"),
                      !"<system-reminder>".hasPrefix(remaining) else { return nil }
                return String(text[cursor...])
            }
            let contentStart = text.index(cursor, offsetBy: "<system-reminder>".count)
            guard let close = text.range(of: "</system-reminder>", range: contentStart..<end),
                  text.range(of: "<system-reminder", range: contentStart..<close.lowerBound) == nil else { return nil }
            found = true
            cursor = close.upperBound
        }
        return nil
    }
    /// Only parse a complete request within one bounded window, never quoted history across a gap.
    private static func guardianRequest(_ text: String) -> String? {
        for window in windows(text).reversed() {
            guard let start = text.range(of: ">>> APPROVAL REQUEST START", options: .backwards, range: window),
                  let end = text.range(of: ">>> APPROVAL REQUEST END", range: start.upperBound..<window.upperBound) else { continue }
            let request = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let marker = request.range(of: "Planned action JSON:"),
                  let data = request[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? [String], !command.isEmpty,
                  let cwd = object["cwd"] as? String, let tool = object["tool"] as? String,
                  let justification = object["justification"] as? String,
                  let sandbox = object["sandbox_permissions"] as? String else { return fenced(request) }
            let script: String
            if command.count == 3 && command[0].hasSuffix("sh") && ["-c", "-lc"].contains(command[1]) { script = command[2] }
            else { script = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ") }
            return "**" + tool + "** · `" + cwd + "`\n\n" + fenced(script, language: "sh") + "\n\n" + MessageOriginText.justification(justification) + "\n" + MessageOriginText.sandbox(sandbox)
        }
        return nil
    }
    private static func fenced(_ text: String, language: String = "") -> String {
        var longest = 0, run = 0
        for character in text {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + "\n" + fence
    }
    private static func structuredFallback(_ body: String) -> String {
        MessageOriginText.largeStructuredXML + "\n\n```\n" + body + "\n```"
    }
    /// Converts a bounded byte offset to a valid String boundary without splitting UTF-8.
    private static func byteIndex(_ text: String, offset: Int) -> String.Index {
        var index = text.utf8.index(text.utf8.startIndex, offsetBy: offset, limitedBy: text.utf8.endIndex) ?? text.utf8.endIndex
        while String.Index(index, within: text) == nil { index = text.utf8.index(before: index) }
        return String.Index(index, within: text)!
    }
    private static func windows(_ text: String) -> [Range<String.Index>] {
        let mid = byteIndex(text, offset: scanLimit / 2)
        if mid == text.endIndex { return [text.startIndex..<text.endIndex] }
        // Suffix work is separately bounded; total inspected bytes never exceeds 64 KiB.
        var tail = text.utf8.index(text.utf8.endIndex, offsetBy: -(scanLimit / 2), limitedBy: text.utf8.startIndex) ?? text.utf8.startIndex
        while String.Index(tail, within: text) == nil { tail = text.utf8.index(after: tail) }
        let start = String.Index(tail, within: text)!
        if start <= mid { return [text.startIndex..<text.endIndex] }
        return [text.startIndex..<mid, start..<text.endIndex]
    }
    /// Known outer envelopes can be removed using only a bounded opening and closing window.
    private static func envelope(_ tag: String, _ text: String) -> String? {
        let ranges = windows(text)
        guard let open = text.range(of: "<" + tag + #"(?:\s[^>]*)?>"#, options: .regularExpression, range: ranges[0]) else { return nil }
        for range in ranges.reversed() {
            if let close = text.range(of: "</" + tag + ">", options: .backwards, range: range), close.lowerBound >= open.upperBound {
                return String(text[open.upperBound..<close.lowerBound])
            }
        }
        return nil
    }
    /// Exact citation normalization is the sole full-text inspection exception.
    /// Literal token scanning is linear and never pairs across unseen input.
    private static func stripCitations(_ text: String) -> (body: String, count: Int) {
        var cursor = text.startIndex
        var stack: [(tag: String, start: String.Index)] = []
        var removals: [Range<String.Index>] = []
        let tags = ["oai-mem-citation", "citation_entries"]
        while cursor < text.endIndex, let marker = text.range(of: "<", options: .literal, range: cursor..<text.endIndex) {
            let suffix = text[marker.lowerBound...]
            var recognized = false
            for tag in tags {
                let opener = "<" + tag + ">", closer = "</" + tag + ">"
                if suffix.hasPrefix(opener) {
                    // Repeated same-name openers are malformed: retain the earlier
                    // unmatched region rather than swallowing its answer prose.
                    if stack.contains(where: { $0.tag == tag }) { stack.removeAll(keepingCapacity: true) }
                    stack.append((tag, marker.lowerBound))
                    cursor = text.index(marker.lowerBound, offsetBy: opener.count)
                    recognized = true
                    break
                }
                if suffix.hasPrefix(closer) {
                    let end = text.index(marker.lowerBound, offsetBy: closer.count)
                    if stack.last?.tag == tag, let opened = stack.popLast(), stack.isEmpty {
                        removals.append(opened.start..<end)
                    }
                    cursor = end
                    recognized = true
                    break
                }
            }
            if !recognized { cursor = marker.upperBound }
        }
        guard !removals.isEmpty else { return (text, 0) }
        var pieces: [Substring] = []
        var start = text.startIndex
        for range in removals {
            pieces.append(text[start..<range.lowerBound])
            start = range.upperBound
        }
        pieces.append(text[start...])
        return (pieces.joined(), removals.count)
    }
    private static func element(_ tag: String, _ text: String) -> String? {
        guard let start = text.range(of: "<" + tag + #"(?:\s[^>]*)?>"#, options: .regularExpression),
              let end = text.range(of: "</" + tag + ">", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
    private static func onlyElements(_ text: String, allowed: Set<String>?) -> String? {
        var remaining = text[...], first: String?
        while !remaining.isEmpty {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            guard let match = trimmed.range(of: #"^<([A-Za-z][A-Za-z0-9_-]*)(?:\s[^>]*)?>"#, options: .regularExpression) else { return nil }
            let opener = String(trimmed[match]); let tag = String(opener.dropFirst().prefix { $0 != ">" && !$0.isWhitespace })
            if let allowed { guard allowed.contains(tag) else { return nil } }
            else { guard tag.contains("_") || tag.contains("-"), !["annotation-xml", "font-face", "missing-glyph"].contains(tag) else { return nil } }
            guard let close = trimmed.range(of: "</" + tag + ">", range: match.upperBound..<trimmed.endIndex) else { return nil }
            first = first ?? tag
            remaining = trimmed[close.upperBound...]
        }
        return first
    }
    /// Re-indents already-validated one-line JSON without reordering keys or re-escaping strings.
    static func prettyJSON(_ json: String) -> String {
        var out = "", depth = 0, inString = false, escaped = false
        let characters = Array(json)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[":
                var next = i + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == (c == "{" ? "}" : "]") {
                    out += c == "{" ? "{}" : "[]"; i = next
                } else { out.append(c); depth += 1; newline() }
            case "}", "]": depth = max(0, depth - 1); newline(); out.append(c)
            case ",": out.append(c); newline()
            case ":": out += ": "
            default: if !c.isWhitespace { out.append(c) }
            }
        }
        return out
    }
    /// The value of `name="…"` in an XML opening tag, with the five basic entities decoded.
    private static func attribute(_ name: String, _ opener: String) -> String? {
        guard let match = opener.range(of: #"\s"# + name + #"="[^"]*""#, options: .regularExpression) else { return nil }
        let quoted = opener[match].drop { $0 != "\"" }.dropFirst().dropLast()
        return String(quoted).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
    /// Claude wraps pasted text in `<pasted_content id="…">…</pasted_content id="…">`. Each closed
    /// paste becomes a labeled fenced block; the person's own words around it stay unchanged.
    /// An unclosed paste leaves the rest of the text as written.
    private static func pastedContent(_ text: String) -> String? {
        var parts: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: #"<pasted_content(?:\s[^>]*)?>"#, options: .regularExpression, range: cursor..<text.endIndex),
              let close = text.range(of: #"</pasted_content(?:\s[^>]*)?>"#, options: .regularExpression, range: open.upperBound..<text.endIndex) {
            let before = text[cursor..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { parts.append(before) }
            let pasted = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .newlines)
            parts.append(MessageOriginText.pastedText + "\n\n" + fenced(pasted))
            cursor = close.upperBound
        }
        guard !parts.isEmpty else { return nil }
        let rest = text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { parts.append(rest) }
        return parts.joined(separator: "\n\n")
    }
}

enum MessageOriginText {
    static func peerDisplayName(_ value: String) -> String {
        switch value {
        case "another session": return String(localized: "another session")
        case "coordinator": return String(localized: "coordinator")
        default: return value
        }
    }
    static var allowed: String { String(localized: "Allowed", comment: "Guardian approval outcome.") }
    static var denied: String { String(localized: "Denied", comment: "Guardian approval outcome.") }
    static func justification(_ value: String) -> String { String(localized: "**Justification:** \(value)", comment: "Guardian planned action justification.") }
    static func sandbox(_ value: String) -> String { String(localized: "Sandbox: \(value)", comment: "Guardian sandbox permissions.") }
    static func verdict(_ outcome: String, _ risk: String, _ authorization: String) -> String { String(localized: "**\(outcome)** · risk \(risk) · user authorization \(authorization)", comment: "Guardian outcome, risk and user authorization.") }

    static var emptyObject: String { String(localized: "Empty structured message", comment: "Readable assistant presentation for an empty JSON object.") }
    static var emptyInput: String { String(localized: "No input text", comment: "Readable presentation for an empty decoded user envelope.") }
    static var largeStructuredXML: String { String(localized: "Large structured message · shown without envelope decoding", comment: "A large structured envelope cannot be fully parsed within the display scan budget.") }
    static var omittedPeerTail: String { String(localized: "Peer message preview · remaining content omitted", comment: "Uninspected peer transport tail is never displayed.") }
    static var encryptedContent: String { String(localized: "Additional content encrypted in the log", comment: "Card-visible notice accompanying readable partial peer content.") }
    static var largeStructured: String { String(localized: "Large structured message · shown without field formatting", comment: "Large JSON is preserved without parsing beyond the display scan budget.") }
    static var noAnswer: String { String(localized: "No answer", comment: "Question reply without an answer.") }
    static func question(_ question: String, _ answer: String) -> String { String(localized: "**Question:** \(question)\n\n**Answer:** \(answer)", comment: "Readable question and answer from a tool reply.") }
    static func citations(_ count: Int) -> String { String(localized: "*Memory citations: \(count)*", comment: "Number of hidden memory citation blocks.") }
    static func summary(_ origin: MessageOrigin?, body: String, scanned: String, encrypted: Bool) -> String? {
        switch origin {
        case .context(let kinds):
            var labels: [String] = []
            for label in kinds.map(contextLabel) where !labels.contains(label) { labels.append(label) }
            return String(localized: "Context · \(labels.joined(separator: ", "))", comment: "Injected context kinds.")
        case .skill(let name): return String(localized: "Skill loaded · \(name)", comment: "Loaded skill name.")
        case .compaction: return String(localized: "Conversation compacted", comment: "Conversation compaction notice.")
        case .scheduled(let kind):
            let first = String(scanned.prefix(80).split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
            return String(localized: "Scheduled prompt · \(kind) · \(first)", comment: "Scheduled prompt kind and preview.")
        case .harnessRetry: return String(localized: "Harness asked the agent to continue", comment: "Harness retry notice.")
        case .peer(let rawFrom):
            let from = peerDisplayName(rawFrom)
            if encrypted { return String(localized: "Message from \(from) · content encrypted in the log", comment: "Peer content is encrypted.") }
            return String(localized: "Message received from \(from)", comment: "Peer message received.")
        case .notification(let kind):
            if kind == "interruption" { return String(localized: "Request interrupted", comment: "A recorded user-interruption control notice.") }
            if let summary = capture("summary", scanned), let raw = capture("status", scanned) {
                let status = taskStatus(raw)
                return String(localized: "Background task \(status) · \(summary)", comment: "Task status and summary.")
            }
            return String(localized: "Background task update", comment: "Background task notification.")
        default: return nil
        }
    }
    static var pastedText: String { String(localized: "*Pasted text*", comment: "Small label above text the person pasted into a prompt. Keep the asterisks (Markdown italics).") }
    /// A short reader label for an injected-context kind id; unknown ids read as words.
    static func contextLabel(_ kind: String) -> String {
        if kind.hasPrefix("agents_md.") { return "AGENTS.md" }
        if kind.hasPrefix("additional_content.codex_apps_selected_page_part") {
            return String(localized: "selected page", comment: "Context kind: the part of a page the person selected.")
        }
        switch kind {
        case "environments.environment_context", "environment_context":
            return String(localized: "environment", comment: "Context kind: working directory, shell and date.")
        case "codex.preamble": return String(localized: "instructions", comment: "Context kind: agent instructions.")
        case "additional_content.codex_apps_open_page": return String(localized: "open page", comment: "Context kind: the page open in an app.")
        case "goal.internal_context": return String(localized: "goal", comment: "Context kind: the session goal.")
        case "system-reminder": return String(localized: "system reminder", comment: "Context kind: a harness reminder.")
        case "claude.meta": return String(localized: "harness note", comment: "Context kind: a note the harness added.")
        case "claude.caveat": return String(localized: "command caveat", comment: "Context kind: a caveat about local command output.")
        case "grok.context": return String(localized: "workspace info", comment: "Context kind: workspace details.")
        case "openclaw.metadata": return String(localized: "metadata", comment: "Context kind: conversation metadata.")
        case "guardian.history": return String(localized: "review history", comment: "Context kind: earlier approval reviews.")
        default:
            return kind.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        }
    }
    /// A localized background-task status; unknown values stay as recorded.
    static func taskStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "completed", "complete", "done", "success": return String(localized: "completed", comment: "Background task status.")
        case "failed", "failure", "error": return String(localized: "failed", comment: "Background task status.")
        case "running", "in_progress": return String(localized: "running", comment: "Background task status.")
        case "killed", "cancelled", "canceled", "stopped": return String(localized: "stopped", comment: "Background task status: killed or cancelled.")
        default: return raw
        }
    }
    private static func capture(_ tag: String, _ text: String) -> String? {
        guard let a = text.range(of: "<" + tag + ">"), let b = text.range(of: "</" + tag + ">", range: a.upperBound..<text.endIndex) else { return nil }
        let value = String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
