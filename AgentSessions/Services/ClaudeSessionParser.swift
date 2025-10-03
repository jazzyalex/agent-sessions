import Foundation

/// Parser for Claude Code session format
final class ClaudeSessionParser {

    /// Parse a Claude Code session file
    static func parseFile(at url: URL) -> Session? {
        // Check file size for lightweight optimization
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        // Fast path: heavy file → metadata-first, avoid full scan now
        if size >= 10_000_000 { // 10 MB threshold
            print("🔵 HEAVY CLAUDE FILE: \(url.lastPathComponent) size=\(size) bytes (~\(size/1_000_000)MB)")
            if let light = lightweightSession(from: url, size: size, mtime: mtime) {
                print("✅ LIGHTWEIGHT CLAUDE: \(url.lastPathComponent) estEvents=\(light.eventCount) messageCount=\(light.messageCount)")
                return light
            }
            print("❌ LIGHTWEIGHT FAILED - falling through to full parse")
        }

        return parseFileFull(at: url)
    }

    /// Full parse of Claude Code session file
    static func parseFileFull(at url: URL) -> Session? {
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
                let event = parseLine(obj, eventID: eventID(for: url, index: idx))
                events.append(event)
            }
        } catch {
            print("❌ Failed to read Claude session: \(error)")
            return nil
        }

        // Fallback session ID from filename
        if sessionID == nil {
            sessionID = url.deletingPathExtension().lastPathComponent
        }

        let id = hash(path: url.path)  // Always use file path for unique ID
        return Session(
            id: id,
            source: .claude,
            startTime: tmin,
            endTime: tmax,
            model: model,
            filePath: url.path,
            eventCount: events.count,
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )
    }

    // MARK: - Event Parsing

    private static func parseLine(_ obj: [String: Any], eventID: String) -> SessionEvent {
        let eventType = obj["type"] as? String
        let timestamp = extractTimestamp(from: obj)

        var role: String?
        var text: String?
        var toolName: String?
        var toolInput: String?
        var toolOutput: String?

        // Determine role and extract content based on type
        switch eventType {
        case "user":
            role = "user"
            // Extract from nested message.content
            if let message = obj["message"] as? [String: Any] {
                text = extractContent(from: message)
            }
            // Fallback to direct content
            if text == nil {
                text = extractContent(from: obj)
            }

        case "assistant", "response":
            role = "assistant"
            if let message = obj["message"] as? [String: Any] {
                text = extractContent(from: message)
            }
            if text == nil {
                text = extractContent(from: obj)
            }

        case "system":
            role = "system"
            text = obj["content"] as? String

        case "tool_use", "tool_call":
            role = "assistant"
            toolName = obj["name"] as? String ?? obj["tool"] as? String
            if let input = obj["input"] {
                toolInput = stringifyJSON(input)
            }

        case "tool_result":
            role = "tool"
            if let output = obj["output"] {
                toolOutput = stringifyJSON(output)
            }

        default:
            // Meta events: summary, file-history-snapshot, etc.
            role = "meta"
            if let summary = obj["summary"] as? String {
                text = summary
            }
        }

        // Determine if this is a meta event based on type, not isMeta flag
        // Claude Code marks many user messages as isMeta, so we need better logic
        let isMetaEvent = eventType == "summary" ||
                          eventType == "file-history-snapshot" ||
                          eventType == "meta"

        let kind = SessionEventKind.from(role: role, type: eventType)

        return SessionEvent(
            id: eventID,
            timestamp: timestamp,
            kind: isMetaEvent ? .meta : kind,
            role: role,
            text: text,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            messageID: obj["uuid"] as? String,
            parentID: obj["parentUuid"] as? String,
            isDelta: false,
            rawJSON: (try? JSONSerialization.data(withJSONObject: obj, options: []).base64EncodedString()) ?? ""
        )
    }

    // MARK: - Lightweight Session

    /// Build a lightweight Session by scanning only head/tail slices
    private static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        let headBytes = 256 * 1024
        let tailBytes = 256 * 1024
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

        var sessionID: String?
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
            if sessionID == nil, let sid = obj["sessionId"] as? String {
                sessionID = sid
            }
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

        // Fallback session ID from filename
        if sessionID == nil {
            sessionID = url.deletingPathExtension().lastPathComponent
        }

        // Extract title from sample events
        let tempSession = Session(id: hash(path: url.path),
                                   source: .claude,
                                   startTime: tmin,
                                   endTime: tmax,
                                   model: model,
                                   filePath: url.path,
                                   eventCount: estEvents,
                                   events: sampleEvents,
                                   cwd: cwd,
                                   repoName: nil,
                                   lightweightTitle: nil)
        let title = tempSession.title

        // Create final lightweight session with empty events
        let id = hash(path: url.path)
        return Session(id: id,
                      source: .claude,
                      startTime: tmin ?? mtime,
                      endTime: tmax ?? mtime,
                      model: model,
                      filePath: url.path,
                      eventCount: estEvents,
                      events: [],
                      cwd: cwd,
                      repoName: nil,
                      lightweightTitle: title)
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

    private static func eventID(for url: URL, index: Int) -> String {
        let base = hash(path: url.path)
        return base + String(format: "-%04d", index)
    }

    private static func hash(path: String) -> String {
        // Simple hash for consistency
        return String(path.hashValue)
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
