import Foundation
import CryptoKit

/// Parser for Claude Code session format
final class ClaudeSessionParser {
    // Keep per-event raw JSON bounded. Claude tool results can embed large base64 blobs
    // (e.g., screenshots from Chrome MCP), which otherwise balloon memory and stall UI.
    private static let maxRawJSONFieldBytes = 8_192
    private static let maxFallbackStringifyBytes = 64_000

    /// Parse a Claude Code session file
    static func parseFile(at url: URL) -> Session? {
        // Check file size for lightweight optimization
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        // Prefer lightweight metadata-first parsing for all files at launch.
        // This keeps Claude Stage 1 bounded even with many sessions.
        if let light = lightweightSession(from: url, size: size, mtime: mtime) {
            #if DEBUG
            print("✅ LIGHTWEIGHT CLAUDE: \(url.lastPathComponent) estEvents=\(light.eventCount) messageCount=\(light.messageCount)")
            #endif
            return light
        }

        // Fallback: full parse only when lightweight path fails.
        return parseFileFull(at: url)
    }

    /// Full parse of Claude Code session file
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        var sessionID: String?
        var model: String?
        var cwd: String?
        var gitBranch: String?
        var tmin: Date?
        var tmax: Date?
        var idx = 0

        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                // Extract session-level metadata from first few events
                if sessionID == nil, let sid = obj["sessionId"] as? String {
                    sessionID = sid
                }
                if cwd == nil {
                    if let cwdVal = obj["cwd"] as? String, Self.isValidPath(cwdVal) {
                        cwd = cwdVal
                    } else if let projectVal = obj["project"] as? String, Self.isValidPath(projectVal) {
                        cwd = projectVal
                    }
                }
                if gitBranch == nil, let branch = obj["gitBranch"] as? String {
                    gitBranch = branch
                }
                if model == nil, let ver = obj["version"] as? String {
                    model = "Claude Code \(ver)"
                }

                // Extract timestamp
                if let ts = extractTimestamp(from: obj) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                // Parse event
                let baseID = eventID(for: url, index: idx)
                let parsed = parseLineEvents(obj, baseEventID: baseID)
                events.append(contentsOf: parsed)
            }
        } catch {
            #if DEBUG
            print("❌ Failed to read Claude session: \(error)")
            #endif
            return nil
        }

        // Use per-file stable ID to match Sessions list expectations
        let fileID = forcedID ?? hash(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        return Session(
            id: fileID,
            source: .claude,
            startTime: tmin,
            endTime: tmax,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )
    }

    // MARK: - Event Parsing

    private static func parseLine(_ obj: [String: Any], eventID: String) -> SessionEvent {
        let derived = parseLineEvents(obj, baseEventID: eventID)
        if let preferred = derived.first(where: { $0.kind == .user || $0.kind == .assistant }) {
            return preferred
        }
        return derived.first ?? SessionEvent(
            id: eventID,
            timestamp: extractTimestamp(from: obj),
            kind: .meta,
            role: "meta",
            text: nil,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: obj["uuid"] as? String,
            parentID: obj["parentUuid"] as? String,
            isDelta: false,
            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
        )
    }

    /// Full-fidelity parse for a single JSONL object.
    /// Claude Code can embed `tool_use`, `tool_result`, and `thinking` blocks inside `message.content[]`.
    /// We split these into separate `SessionEvent`s to avoid collapsing tool activity into a single line.
    private static func parseLineEvents(_ obj: [String: Any], baseEventID: String) -> [SessionEvent] {
        let timestamp = extractTimestamp(from: obj)
        let rawJSON = rawJSONBase64(sanitizeLargeStrings(in: obj))
        let messageID = obj["uuid"] as? String
        let parentID = obj["parentUuid"] as? String

        // Handle explicit top-level tool events (rare but supported).
        if let t = (obj["type"] as? String)?.lowercased() {
            if t == "tool_use" || t == "tool_call" {
                let toolName = obj["name"] as? String ?? obj["tool"] as? String
                let toolInput = obj["input"].flatMap(stringifyJSONBounded)
                return [
                    SessionEvent(
                        id: baseEventID,
                        timestamp: timestamp,
                        kind: .tool_call,
                        role: "assistant",
                        text: nil,
                        toolName: toolName,
                        toolInput: toolInput,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                ]
            }
            if t == "tool_result" {
                let toolOutput = obj["output"].flatMap(stringifyJSONBounded)
                return [
                    SessionEvent(
                        id: baseEventID,
                        timestamp: timestamp,
                        kind: .tool_result,
                        role: "tool",
                        text: nil,
                        toolName: obj["name"] as? String ?? obj["tool"] as? String,
                        toolInput: nil,
                        toolOutput: toolOutput,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                ]
            }
        }

        // Base role inference (block parsing below derives role/kind per block when possible).
        let eventType = obj["type"] as? String
        var role: String?
        var baseText: String?

        if let message = obj["message"] as? [String: Any], let mr = (message["role"] as? String)?.lowercased() {
            if mr == "user" || mr == "human" { role = "user" }
            else if mr == "assistant" || mr == "model" { role = "assistant" }
            else if mr == "system" { role = "system" }
        }

        if role == nil {
            switch eventType?.lowercased() {
            case "user", "user_input", "user-input", "input", "prompt", "chat_input", "chat-input", "human":
                role = "user"
            case "assistant", "response", "assistant_message", "assistant-message", "assistant_response", "assistant-response", "completion":
                role = "assistant"
            case "system":
                role = "system"
            default:
                if let explicitRole = (obj["role"] as? String) ?? (obj["sender"] as? String) {
                    let lower = explicitRole.lowercased()
                    if lower == "user" || lower == "human" { role = "user" }
                    else if lower == "assistant" || lower == "model" { role = "assistant" }
                }
            }
        }

        if let message = obj["message"] as? [String: Any] {
            // Only use baseText when there's no block array to split; otherwise we build text from blocks.
            if (message["content"] as? [[String: Any]]) == nil {
                baseText = extractContent(from: message)
            }
        }
        if baseText == nil {
            baseText = extractContent(from: obj)
        }

        if role == nil {
            role = baseText?.isEmpty == false ? "assistant" : "meta"
        }

        // If we have message.content blocks, split them into events in-order.
        if let message = obj["message"] as? [String: Any],
           let contentArray = message["content"] as? [[String: Any]] {
            // Claude's tool_result blocks (including failures) frequently appear on JSONL lines whose
            // top-level type is "user". Always parse message.content blocks, then derive role/kind
            // per block instead of relying on the parent line type.

            var out: [SessionEvent] = []
            var textBuffer: [String] = []
            var seq = 0

            func makeID(_ suffix: String) -> String {
                baseEventID + suffix
            }

            func flushTextIfNeeded() {
                let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                textBuffer.removeAll(keepingCapacity: true)
                guard !joined.isEmpty else { return }
                seq += 1
                let inferred = (role ?? "assistant").lowercased()
                let kind: SessionEventKind
                let outRole: String?
                if inferred == "user" {
                    kind = .user
                    outRole = "user"
                } else if inferred == "assistant" {
                    kind = .assistant
                    outRole = "assistant"
                } else if inferred == "system" {
                    kind = .meta
                    outRole = "system"
                } else {
                    kind = .assistant
                    outRole = "assistant"
                }
                out.append(
                    SessionEvent(
                        id: makeID(String(format: "-p%02d", seq)),
                        timestamp: timestamp,
                        kind: kind,
                        role: outRole,
                        text: joined,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                )
            }

            for block in contentArray {
                let t = (block["type"] as? String)?.lowercased()
                switch t {
                case "text":
                    if let s = block["text"] as? String {
                        textBuffer.append(s)
                    }
                case "thinking":
                    flushTextIfNeeded()
                    if let s = block["thinking"] as? String, !s.isEmpty {
                        seq += 1
                        out.append(
                            SessionEvent(
                                id: makeID(String(format: "-m%02d", seq)),
                                timestamp: timestamp,
                                kind: .meta,
                                role: "assistant",
                                text: "[thinking]\n" + s,
                                toolName: nil,
                                toolInput: nil,
                                toolOutput: nil,
                                messageID: messageID,
                                parentID: parentID,
                                isDelta: false,
                                rawJSON: rawJSON
                            )
                        )
                    }
                case "tool_use", "tool-use", "tool_call", "tool-call":
                    flushTextIfNeeded()
                    seq += 1
                    let toolName = (block["name"] as? String) ?? (block["tool"] as? String)
                    let toolInput = block["input"].flatMap(stringifyJSON)
                    out.append(
                        SessionEvent(
                            id: makeID(String(format: "-t%02d", seq)),
                            timestamp: timestamp,
                            kind: .tool_call,
                            role: "assistant",
                            text: nil,
                            toolName: toolName,
                            toolInput: toolInput,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSON
                        )
                    )
                case "tool_result", "tool-result":
                    flushTextIfNeeded()
                    seq += 1
                    let (toolOutput, disposition) = extractToolResultOutput(from: obj, block: block)
                    let kind: SessionEventKind
                    let role: String?
                    let text: String?
                    let toolOutputField: String?
                    switch disposition {
                    case .runtimeError:
                        kind = .error
                        role = "tool"
                        text = toolOutput
                        toolOutputField = nil
                    case .rejectedOrPermissions:
                        // Hide by default (meta is off), but keep for JSON inspection.
                        kind = .meta
                        role = "system"
                        text = toolOutput.flatMap { "Rejected tool use: " + $0 }
                        toolOutputField = nil
                    case .notFoundOrMismatch:
                        kind = .tool_result
                        role = "tool"
                        text = nil
                        toolOutputField = toolOutput
                    case .otherToolFailure:
                        // Keep visible as tool output unless we can confidently call it runtime-ish.
                        kind = .tool_result
                        role = "tool"
                        text = nil
                        toolOutputField = toolOutput
                    case .ok:
                        kind = .tool_result
                        role = "tool"
                        text = nil
                        toolOutputField = toolOutput
                    }
                    out.append(
                        SessionEvent(
                            id: makeID(String(format: "-r%02d", seq)),
                            timestamp: timestamp,
                            kind: kind,
                            role: role,
                            text: text,
                            toolName: (block["name"] as? String) ?? (block["tool"] as? String),
                            toolInput: nil,
                            toolOutput: toolOutputField,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSON
                        )
                    )
                default:
                    // Fallback: if there's a text field, treat as assistant-visible text.
                    if let s = block["text"] as? String {
                        textBuffer.append(s)
                    }
                }
            }
            flushTextIfNeeded()

            // If we didn't produce anything, fall back to base behavior.
            if out.isEmpty {
                let baseKind = SessionEventKind.from(role: role, type: eventType)
                return [
                    SessionEvent(
                        id: baseEventID,
                        timestamp: timestamp,
                        kind: baseKind,
                        role: role,
                        text: baseText,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                ]
            }

            return out
        }

        // No block array: return a single base event.
        let et = eventType?.lowercased()
        let isMetaEvent = (et == "summary" || et == "file-history-snapshot" || et == "meta") && (role == nil || role == "meta")
        let baseKind = SessionEventKind.from(role: role, type: eventType)
        return [
            SessionEvent(
                id: baseEventID,
                timestamp: timestamp,
                kind: isMetaEvent ? .meta : baseKind,
                role: role,
                text: baseText,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: messageID,
                parentID: parentID,
                isDelta: false,
                rawJSON: rawJSON
            )
        ]
    }

    private enum ToolResultDisposition {
        case ok
        case runtimeError
        case rejectedOrPermissions
        case notFoundOrMismatch
        case otherToolFailure
    }

    private static func extractToolResultOutput(from obj: [String: Any], block: [String: Any]) -> (String?, ToolResultDisposition) {
        var output: String? = nil
        let explicitBlockIsError = (block["is_error"] as? Bool) == true
        var toolResultIsError: Bool = false
        var isFilePayload: Bool = false

        // Prefer a summarized string when available.
        if let resultString = obj["toolUseResult"] as? String {
            let t = resultString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { output = t }
        }

        if let result = obj["toolUseResult"] as? [String: Any] {
            if let t = (result["type"] as? String)?.lowercased(), t == "file" || result["file"] != nil {
                isFilePayload = true
            }
            if let isErr = result["is_error"] as? Bool, isErr {
                toolResultIsError = true
            }
            let stdout = (result["stdout"] as? String) ?? ""
            let stderr = (result["stderr"] as? String) ?? ""
            if !stdout.isEmpty && !stderr.isEmpty {
                output = stdout + "\n" + stderr
            } else if !stdout.isEmpty {
                output = stdout
            } else if !stderr.isEmpty {
                output = stderr
            }
        }

        if output == nil {
            if let content = block["content"] as? String {
                output = content
            } else if let content = block["content"] {
                // Some Claude tool results embed large base64 blobs (e.g., screenshots).
                // Always summarize those instead of stringifying megabytes of JSON.
                output = summarizeToolResultContentIfPossible(content) ?? stringifyJSONBounded(content)
            }
        }

        let trimmed = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (output, .ok)
        }

        let lower = trimmed.lowercased()
        let isExplicitError = explicitBlockIsError || toolResultIsError

        // Read-file payloads can contain arbitrary code/comments like "exit code" and should not be
        // reclassified as runtime errors unless Claude explicitly flagged the tool_result as an error.
        if isFilePayload && !isExplicitError {
            return (output, .ok)
        }

        // If Claude didn't mark this as an error, be conservative: only classify failures when the
        // output looks like a tool failure summary (e.g. "Error: ...") or an explicit interruption.
        let looksLikeFailureSummary =
            isExplicitError ||
            lower.hasPrefix("error:") ||
            lower.hasPrefix("[error]") ||
            lower.contains("<tool_use_error>") ||
            lower.contains("request interrupted by user") ||
            lower.contains("interrupted by user") ||
            lower.contains("request cancelled by user") ||
            lower.contains("request canceled by user")
        if !looksLikeFailureSummary {
            return (output, .ok)
        }

        // 1) User rejections (do not surface as errors).
        // Keep this strict to avoid classifying generic git/server "rejected" failures as rejections.
        if lower.contains("the user doesn't want to proceed with this tool use") ||
            lower.contains("tool use was rejected") ||
            lower.contains("the tool use was rejected") {
            return (output, .rejectedOrPermissions)
        }

        // 3) Interrupted/cancelled tool runs should count as runtime-ish errors.
        if lower.contains("request interrupted by user") ||
            lower.contains("interrupted by user") ||
            lower.contains("request cancelled by user") ||
            lower.contains("request canceled by user") {
            return (output, .runtimeError)
        }

        // 4) Exit code parsing: treat non-zero as runtime-ish.
        if let code = parseExitCode(from: lower), code != 0 {
            return (output, .runtimeError)
        }

        // 5) Not-found / mismatch failures (keep visible but not counted as runtime-ish errors).
        if lower.contains("file does not exist") ||
            lower.contains("no such file or directory") ||
            lower.contains("command not found") ||
            lower.contains("string to replace not found") ||
            lower.contains("string to replace was not found") {
            return (output, .notFoundOrMismatch)
        }

        // 6) Generic error prefix: treat as runtime-ish.
        if lower.hasPrefix("error:") || lower.hasPrefix("[error]") {
            return (output, .runtimeError)
        }

        if isExplicitError {
            return (output, .otherToolFailure)
        }

        return (output, .ok)
    }

    private static func summarizeToolResultContentIfPossible(_ content: Any) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }

        var out: [String] = []
        out.reserveCapacity(min(parts.count, 8))

        for part in parts {
            let t = (part["type"] as? String)?.lowercased()
            switch t {
            case "text":
                if let s = part["text"] as? String, !s.isEmpty {
                    out.append(s)
                }
            case "image":
                // Claude: { "type":"image", "source": { "type":"base64", "media_type":"image/jpeg", "data":"..." } }
                if let src = part["source"] as? [String: Any],
                   let data = src["data"] as? String,
                   !data.isEmpty {
                    let media = (src["media_type"] as? String) ?? "image"
                    let approxBytes = approximateBase64Bytes(forLength: data.count)
                    let approxKB = Int((Double(approxBytes) / 1024.0).rounded())
                    out.append("[image omitted: \(media), approx \(approxKB) KB]")
                } else {
                    out.append("[image omitted]")
                }
            default:
                if let s = stringifyJSONBounded(part), !s.isEmpty {
                    out.append(s)
                }
            }
        }

        let joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func approximateBase64Bytes(forLength length: Int) -> Int {
        if length <= 0 { return 0 }
        return max(0, (length * 3) / 4)
    }

    private static func parseExitCode(from text: String) -> Int? {
        // IMPORTANT: Do not let patterns cross newlines. Claude read-file tool_results often include
        // line-number prefixes like "219→ ...", and "\s*" can accidentally capture the next line number.
        let patterns = [
            #"exit code[: \t]*(-?\d+)"#,
            #"exit status[: \t]*(-?\d+)"#
        ]
        for lineSub in text.split(whereSeparator: \.isNewline) {
            let line = String(lineSub)
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, options: [], range: range),
                      match.numberOfRanges >= 2,
                      let valueRange = Range(match.range(at: 1), in: line) else {
                    continue
                }
                return Int(line[valueRange])
            }
        }
        return nil
    }

    // MARK: - Lightweight Session

    /// Build a lightweight Session by scanning only head/tail slices
    private static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        let headBytesInitial = 256 * 1024
        let headBytesMax = 2 * 1024 * 1024
        let tailBytes = 256 * 1024
        func looksLikeClaudeLocalCommandTitle(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            if t.hasPrefix("Caveat:") { return true }
            if t.contains("<local-command-") { return true }
            if t.contains("<command-name>") { return true }
            if t.contains("<command-message>") { return true }
            if t.contains("<command-args>") { return true }
            return false
        }

        func build(headBytes: Int) -> Session? {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? fh.close() }

            // Read head slice
            let headData = try? fh.read(upToCount: headBytes) ?? Data()

            // Read tail slice
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? size
            var tailData: Data = Data()
            if fileSize > tailBytes {
                let offset = UInt64(fileSize - tailBytes)
                try? fh.seek(toOffset: offset)
                tailData = (try? fh.readToEnd()) ?? Data()
            }

            func lines(from data: Data, keepHead: Bool) -> [String] {
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return [] }
                let parts = s.components(separatedBy: "\n")
                if keepHead {
                    return Array(parts.prefix(300))
                } else {
                    return Array(parts.suffix(300))
                }
            }

            let headLines = lines(from: headData ?? Data(), keepHead: true)
            let tailLines = lines(from: tailData, keepHead: false)

            var model: String?
            var cwd: String?
            var tmin: Date?
            var tmax: Date?
            var sampleCount = 0
            var sampleEvents: [SessionEvent] = []

            func ingest(_ rawLine: String) {
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                // Extract metadata
                if cwd == nil {
                    if let cwdVal = obj["cwd"] as? String, isValidPath(cwdVal) {
                        cwd = cwdVal
                    } else if let projectVal = obj["project"] as? String, isValidPath(projectVal) {
                        cwd = projectVal
                    }
                }
                if model == nil, let ver = obj["version"] as? String {
                    model = "Claude Code \(ver)"
                }

                // Extract timestamp
                if let ts = extractTimestamp(from: obj) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                // Create sample event for title extraction
                let event = parseLine(obj, eventID: "light-\(sampleCount)")
                sampleEvents.append(event)
                sampleCount += 1
            }

            headLines.forEach(ingest)
            tailLines.forEach(ingest)

            // Estimate event count
            let headBytesRead = headData?.count ?? 1
            let newlineCount = headData?.filter { $0 == 0x0a }.count ?? 1
            let avgLineLen = max(256, headBytesRead / max(newlineCount, 1))
            let estEvents = max(1, min(1_000_000, fileSize / avgLineLen))

            // Extract title from sample events (temp session; ID not used downstream for UI)
            let tempSession = Session(id: hash(path: url.path),
                                      source: .claude,
                                      startTime: tmin,
                                      endTime: tmax,
                                      model: model,
                                      filePath: url.path,
                                      fileSizeBytes: size,
                                      eventCount: estEvents,
                                      events: sampleEvents,
                                      cwd: cwd,
                                      repoName: nil,
                                      lightweightTitle: nil)
            let title = tempSession.title

            // Create final lightweight session with empty events
            return Session(id: hash(path: url.path),
                           source: .claude,
                           startTime: tmin ?? mtime,
                           endTime: tmax ?? mtime,
                           model: model,
                           filePath: url.path,
                           fileSizeBytes: size,
                           eventCount: estEvents,
                           events: [],
                           cwd: cwd,
                           repoName: nil,
                           lightweightTitle: title)
        }

        guard let initial = build(headBytes: headBytesInitial) else { return nil }
        if let t = initial.lightweightTitle, looksLikeClaudeLocalCommandTitle(t) {
            if let expanded = build(headBytes: headBytesMax),
               let expTitle = expanded.lightweightTitle,
               !looksLikeClaudeLocalCommandTitle(expTitle) {
                return expanded
            }
        }
        return initial
    }

    // MARK: - Helper Methods

    private static func extractContent(from obj: [String: Any]) -> String? {
        // Try direct content/text fields
        if let str = obj["content"] as? String {
            return str
        }
        if let str = obj["text"] as? String {
            return str
        }

        // Handle array of content blocks (multimodal)
        if let contentArray = obj["content"] as? [[String: Any]] {
            var texts: [String] = []
            for block in contentArray {
                if let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        return nil
    }

    private static func extractTimestamp(from obj: [String: Any]) -> Date? {
        let tsKeys = ["timestamp", "time", "ts", "created", "created_at"]
        for key in tsKeys {
            if let value = obj[key] {
                if let ts = parseTimestampValue(value) {
                    return ts
                }
            }
        }
        return nil
    }

    private static func parseTimestampValue(_ value: Any) -> Date? {
        if let num = value as? Double {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(num))
        }
        if let num = value as? Int {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(num)))
        }
        if let str = value as? String {
            // Try ISO8601
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: str) {
                return date
            }
            // Try without fractional seconds
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: str)
        }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }  // microseconds
        if value > 1e11 { return value / 1_000 }       // milliseconds
        return value
    }

    private static func stringifyJSON(_ any: Any) -> String? {
        if let str = any as? String { return str }
        if JSONSerialization.isValidJSONObject(any) {
            if let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return String(describing: any)
    }

    private static func stringifyJSONBounded(_ any: Any) -> String? {
        if let str = any as? String { return str }
        guard JSONSerialization.isValidJSONObject(any) else { return String(describing: any) }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return String(describing: any)
        }
        if data.count > maxFallbackStringifyBytes {
            return "[OMITTED large JSON payload bytes=\(data.count)]"
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizeLargeStrings(in any: Any) -> Any {
        if let s = any as? String {
            if s.utf8.count > maxRawJSONFieldBytes {
                return "[OMITTED bytes=\(s.utf8.count)]"
            }
            return s
        }
        if let arr = any as? [Any] {
            return arr.map { sanitizeLargeStrings(in: $0) }
        }
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = sanitizeLargeStrings(in: v)
            }
            return out
        }
        return any
    }

    private static func rawJSONBase64(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: []) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private static func eventID(for url: URL, index: Int) -> String {
        let base = hash(path: url.path)
        return base + String(format: "-%04d", index)
    }

    private static func hash(path: String) -> String {
        // Stable, deterministic ID based on file path (hex SHA-256)
        let d = SHA256.hash(data: Data(path.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidPath(_ path: String) -> Bool {
        // Check if string looks like a valid file path
        // Must start with / or ~ and not contain certain invalid characters
        guard !path.isEmpty else { return false }

        // Must be an absolute path
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }

        // Should not contain code snippets or quotes
        let invalidPatterns = ["\"", "(", ")", "let ", "var ", "func ", ".range", "text.", "="]
        for pattern in invalidPatterns {
            if path.contains(pattern) {
                return false
            }
        }

        return true
    }
}
