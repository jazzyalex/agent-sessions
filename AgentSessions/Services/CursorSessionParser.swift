import Foundation
import SQLite3
import CryptoKit

/// Parser for Cursor agent transcript JSONL files.
///
/// Format: one JSON object per line with `role` at top level and `message.content[]`
/// containing Anthropic-style content blocks (text, tool_use, tool_result, thinking).
///
/// No per-message timestamps or model info in the JSONL — these are enriched from
/// the chat DB meta table by the indexer.
final class CursorSessionParser {
    private static let maxRawJSONFieldBytes = 8_192
    private static let previewLineLimit = 200
    private static let userQueryOpenTag = "<user_query>"
    private static let userQueryCloseTag = "</user_query>"

    // MARK: - Public: Lightweight Preview

    /// Parse a Cursor transcript file for lightweight indexing (metadata only, no events).
    static func parseFile(at url: URL) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime

        let reader = JSONLReader(url: url)
        var eventCount = 0
        var commandCount = 0
        var bytesRead = 0
        var firstUserText: String?
        var idx = 0
        var sawRole = false

        let (parentSessionID, subagentType) = detectSubagentInfo(from: url)

        do {
            try reader.forEachLineWhile { rawLine in
                idx += 1
                bytesRead += rawLine.utf8.count + 1 // +1 for newline
                guard idx <= previewLineLimit else { return false }
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return true
                }

                let role = (obj["role"] as? String)?.lowercased() ?? ""
                if role == "user" || role == "assistant" {
                    eventCount += 1
                    sawRole = true
                }

                // Format sniff: if the first few lines have no recognizable role,
                // this is not a Cursor transcript — bail early.
                if idx >= 3, !sawRole { return false }

                // Count tool_use blocks for lightweightCommands
                if let message = obj["message"] as? [String: Any],
                   let contentArray = message["content"] as? [[String: Any]] {
                    for block in contentArray {
                        let blockType = (block["type"] as? String)?.lowercased() ?? ""
                        if blockType == "tool_use" || blockType == "tool_call" || blockType == "tool-use" {
                            commandCount += 1
                        }
                    }

                    // Extract first user message for lightweight title
                    if firstUserText == nil, role == "user" {
                        for block in contentArray {
                            if (block["type"] as? String) == "text",
                               let text = block["text"] as? String, !text.isEmpty {
                                firstUserText = stripUserQueryTags(text)
                                break
                            }
                        }
                    }
                }

                return true
            }
        } catch {
            #if DEBUG
            print("❌ Failed to read Cursor transcript: \(error)")
            #endif
            return nil
        }

        guard eventCount > 0 else { return nil }

        // Estimate total events from bytes read during preview (not full file size)
        let estimatedEvents: Int
        if idx >= previewLineLimit, size > 0, bytesRead > 0 {
            let avgLineLen = max(128, bytesRead / max(idx, 1))
            estimatedEvents = max(eventCount, size / avgLineLen)
        } else {
            estimatedEvents = eventCount
        }

        let sessionID = extractSessionID(from: url)
        let cwd = inferCWD(from: url)
        let repoName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let title = firstUserText.map { truncateTitle($0) }

        return Session(
            id: sessionID,
            source: .cursor,
            startTime: ctime,
            endTime: mtime,
            model: nil,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: estimatedEvents,
            events: [],
            cwd: cwd,
            repoName: repoName,
            lightweightTitle: title,
            lightweightCommands: commandCount > 0 ? commandCount : nil,
            parentSessionID: parentSessionID,
            subagentType: subagentType
        )
    }

    // MARK: - Public: Full Parse

    /// Parse a Cursor transcript file with all events.
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime

        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        var idx = 0

        let (parentSessionID, subagentType) = detectSubagentInfo(from: url)

        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                let baseID = eventID(for: url, index: idx)
                let parsed = parseLineEvents(obj, baseEventID: baseID)
                events.append(contentsOf: parsed)
            }
        } catch {
            #if DEBUG
            print("❌ Failed to read Cursor transcript full: \(error)")
            #endif
            return nil
        }

        let sessionID = forcedID ?? extractSessionID(from: url)
        let cwd = inferCWD(from: url)
        let repoName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let nonMetaCount = events.filter { $0.kind != .meta }.count

        return Session(
            id: sessionID,
            source: .cursor,
            startTime: ctime,
            endTime: mtime,
            model: nil,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: cwd,
            repoName: repoName,
            lightweightTitle: nil,
            parentSessionID: parentSessionID,
            subagentType: subagentType
        )
    }

    // MARK: - Line Event Parsing

    /// Parse a single JSONL line into one or more SessionEvents.
    /// Splits `message.content[]` blocks into separate events following Claude parser pattern.
    private static func parseLineEvents(_ obj: [String: Any], baseEventID: String) -> [SessionEvent] {
        let rawJSON = rawJSONBase64(sanitizeLargeStrings(in: obj))

        // Cursor lines have role at top level
        let roleRaw = (obj["role"] as? String)?.lowercased() ?? ""
        let role: String
        switch roleRaw {
        case "user", "human": role = "user"
        case "assistant", "model": role = "assistant"
        case "system": role = "system"
        default: role = "assistant"
        }

        // Extract message.content[] blocks
        guard let message = obj["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else {
            // No content blocks — create a single event from whatever text is available
            let text = extractFallbackText(from: obj)
            let kind: SessionEventKind = role == "user" ? .user : .assistant
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: nil,
                    kind: kind,
                    role: role,
                    text: text,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        }

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
            let kind: SessionEventKind = role == "user" ? .user : .assistant
            let displayText = role == "user" ? stripUserQueryTags(joined) : joined
            out.append(
                SessionEvent(
                    id: makeID(String(format: "-p%02d", seq)),
                    timestamp: nil,
                    kind: kind,
                    role: role,
                    text: displayText,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
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
                            timestamp: nil,
                            kind: .meta,
                            role: "assistant",
                            text: "[thinking]\n" + s,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: nil,
                            parentID: nil,
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
                        timestamp: nil,
                        kind: .tool_call,
                        role: "assistant",
                        text: nil,
                        toolName: toolName,
                        toolInput: toolInput,
                        toolOutput: nil,
                        messageID: nil,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                )

            case "tool_result", "tool-result":
                flushTextIfNeeded()
                seq += 1
                let toolOutput = extractToolResultContent(from: block)
                out.append(
                    SessionEvent(
                        id: makeID(String(format: "-r%02d", seq)),
                        timestamp: nil,
                        kind: .tool_result,
                        role: "tool",
                        text: nil,
                        toolName: (block["name"] as? String) ?? (block["tool"] as? String),
                        toolInput: nil,
                        toolOutput: toolOutput,
                        messageID: nil,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                )

            default:
                // Unknown block type — treat text field as visible text if present
                if let s = block["text"] as? String {
                    textBuffer.append(s)
                }
            }
        }
        flushTextIfNeeded()

        if out.isEmpty {
            let kind: SessionEventKind = role == "user" ? .user : .assistant
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: nil,
                    kind: kind,
                    role: role,
                    text: nil,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        }

        return out
    }

    // MARK: - Subagent Detection

    /// Detect subagent from file path: .../agent-transcripts/<parentUUID>/subagents/<uuid>.jsonl
    static func detectSubagentInfo(from url: URL) -> (parentSessionID: String?, subagentType: String?) {
        let parentDir = url.deletingLastPathComponent()
        guard parentDir.lastPathComponent == "subagents" else { return (nil, nil) }

        let sessionDir = parentDir.deletingLastPathComponent()
        let parentUUID = sessionDir.lastPathComponent
        guard looksLikeUUID(parentUUID) else { return (nil, nil) }

        return (parentUUID, "subagent")
    }

    // MARK: - CWD / Project Inference

    /// Infer CWD from the project directory name in the transcript path.
    /// Path pattern: ~/.cursor/projects/<encodedProjectPath>/agent-transcripts/...
    /// The project dir name encodes the path with `-` as separator:
    /// `Users-alexm-Repository-Codex-History` → `/Users/alexm/Repository/Codex-History`
    static func inferCWD(from url: URL, fileProbe: any FileProbing = DefaultFileProbe()) -> String? {
        guard let projectName = extractProjectDirName(from: url) else { return nil }
        return inferCWD(fromProjectDirName: projectName, fileProbe: fileProbe)
    }

    /// Best-effort CWD inference for resume/copy command paths.
    /// Unlike `inferCWD`, this does not require the final path to exist.
    static func inferCWDBestEffort(from url: URL, fileProbe: any FileProbing = DefaultFileProbe()) -> String? {
        guard let projectName = extractProjectDirName(from: url) else { return nil }
        return inferCWDBestEffort(fromProjectDirName: projectName, fileProbe: fileProbe)
    }

    /// Infer CWD from a Cursor project directory name (encoded with `-` as separator).
    ///
    /// Cursor encodes absolute paths by replacing `/` with `-`:
    /// `/Users/alexm/Repository/Codex-History` → `Users-alexm-Repository-Codex-History`
    ///
    /// The challenge is that real path components can contain hyphens (e.g. `Codex-History`).
    /// We use a greedy left-to-right walk: split on `-`, then at each segment try treating it
    /// as a path separator first (check if the prefix directory exists), and if not, rejoin
    /// with the next segment using a literal hyphen.
    static func inferCWD(fromProjectDirName projectName: String,
                         fileProbe: any FileProbing = DefaultFileProbe()) -> String? {
        let bestEffort = inferCWDBestEffort(fromProjectDirName: projectName, fileProbe: fileProbe)
        guard let bestEffort else { return nil }

        if fileProbe.directoryExists(atPath: bestEffort) {
            return bestEffort
        }

        // Fallback: try the naive all-slash replacement (for edge cases where no
        // intermediate directories exist, e.g. temp paths)
        let naive = "/" + projectName.replacingOccurrences(of: "-", with: "/")
        if fileProbe.directoryExists(atPath: naive) {
            return naive
        }

        return nil
    }

    /// Best-effort decoder for Cursor project-dir encoding.
    /// Prefers segment boundaries that are known directories when possible,
    /// but always returns a decoded absolute path even when the final
    /// directory currently does not exist.
    static func inferCWDBestEffort(fromProjectDirName projectName: String,
                                   fileProbe: any FileProbing = DefaultFileProbe()) -> String? {
        let segments = projectName.components(separatedBy: "-")
        guard !segments.isEmpty else { return nil }

        // Greedy walk: track the resolved prefix (committed path with slashes)
        // and the current component being built (may accumulate literal hyphens).
        //
        // Example: segments = ["Users", "alexm", "Repository", "Codex", "History"]
        //   Step 1: "/Users" is a dir → resolvedPrefix="/Users", component="alexm"
        //   Step 2: "/Users/alexm" is a dir → resolvedPrefix="/Users/alexm", component="Repository"
        //   Step 3: "/Users/alexm/Repository" is a dir → resolvedPrefix="/Users/alexm/Repository", component="Codex"
        //   Step 4: "/Users/alexm/Repository/Codex" is NOT a dir → component="Codex-History"
        //   Final: "/Users/alexm/Repository/Codex-History"
        var resolvedPrefix = ""
        var currentComponent = segments[0]
        var i = 1

        while i < segments.count {
            let candidateDir = resolvedPrefix + "/" + currentComponent
            if fileProbe.directoryExists(atPath: candidateDir) {
                // currentComponent is a real directory — commit it as a path level
                resolvedPrefix = candidateDir
                currentComponent = segments[i]
            } else {
                // Not a directory — this hyphen is literal within the component name
                currentComponent = currentComponent + "-" + segments[i]
            }
            i += 1
        }

        return resolvedPrefix + "/" + currentComponent
    }

    /// Extract the project directory name from a transcript file URL.
    /// Pattern: .../projects/<projectDirName>/agent-transcripts/...
    private static func extractProjectDirName(from url: URL) -> String? {
        let components = url.pathComponents
        for (i, component) in components.enumerated() {
            if component == "agent-transcripts", i > 0 {
                let projectDir = components[i - 1]
                // Skip special names
                if projectDir == "projects" || projectDir == "empty-window" { return nil }
                return projectDir
            }
        }
        return nil
    }

    // MARK: - Session ID

    /// Extract session ID from the directory/file UUID structure.
    /// Pattern: .../agent-transcripts/<uuid>/<uuid>.jsonl
    /// For subagents: .../agent-transcripts/<parentUUID>/subagents/<uuid>.jsonl
    private static func extractSessionID(from url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        if looksLikeUUID(filename) {
            return filename
        }
        // Fallback: hash the file path for a stable ID
        return hash(path: url.path)
    }

    // MARK: - Helpers

    private static func stripUserQueryTags(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: userQueryOpenTag, with: "")
        result = result.replacingOccurrences(of: userQueryCloseTag, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncateTitle(_ text: String, maxLength: Int = 120) -> String {
        let oneLine = text.components(separatedBy: .newlines).first ?? text
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        // UUID format: 8-4-4-4-12 hex chars
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func extractFallbackText(from obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            if let content = message["content"] as? String { return content }
            if let text = message["text"] as? String { return text }
        }
        if let text = obj["text"] as? String { return text }
        if let content = obj["content"] as? String { return content }
        return nil
    }

    private static func extractToolResultContent(from block: [String: Any]) -> String? {
        if let content = block["content"] as? String { return content }
        if let output = block["output"] as? String { return output }
        if let content = block["content"] {
            return stringifyJSON(content)
        }
        return nil
    }

    private static func stringifyJSON(_ any: Any) -> String? {
        if let str = any as? String { return str }
        if JSONSerialization.isValidJSONObject(any) {
            if let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                if str.utf8.count > maxRawJSONFieldBytes {
                    return "[OMITTED large JSON bytes=\(str.utf8.count)]"
                }
                return str
            }
        }
        return String(describing: any)
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
        let d = SHA256.hash(data: Data(path.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
}

struct CursorACPParseResult {
    let session: Session
    let referencedTranscriptPaths: Set<String>
}

/// Read-only decoder for Cursor ACP persisted sessions. Cursor stores a small root
/// record in SQLite `meta` and protobuf conversation nodes in content-addressed
/// `blobs`. This deliberately decodes only user and assistant text; tool arguments,
/// results, attachments, and the root's blob-encryption key never enter the index.
enum CursorACPStoreReader {
    private static let idPrefix = "cursor-acp:"
    private static let transcriptFieldNumber = 18

    static func isACPStore(_ url: URL) -> Bool {
        url.lastPathComponent == "store.db"
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "acp-sessions"
    }

    static func parse(at url: URL) -> Session? {
        parseResult(at: url)?.session
    }

    /// Reads only the first persisted user text from a Cursor chat store.
    /// This is used for a bounded display-title fallback for ACP child stores;
    /// it does not expose tool arguments, tool results, or attachments.
    static func firstUserText(at url: URL) -> String? {
        guard let store = Store(url: url),
              let rootJSON = store.rootJSON,
              let rootID = rootJSON["latestRootBlobId"] as? String,
              let rootIDData = Data(hexString: rootID), rootIDData.count == 32,
              let root = store.blob(id: rootID) else { return nil }

        let rootMessage = ProtoMessage(root)
        for turnIDData in rootMessage.dataFields(number: 8) {
            guard turnIDData.count == 32,
                  let turn = store.blob(id: turnIDData.hexString) else { continue }
            let turnMessage = ProtoMessage(turn)
            guard let agentTurn = turnMessage.firstData(number: 1),
                  let userBlobID = ProtoMessage(agentTurn).firstData(number: 1),
                  userBlobID.count == 32,
                  let user = store.blob(id: userBlobID.hexString),
                  let text = ProtoMessage(user).firstString(number: 1),
                  !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    static func parseResult(at url: URL) -> CursorACPParseResult? {
        guard isACPStore(url),
              let rawID = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent)?.uuidString.lowercased(),
              let sidecar = readSidecar(url.deletingLastPathComponent().appendingPathComponent("meta.json")),
              sidecar["schemaVersion"] as? Int == 1,
              let store = Store(url: url),
              let rootJSON = store.rootJSON,
              let rootID = rootJSON["latestRootBlobId"] as? String,
              let rootIDData = Data(hexString: rootID), rootIDData.count == 32,
              let root = store.blob(id: rootID) else { return nil }

        let rootMessage = ProtoMessage(root)
        let rootTranscriptPath = transcriptPath(
            from: rootMessage.dataFields(number: transcriptFieldNumber),
            expectedRootID: rawID
        )
        let turns = rootMessage.dataFields(number: 8)
        var events: [SessionEvent] = []
        for (turnIndex, turnIDData) in turns.enumerated() {
            guard turnIDData.count == 32,
                  let turn = store.blob(id: turnIDData.hexString) else { return nil }
            let turnMessage = ProtoMessage(turn)
            guard let agentTurn = turnMessage.firstData(number: 1) else { continue }
            let agent = ProtoMessage(agentTurn)

            if let userBlobID = agent.firstData(number: 1), userBlobID.count == 32,
               let user = store.blob(id: userBlobID.hexString),
               let text = ProtoMessage(user).firstString(number: 1), !text.isEmpty {
                events.append(event(id: rawID, turn: turnIndex, kind: .user, text: text))
            }
            for (stepIndex, stepBlobID) in agent.dataFields(number: 2).enumerated() {
                guard stepBlobID.count == 32,
                      let step = store.blob(id: stepBlobID.hexString),
                      let assistant = ProtoMessage(step).firstData(number: 1),
                      let text = ProtoMessage(assistant).firstString(number: 1), !text.isEmpty else { continue }
                events.append(event(id: rawID, turn: turnIndex * 10_000 + stepIndex, kind: .assistant, text: text))
            }
        }

        let created = date(rootJSON["createdAt"])
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let session = Session(id: idPrefix + rawID,
                              source: .cursor,
                              startTime: created,
                              endTime: modified ?? created,
                              model: nil,
                              filePath: url.path,
                              fileSizeBytes: size,
                              eventCount: events.count,
                              events: events,
                              cwd: sidecar["cwd"] as? String,
                              repoName: (sidecar["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
                              lightweightTitle: rootJSON["name"] as? String,
                              customTitle: rootJSON["name"] as? String,
                              originator: "cursor-agent",
                              originSource: "acp-persisted",
                              surface: .acp)
        return CursorACPParseResult(session: session, referencedTranscriptPaths: rootTranscriptPath)
    }

    private static func transcriptPath(from values: [Data], expectedRootID: String) -> Set<String> {
        var paths = Set<String>()
        for value in values {
            guard let rawPath = String(data: value, encoding: .utf8),
                  rawPath.hasPrefix("/") else { continue }
            let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let components = normalized.split(separator: "/").map(String.init)
            guard let marker = components.lastIndex(of: "agent-transcripts") else { continue }
            let suffix = Array(components.dropFirst(marker + 1))
            guard suffix.count == 2 || suffix.count == 3 else { continue }

            if suffix.count == 2 {
                guard let directoryID = UUID(uuidString: suffix[0])?.uuidString.lowercased(),
                      let filenameID = UUID(uuidString: String(suffix[1].dropLast(".jsonl".count)))?.uuidString.lowercased(),
                      suffix[1].hasSuffix(".jsonl"),
                      directoryID == filenameID else { continue }
                // The root transcript identifies the ACP session itself, not a child.
                guard directoryID == expectedRootID else { continue }
                continue
            } else {
                guard suffix[1] == "subagents",
                      let directoryID = UUID(uuidString: suffix[0])?.uuidString.lowercased(),
                      let filenameID = UUID(uuidString: String(suffix[2].dropLast(".jsonl".count)))?.uuidString.lowercased(),
                      suffix[2].hasSuffix(".jsonl"),
                      directoryID != filenameID else { continue }
            }
            // The parent directory and child filename have been validated as UUIDs.
            // Keep the normalized path as the resolver's exact, lexical lookup key.
            paths.insert(normalized)
        }
        return paths
    }

    private static func event(id: String, turn: Int, kind: SessionEventKind, text: String) -> SessionEvent {
        SessionEvent(id: "\(id):\(kind.rawValue):\(turn)", timestamp: nil, kind: kind,
                     role: kind == .user ? "user" : "assistant", text: text, toolName: nil,
                     toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil,
                     isDelta: false, rawJSON: "")
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds) }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func readSidecar(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private final class Store {
        private var db: OpaquePointer?

        init?(url: URL) {
            if let normal = Self.openDatabase(at: url.path, immutable: false) {
                db = normal
                sqlite3_busy_timeout(normal, 250)
                if schemaIsSupported, rootJSON != nil {
                    return
                }
                sqlite3_close(normal)
                db = nil
            }

            guard let immutable = Self.openDatabase(at: url.path, immutable: true) else { return nil }
            db = immutable
            sqlite3_busy_timeout(immutable, 250)
            guard schemaIsSupported, rootJSON != nil else {
                sqlite3_close(immutable)
                db = nil
                return nil
            }
        }

        deinit { sqlite3_close(db) }

        private static func openDatabase(at path: String, immutable: Bool) -> OpaquePointer? {
            var database: OpaquePointer?
            let target = immutable
                ? URL(fileURLWithPath: path).absoluteString + "?immutable=1"
                : path
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
                | (immutable ? SQLITE_OPEN_URI : 0)
            guard sqlite3_open_v2(target, &database, flags, nil) == SQLITE_OK else {
                sqlite3_close(database)
                return nil
            }
            return database
        }

        var rootJSON: [String: Any]? {
            guard let hex = scalar("SELECT value FROM meta WHERE key = '0'"),
                  let data = Data(hexString: hex),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return object as? [String: Any]
        }

        func blob(id: String) -> Data? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM blobs WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }

        private var schemaIsSupported: Bool {
            guard let count = scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('blobs', 'meta')"),
                  count == "2" else { return false }
            return columnNames(for: "blobs") == ["id", "data"]
                && columnNames(for: "meta") == ["key", "value"]
        }

        private func columnNames(for table: String) -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 1) else { return [] }
                names.append(String(cString: text))
            }
            return names
        }

        private func scalar(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }
}

private struct ProtoMessage {
    private let fields: [(number: Int, data: Data)]

    init(_ data: Data) {
        let bytes = Array(data)
        var offset = 0
        var parsed: [(Int, Data)] = []
        while offset < bytes.count, let key = Self.readVarint(bytes, &offset) {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: _ = Self.readVarint(bytes, &offset)
            case 1: offset += 8
            case 2:
                guard let length = Self.readVarint(bytes, &offset), length <= UInt64(bytes.count - offset) else { offset = bytes.count; break }
                let end = offset + Int(length)
                parsed.append((field, Data(bytes[offset..<end])))
                offset = end
            case 5: offset += 4
            default: offset = bytes.count
            }
        }
        fields = parsed
    }

    func dataFields(number: Int) -> [Data] { fields.filter { $0.number == number }.map(\.data) }
    func firstData(number: Int) -> Data? { dataFields(number: number).first }
    func firstString(number: Int) -> String? { firstData(number: number).flatMap { String(data: $0, encoding: .utf8) } }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]; offset += 1
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard clean.count.isMultiple(of: 2) else { return nil }
        var result = Data(); result.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<end], radix: 16) else { return nil }
            result.append(byte); index = end
        }
        self = result
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
