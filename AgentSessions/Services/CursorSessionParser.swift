import Foundation
import CryptoKit
import SQLite3
import Darwin

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

/// Read-only decoder for Cursor ACP persisted sessions. Cursor stores a small root
/// record in SQLite `meta` and protobuf conversation nodes in content-addressed
/// `blobs`. Only user and assistant text is admitted to the session index.
enum CursorACPStoreReader {
    private static let idPrefix = "cursor-acp:"
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum ArchiveValidationResult {
        case valid
        case invalid
        case unavailable
    }

    enum LiveParseResult {
        case valid(session: Session, logicalStat: SessionFileStat)
        case invalid
        case unavailable
    }

    enum ACPStoreAdmissionResult {
        case valid
        case invalid
        case unavailable
    }

    enum TrustedSnapshotValidationResult {
        case valid(Session)
        case invalid
        case unavailable
    }

    private struct ArchiveParseSnapshot {
        let rootURL: URL
        let storeURL: URL
        let logicalStat: SessionFileStat
    }

    private enum ArchiveParseResult {
        case snapshot(ArchiveParseSnapshot)
        case invalid
        case unavailable
    }

    private enum ArchiveManifestResult {
        case valid(SessionArchiveManifest)
        case invalid
        case unavailable
    }

    private enum ArchiveFileReadResult {
        case data(Data)
        case missing
        case invalid
        case unavailable
    }

    /// A bound archive keeps the root, session directory, and data directory
    /// open for the entire validation/copy operation. Reopening any of these
    /// pathnames after a symlink preflight would reintroduce a parent-directory
    /// ABA race.
    private struct ArchiveBinding {
        let rootDescriptor: Int32
        let sessionDescriptor: Int32
        let dataDescriptor: Int32
    }

    private enum ArchiveDirectoryOpenResult {
        case opened(Int32)
        case invalid
        case unavailable
    }

    private enum ArchiveBindingOpenResult {
        case opened(ArchiveBinding)
        case invalid
        case unavailable
    }

    private enum ArchiveFileDescriptorResult {
        case opened(Int32)
        case invalid
        case unavailable
    }

    private enum ArchiveDirectoryEntriesResult {
        case entries([String])
        case invalid
        case unavailable
    }

    private enum StoreQueryResult<Value> {
        case value(Value)
        case invalid
        case unavailable
    }

    private enum StoreOpenResult {
        case opened(Store)
        case invalid
        case unavailable
    }

    private enum SnapshotCopyFailure: Error, Equatable {
        case invalid
        case unavailable
    }

    private struct LiveFileSnapshot: Equatable {
        let name: String
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanoseconds: Int64
    }

    private struct LiveCompanionSet: Equatable {
        let metadata: LiveFileSnapshot?
        let database: LiveFileSnapshot?
        let wal: LiveFileSnapshot?
    }

#if DEBUG
    /// Test-only authority injection for archive round-trip fixtures. Production
    /// parsing always derives this root from Application Support.
    static var archiveRootProvider: (() -> URL?)?
    /// Test-only seam between archive admission and the verified snapshot copy.
    /// Production parsing never mutates or replaces archive files here.
    static var archiveParseHook: (() -> Void)?
    /// Test-only seam after the live session directory is descriptor-bound.
    /// Production parsing never mutates or replaces live files here.
    static var liveParseHook: (() -> Void)?
    /// Test-only seam after all live companions are copied and before the
    /// descriptor-bound companion set is re-snapshotted.
    static var liveParsePostCopyHook: (() -> Void)?
    /// Test-only seam immediately before the first live companion copy. This
    /// lets tests exercise an ABA replacement that restores the original
    /// descriptor identity before the post-copy check.
    static var liveParseBeforeMetadataCopyHook: (() -> Void)?
    /// Test-only seam after the stable live snapshot has been copied and
    /// before semantic parsing. The returned session and authority stat must
    /// still describe that same copied epoch if the live source changes here.
    static var liveParseBeforeSemanticParseHook: (() -> Void)?
    /// Test-only seam for an operational archive-validation outage. The
    /// recovery path must preserve every copy when validation is unavailable.
    static var archiveValidationUnavailableHook: (() -> Bool)?
    /// Test-only seam for an operational failure after the archive snapshot
    /// has already been copied into disposable validation space.
    static var archiveParseOperationalFailureHook: (() -> Bool)?
    /// Test-only seam for an operational failure after discovery has confirmed
    /// that the live store path exists. The discovery contract must preserve
    /// the prior projection instead of treating that failure as absence.
    static var liveStoreAdmissionUnavailableHook: (() -> Bool)?
#endif

    /// Recognizes both a live `acp-sessions/<UUID>/store.db` and a controlled
    /// archived `Archives/cursor/<id>/data/store.db`. Live paths are canonicalized
    /// and reject every symlink in the storage boundary before parsing.
    static func isACPStore(_ url: URL) -> Bool {
        guard url.lastPathComponent == "store.db" else { return false }
        let sessionDir = url.deletingLastPathComponent()
        let parent = sessionDir.deletingLastPathComponent()
        if UUID(uuidString: sessionDir.lastPathComponent) != nil,
           parent.lastPathComponent == "acp-sessions" {
            if case .valid = liveACPStoreAdmission(at: url) {
                return true
            }
            return false
        }
        let archiveSession = parent
        let archivedUUID = String(archiveSession.lastPathComponent.dropFirst(idPrefix.count))
        guard sessionDir.lastPathComponent == "data",
              archiveSession.lastPathComponent.hasPrefix(idPrefix),
              UUID(uuidString: archivedUUID) != nil,
              archiveSession.deletingLastPathComponent().lastPathComponent == "cursor",
              let archiveRoot = archiveRoot() else { return false }
        return isSafeArchiveStore(url, root: archiveRoot)
    }

    /// Performs typed structural admission for a live ACP store. Discovery
    /// needs to distinguish a deterministic rejection from an operational
    /// failure so an unreadable candidate cannot become authoritative absence.
    static func liveACPStoreAdmission(at url: URL) -> ACPStoreAdmissionResult {
        guard url.lastPathComponent == "store.db" else { return .invalid }
        let sessionDir = url.deletingLastPathComponent()
        let root = sessionDir.deletingLastPathComponent()
        guard UUID(uuidString: sessionDir.lastPathComponent) != nil,
              root.lastPathComponent == "acp-sessions" else { return .invalid }

#if DEBUG
        if liveStoreAdmissionUnavailableHook?() == true {
            return .unavailable
        }
#endif
        return liveStoreAdmission(url, root: root)
    }

    /// Structural admission for a candidate that discovery already opened
    /// relative to its bound `acp-sessions` descriptor. The descriptors keep a
    /// root replacement from redirecting the sidecar checks to a different
    /// pathname between enumeration and admission.
    static func liveACPStoreAdmission(sessionDirectoryDescriptor: Int32,
                                      storeDescriptor: Int32) -> ACPStoreAdmissionResult {
        var storeStat = stat()
        guard Darwin.fstat(storeDescriptor, &storeStat) == 0 else { return .unavailable }
        guard (storeStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }

#if DEBUG
        if liveStoreAdmissionUnavailableHook?() == true {
            return .unavailable
        }
#endif

        switch descriptorFileAdmission(named: "meta.json",
                                       in: sessionDirectoryDescriptor,
                                       required: true) {
        case .valid:
            break
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        for name in ["store.db-wal", "store.db-shm"] {
            switch descriptorFileAdmission(named: name,
                                           in: sessionDirectoryDescriptor,
                                           required: false) {
            case .valid:
                continue
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }
        return .valid
    }

    static func parse(at url: URL) -> Session? {
        guard let identity = liveOrArchiveSessionID(for: url) else { return nil }

        if identity.isArchived {
            guard case .snapshot(let snapshot) = archiveParseSnapshot(at: url) else { return nil }
            defer { try? FileManager.default.removeItem(at: snapshot.rootURL) }
            let expectedUUID = String(identity.value.dropFirst(idPrefix.count))
            switch parseSnapshot(storeURL: snapshot.storeURL,
                                 outputURL: url,
                                 expectedUUID: expectedUUID,
                                 sessionID: identity.value,
                                 logicalStat: snapshot.logicalStat) {
            case .valid(let session):
                return session
            case .invalid, .unavailable:
                return nil
            }
        }
        return parseWithAuthority(at: url)?.session
    }

    /// Parses a stable live snapshot and returns the logical authority stat
    /// captured by that same descriptor-bound copy. Callers that use the stat
    /// as an authority token must not re-stat the live pathname after parsing.
    static func parseWithAuthority(at url: URL) -> (session: Session, logicalStat: SessionFileStat)? {
        switch parseWithAuthorityResult(at: url) {
        case .valid(let session, let logicalStat):
            return (session, logicalStat)
        case .invalid, .unavailable:
            return nil
        }
    }

    /// Typed variant for indexers that must distinguish deterministic invalid
    /// persisted data from a transient read or SQLite outage.
    static func parseWithAuthorityResult(at url: URL) -> LiveParseResult {
        guard let identity = liveOrArchiveSessionID(for: url), !identity.isArchived else {
            return .unavailable
        }
        switch liveACPStoreAdmission(at: url) {
        case .valid:
            break
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard let snapshot = liveParseSnapshot(at: url) else {
            // Admission can succeed and the descriptor-bound snapshot can
            // still fail because a companion was deterministically replaced
            // by a symlink, non-regular file, or other structurally invalid
            // entry after admission. Re-admit only to classify that terminal
            // failure; never turn a persistent structural rejection into an
            // operational outage (or vice versa).
            switch liveACPStoreAdmission(at: url) {
            case .invalid:
                return .invalid
            case .valid, .unavailable:
                return .unavailable
            }
        }
        defer { try? FileManager.default.removeItem(at: snapshot.rootURL) }

#if DEBUG
        liveParseBeforeSemanticParseHook?()
#endif
        let sessionID = idPrefix + identity.value
        switch parseSnapshot(storeURL: snapshot.storeURL,
                             outputURL: url,
                             expectedUUID: identity.value,
                             sessionID: sessionID,
                             logicalStat: snapshot.logicalStat) {
        case .valid(let session):
            return .valid(session: session, logicalStat: snapshot.logicalStat)
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    /// Parses a private, already-copied ACP snapshot. The path is deliberately
    /// not admitted by `isACPStore`; callers use this only after binding and
    /// copying the source under their own descriptor/manifest contract. The
    /// full semantic SQLite and protobuf validation still runs here.
    static func parseTrustedSnapshot(at storeURL: URL, expectedSessionID: String) -> Session? {
        switch validateTrustedSnapshot(at: storeURL, expectedSessionID: expectedSessionID) {
        case .valid(let session):
            return session
        case .invalid, .unavailable:
            return nil
        }
    }

    /// Typed validation for a private, already-copied ACP snapshot. The
    /// archive manager uses this to preserve the distinction between corrupt
    /// staged bytes and an operational validation outage.
    static func validateTrustedSnapshot(at storeURL: URL,
                                        expectedSessionID: String) -> TrustedSnapshotValidationResult {
        guard expectedSessionID.hasPrefix(idPrefix) else { return .invalid }
        let expectedUUID = String(expectedSessionID.dropFirst(idPrefix.count))
        guard UUID(uuidString: expectedUUID) != nil else { return .invalid }
        switch parseSnapshot(storeURL: storeURL,
                             outputURL: storeURL,
                             expectedUUID: expectedUUID,
                             sessionID: expectedSessionID,
                             logicalStat: nil) {
        case .valid(let session):
            return .valid(session)
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    static func validateArchivedSnapshot(at url: URL,
                                         expectedSessionID: String) -> ArchiveValidationResult {
#if DEBUG
        if archiveValidationUnavailableHook?() == true {
            return .unavailable
        }
#endif
        guard let identity = liveOrArchiveSessionID(for: url),
              identity.isArchived,
              identity.value == expectedSessionID else {
            return .invalid
        }
        let snapshot: ArchiveParseSnapshot
        switch archiveParseSnapshot(at: url) {
        case .snapshot(let value):
            snapshot = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        defer { try? FileManager.default.removeItem(at: snapshot.rootURL) }

#if DEBUG
        if archiveParseOperationalFailureHook?() == true {
            return .unavailable
        }
#endif

        let expectedUUID = String(expectedSessionID.dropFirst(idPrefix.count))
        switch parseSnapshot(storeURL: snapshot.storeURL,
                             outputURL: url,
                             expectedUUID: expectedUUID,
                             sessionID: expectedSessionID,
                             logicalStat: snapshot.logicalStat) {
        case .valid:
            return .valid
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private enum SnapshotParseResult {
        case valid(Session)
        case invalid
        case unavailable
    }

    private static func parseSnapshot(storeURL: URL,
                                      outputURL: URL,
                                      expectedUUID: String,
                                      sessionID: String,
                                      logicalStat parsedLogicalStat: SessionFileStat?) -> SnapshotParseResult {
        let sidecar: [String: Any]
        switch readSidecar(storeURL.deletingLastPathComponent().appendingPathComponent("meta.json")) {
        case .value(let value):
            sidecar = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard schemaVersion(in: sidecar) == 1 else { return .invalid }

        let store: Store
        switch Store.open(url: storeURL) {
        case .opened(let value):
            store = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        func storeFailure() -> SnapshotParseResult {
            store.hadOperationalFailure ? .unavailable : .invalid
        }
        guard case .value(let rootJSON) = store.rootJSONResult else {
            return storeFailure()
        }
        guard let agentID = rootJSON["agentId"] as? String,
              matchesUUID(agentID, expected: expectedUUID) else {
            return .invalid
        }
        guard let rootID = rootJSON["latestRootBlobId"] as? String,
              let rootIDData = Data(hexString: rootID), rootIDData.count == 32 else {
            return .invalid
        }
        guard case .value(let root) = store.blob(id: rootIDData.hexString),
              let rootMessage = ProtoMessage(root) else {
            return storeFailure()
        }

        var events: [SessionEvent] = []
        for (turnIndex, turnIDData) in rootMessage.dataFields(number: 8).enumerated() {
            guard turnIDData.count == 32,
                  case .value(let turnData) = store.blob(id: turnIDData.hexString),
                  let turnMessage = ProtoMessage(turnData) else {
                // A referenced turn is a supported graph edge. If the node is
                // missing or malformed, reject the whole session rather than
                // publishing a plausible but incomplete transcript.
                return storeFailure()
            }

            // ConversationTurn is a oneof: field 1 is an agent turn and field
            // 2 is a shell turn. Shell turns are valid persisted graph nodes,
            // but are intentionally omitted from the current text projection.
            // Reject absent or repeated variants instead of treating a valid
            // shell turn as a malformed agent turn.
            let agentTurnFields = turnMessage.dataFields(number: 1)
            let shellTurnFields = turnMessage.dataFields(number: 2)
            guard agentTurnFields.count + shellTurnFields.count == 1 else {
                return .invalid
            }
            if let shellTurnData = shellTurnFields.first {
                guard ProtoMessage(shellTurnData) != nil else { return .invalid }
                continue
            }

            guard let agentTurnData = agentTurnFields.first,
                  let agentTurn = ProtoMessage(agentTurnData),
                  let userID = agentTurn.firstData(number: 1),
                  userID.count == 32,
                  case .value(let userData) = store.blob(id: userID.hexString),
                  let userMessage = ProtoMessage(userData),
                  let userText = userMessage.firstString(number: 1),
                  !userText.isEmpty else {
                return storeFailure()
            }
            events.append(event(id: sessionID, turn: turnIndex, kind: .user, text: userText))

            for (stepIndex, stepID) in agentTurn.dataFields(number: 2).enumerated() {
                guard stepID.count == 32,
                      case .value(let stepData) = store.blob(id: stepID.hexString),
                      let stepMessage = ProtoMessage(stepData) else { return storeFailure() }

                // The step payload is a oneof in Cursor's ACP graph. Field 1
                // references assistant text; fields 2 and 3 are tool-call and
                // thinking steps. Those latter variants are valid graph nodes,
                // but are intentionally omitted from the current text-only
                // event projection. An absent or ambiguous oneof is malformed.
                let variants = [1, 2, 3].filter { !stepMessage.dataFields(number: $0).isEmpty }
                guard variants.count == 1 else { return .invalid }
                switch variants[0] {
                case 1:
                    guard let assistantID = stepMessage.firstData(number: 1),
                          assistantID.count == 32,
                          case .value(let assistantData) = store.blob(id: assistantID.hexString),
                          let assistantMessage = ProtoMessage(assistantData),
                          let assistantText = assistantMessage.firstString(number: 1),
                          !assistantText.isEmpty else { return storeFailure() }
                    events.append(event(id: sessionID,
                                        turn: turnIndex * 10_000 + stepIndex,
                                        kind: .assistant,
                                        text: assistantText))
                case 2, 3:
                    continue
                default:
                    return .invalid
                }
            }
        }

        let created = date(rootJSON["createdAt"])
        let logicalStat = parsedLogicalStat ?? logicalFileStat(at: outputURL)
        let modified = logicalStat.map { Date(timeIntervalSince1970: TimeInterval($0.mtime)) }
        let size = logicalStat?.size
        let cwd = sidecar["cwd"] as? String
        let name = rootJSON["name"] as? String
        return .valid(Session(id: sessionID,
                              source: .cursor,
                              startTime: created,
                              endTime: modified ?? created,
                              model: nil,
                              filePath: outputURL.path,
                              fileSizeBytes: Int(size ?? 0),
                              eventCount: events.count,
                              events: events,
                              cwd: cwd,
                              repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                              lightweightTitle: name,
                              customTitle: name,
                              originator: "cursor-agent",
                              originSource: "acp-persisted",
                              surface: .acp))
    }

    /// Combines the SQLite store and its sidecar/WAL companions so focused reload
    /// and search ingest notice writes that do not change `store.db`'s own stat.
    static func logicalFileStat(at url: URL) -> SessionFileStat? {
        guard isACPStore(url) else { return nil }
        let files = [url,
                     url.deletingLastPathComponent().appendingPathComponent("meta.json"),
                     URL(fileURLWithPath: url.path + "-wal")]
        var total: Int64 = 0
        var latest = Date.distantPast
        var found = false
        var components: [String] = []
        for (index, file) in files.enumerated() {
            var fileStat = stat()
            guard Darwin.lstat(file.path, &fileStat) == 0 else {
                guard errno == ENOENT else { return nil }
                components.append("\(index)=missing")
                continue
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return nil }
            found = true
            let seconds = Int64(fileStat.st_mtimespec.tv_sec)
            let nanoseconds = Int64(fileStat.st_mtimespec.tv_nsec)
            total += Int64(fileStat.st_size)
            latest = max(latest, Date(timeIntervalSince1970: TimeInterval(seconds)))
            components.append("\(index)=\(fileStat.st_dev):\(fileStat.st_ino):\(fileStat.st_size):\(seconds):\(nanoseconds)")
        }
        guard found else { return nil }
        return SessionFileStat(mtime: Int64(latest.timeIntervalSince1970),
                               size: total,
                               fingerprint: components.joined(separator: "|"))
    }

    private static func matchesUUID(_ value: String, expected: String) -> Bool {
        guard let actual = UUID(uuidString: value),
              let expected = UUID(uuidString: expected) else { return false }
        return actual == expected
    }

    private static func event(id: String, turn: Int, kind: SessionEventKind, text: String) -> SessionEvent {
        SessionEvent(id: "\(id):\(kind.rawValue):\(turn)",
                     timestamp: nil,
                     kind: kind,
                     role: kind == .user ? "user" : "assistant",
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: nil,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: "")
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static func readSidecar(_ url: URL) -> StoreQueryResult<[String: Any]> {
        switch readRegularFileNoFollow(url) {
        case .data(let data):
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return .invalid }
            return .value(dictionary)
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private static func readRegularFileNoFollow(_ url: URL) -> ArchiveFileReadResult {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : (errno == ELOOP ? .invalid : .unavailable)
        }
        defer { Darwin.close(descriptor) }

        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            guard let data = try handle.readToEnd() else { return .unavailable }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    /// Bind the live ACP session directory once, then copy its companions by
    /// descriptor before SQLite or JSON parsing begins. Reopening the sidecar
    /// and database by pathname after an admission check would let a replaced
    /// session directory supply metadata from a different source.
    private static func liveParseSnapshot(at url: URL) -> ArchiveParseSnapshot? {
        let sessionDirectory = url.deletingLastPathComponent()
        guard let sessionDescriptor = openDirectoryDescriptor(at: sessionDirectory) else { return nil }
        defer { Darwin.close(sessionDescriptor) }

#if DEBUG
        liveParseHook?()
#endif

        for _ in 0..<4 {
            let tempPath = FileManager.default.temporaryDirectory.path
            let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
            let snapshotRoot = URL(fileURLWithPath: canonicalTempPath, isDirectory: true)
                .appendingPathComponent("AgentSessions-ACP-Live-\(UUID().uuidString)", isDirectory: true)
            let snapshotDataRoot = snapshotRoot.appendingPathComponent("data", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: snapshotDataRoot,
                                                         withIntermediateDirectories: true)
                let before = try liveCompanionSet(from: sessionDescriptor)
                guard before.metadata != nil, before.database != nil else { throw snapshotError() }

                let metadata: LiveFileSnapshot?
#if DEBUG
                liveParseBeforeMetadataCopyHook?()
#endif
                metadata = try copyLiveFile(named: "meta.json",
                                                 from: sessionDescriptor,
                                                 to: snapshotDataRoot.appendingPathComponent("meta.json"))
                let database = try copyLiveFile(named: "store.db",
                                                from: sessionDescriptor,
                                                to: snapshotDataRoot.appendingPathComponent("store.db"))
                guard metadata != nil, database != nil else { throw snapshotError() }
                let wal = try copyLiveFile(named: "store.db-wal",
                                           from: sessionDescriptor,
                                           to: snapshotDataRoot.appendingPathComponent("store.db-wal"))

#if DEBUG
                liveParsePostCopyHook?()
#endif

                // The individual copy checks prevent a torn read of one file;
                // this whole-set comparison additionally prevents a SQLite
                // database from being paired with a WAL from another epoch.
                let after = try liveCompanionSet(from: sessionDescriptor)
                guard before.metadata == metadata,
                      before.database == database,
                      before.wal == wal,
                      before == after,
                      after.metadata != nil,
                      after.database != nil else {
                    throw snapshotError()
                }

                let files = [after.metadata, after.database, after.wal].compactMap { $0 }
                let totalSize = files.reduce(Int64(0)) { $0 + $1.size }
                let latestMtime = files.map {
                    Date(timeIntervalSince1970: TimeInterval($0.mtimeSeconds)
                         + TimeInterval($0.mtimeNanoseconds) / 1_000_000_000)
                }.max() ?? Date.distantPast
                let fingerprints = [after.metadata, after.database, after.wal].enumerated().map { index, file in
                    guard let file else { return "\(index)=missing" }
                    return "\(index)=\(file.device):\(file.inode):\(file.size):\(file.mtimeSeconds):\(file.mtimeNanoseconds)"
                }

                return ArchiveParseSnapshot(
                    rootURL: snapshotRoot,
                    storeURL: snapshotDataRoot.appendingPathComponent("store.db", isDirectory: false),
                    logicalStat: SessionFileStat(mtime: Int64(latestMtime.timeIntervalSince1970),
                                                  size: totalSize,
                                                  fingerprint: fingerprints.joined(separator: "|"))
                )
            } catch {
                try? FileManager.default.removeItem(at: snapshotRoot)
            }
        }
        return nil
    }

    private static func copyLiveFile(named name: String,
                                     from sessionDescriptor: Int32,
                                     to destination: URL) throws -> LiveFileSnapshot? {
        let sourceDescriptor = name.withCString {
            Darwin.openat(sessionDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw snapshotError()
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStat) == 0,
              (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw snapshotError()
        }

        let destinationDescriptor = Darwin.open(destination.path,
                                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                                                 0o600)
        guard destinationDescriptor >= 0 else { throw snapshotError() }
        var removeDestination = true
        defer {
            Darwin.close(destinationDescriptor)
            if removeDestination { try? FileManager.default.removeItem(at: destination) }
        }

        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: false)
        var copiedSize: Int64 = 0
        while let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            copiedSize += Int64(chunk.count)
            try destinationHandle.write(contentsOf: chunk)
        }
        guard copiedSize == Int64(sourceStat.st_size),
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw snapshotError()
        }

        var finalSourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &finalSourceStat) == 0,
              finalSourceStat.st_size == sourceStat.st_size,
              finalSourceStat.st_mtimespec.tv_sec == sourceStat.st_mtimespec.tv_sec,
              finalSourceStat.st_mtimespec.tv_nsec == sourceStat.st_mtimespec.tv_nsec else {
            throw snapshotError()
        }
        removeDestination = false
        return LiveFileSnapshot(name: name,
                                device: sourceStat.st_dev,
                                inode: sourceStat.st_ino,
                                size: Int64(sourceStat.st_size),
                                mtimeSeconds: Int64(sourceStat.st_mtimespec.tv_sec),
                                mtimeNanoseconds: Int64(sourceStat.st_mtimespec.tv_nsec))
    }

    private static func liveCompanionSet(from sessionDescriptor: Int32) throws -> LiveCompanionSet {
        LiveCompanionSet(
            metadata: try snapshotLiveFile(named: "meta.json", from: sessionDescriptor),
            database: try snapshotLiveFile(named: "store.db", from: sessionDescriptor),
            wal: try snapshotLiveFile(named: "store.db-wal", from: sessionDescriptor)
        )
    }

    private static func snapshotLiveFile(named name: String,
                                         from sessionDescriptor: Int32) throws -> LiveFileSnapshot? {
        let sourceDescriptor = name.withCString {
            Darwin.openat(sessionDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw snapshotError()
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStat) == 0,
              (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw snapshotError()
        }
        return LiveFileSnapshot(name: name,
                                device: sourceStat.st_dev,
                                inode: sourceStat.st_ino,
                                size: Int64(sourceStat.st_size),
                                mtimeSeconds: Int64(sourceStat.st_mtimespec.tv_sec),
                                mtimeNanoseconds: Int64(sourceStat.st_mtimespec.tv_nsec))
    }

    private static func openDirectoryDescriptor(at url: URL) -> Int32? {
        guard case .opened(let descriptor) = openDirectoryDescriptorResult(at: url) else {
            return nil
        }
        return descriptor
    }

    private static func openDirectoryDescriptorResult(at url: URL) -> ArchiveDirectoryOpenResult {
        let path = CursorBackendDetector.normalizedSystemAliasPath(url.path)
        guard path.hasPrefix("/") else { return .invalid }
        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { return .unavailable }
        var currentDescriptor = rootDescriptor
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(component)
            let nextDescriptor = name.withCString {
                Darwin.openat(currentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else {
                let failure = errno
                Darwin.close(currentDescriptor)
                return archiveDirectoryOpenResult(for: failure)
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return .opened(currentDescriptor)
    }

    private static func archiveDirectoryOpenResult(for failure: Int32) -> ArchiveDirectoryOpenResult {
        switch failure {
        case ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG:
            return .invalid
        default:
            return .unavailable
        }
    }

    private static func archiveFileDescriptorResult(for failure: Int32) -> ArchiveFileDescriptorResult {
        switch failure {
        case ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG:
            return .invalid
        default:
            return .unavailable
        }
    }

    private static func closeArchiveBinding(_ binding: ArchiveBinding) {
        Darwin.close(binding.dataDescriptor)
        Darwin.close(binding.sessionDescriptor)
        Darwin.close(binding.rootDescriptor)
    }

    private static func openArchiveBinding(at url: URL, root: URL) -> ArchiveBindingOpenResult {
        let dataRoot = url.deletingLastPathComponent()
        let archiveSession = dataRoot.deletingLastPathComponent()
        let expectedRoot = root.standardizedFileURL
        guard archiveSession.deletingLastPathComponent().standardizedFileURL == expectedRoot,
              dataRoot.lastPathComponent == "data",
              archiveSession.lastPathComponent.hasPrefix("cursor-acp:"),
              UUID(uuidString: String(archiveSession.lastPathComponent.dropFirst("cursor-acp:".count))) != nil,
              url.lastPathComponent == "store.db" else {
            return .invalid
        }

        let rootDescriptor: Int32
        switch openDirectoryDescriptorResult(at: root) {
        case .opened(let descriptor):
            rootDescriptor = descriptor
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        let sessionDescriptor: Int32
        switch openArchiveDirectoryChild(rootDescriptor, name: archiveSession.lastPathComponent) {
        case .opened(let descriptor):
            sessionDescriptor = descriptor
        case .invalid:
            Darwin.close(rootDescriptor)
            return .invalid
        case .unavailable:
            Darwin.close(rootDescriptor)
            return .unavailable
        }

        switch openArchiveDirectoryChild(sessionDescriptor, name: "data") {
        case .opened(let dataDescriptor):
            return .opened(ArchiveBinding(rootDescriptor: rootDescriptor,
                                          sessionDescriptor: sessionDescriptor,
                                          dataDescriptor: dataDescriptor))
        case .invalid:
            Darwin.close(sessionDescriptor)
            Darwin.close(rootDescriptor)
            return .invalid
        case .unavailable:
            Darwin.close(sessionDescriptor)
            Darwin.close(rootDescriptor)
            return .unavailable
        }
    }

    private static func isSafeArchiveComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }

    private static func openArchiveDirectoryChild(_ parentDescriptor: Int32,
                                                  name: String) -> ArchiveDirectoryOpenResult {
        guard isSafeArchiveComponent(name) else { return .invalid }
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return archiveDirectoryOpenResult(for: errno) }
        return .opened(descriptor)
    }

    private static func openArchiveRelativeDirectory(_ relativePath: String,
                                                     under rootDescriptor: Int32) -> ArchiveDirectoryOpenResult {
        var currentDescriptor = Darwin.dup(rootDescriptor)
        guard currentDescriptor >= 0 else { return .unavailable }

        if relativePath.isEmpty {
            return .opened(currentDescriptor)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(where: { !isSafeArchiveComponent($0) }) else {
            Darwin.close(currentDescriptor)
            return .invalid
        }

        for component in components {
            switch openArchiveDirectoryChild(currentDescriptor, name: component) {
            case .opened(let nextDescriptor):
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            case .invalid:
                Darwin.close(currentDescriptor)
                return .invalid
            case .unavailable:
                Darwin.close(currentDescriptor)
                return .unavailable
            }
        }
        return .opened(currentDescriptor)
    }

    private static func openArchiveFileDescriptor(_ relativePath: String,
                                                  under rootDescriptor: Int32) -> ArchiveFileDescriptorResult {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let fileName = components.last,
              !components.contains(where: { !isSafeArchiveComponent($0) }) else {
            return .invalid
        }

        let parentPath = components.dropLast().joined(separator: "/")
        let parentDescriptor: Int32
        switch openArchiveRelativeDirectory(parentPath, under: rootDescriptor) {
        case .opened(let descriptor):
            parentDescriptor = descriptor
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = fileName.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return archiveFileDescriptorResult(for: errno) }
        return .opened(descriptor)
    }

    private static func readArchiveRegularFile(in directoryDescriptor: Int32,
                                               name: String) -> ArchiveFileReadResult {
        guard isSafeArchiveComponent(name) else { return .invalid }
        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            switch archiveFileDescriptorResult(for: errno) {
            case .invalid:
                return .missing
            case .unavailable:
                return .unavailable
            case .opened:
                return .unavailable
            }
        }
        defer { Darwin.close(descriptor) }

        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            guard let data = try handle.readToEnd() else { return .unavailable }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    private static func archiveDataEntryNames(in dataDescriptor: Int32) -> ArchiveDirectoryEntriesResult {
        let duplicateDescriptor = ".".withCString {
            Darwin.openat(dataDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard duplicateDescriptor >= 0 else {
            switch archiveDirectoryOpenResult(for: errno) {
            case .invalid:
                return .invalid
            case .unavailable, .opened:
                return .unavailable
            }
        }
        guard let directoryStream = Darwin.fdopendir(duplicateDescriptor) else {
            Darwin.close(duplicateDescriptor)
            return .unavailable
        }
        defer { Darwin.closedir(directoryStream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directoryStream) else {
                guard errno == 0 else { return .unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var fileStat = stat()
            let statResult = name.withCString {
                Darwin.fstatat(dataDescriptor, $0, &fileStat, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                return .unavailable
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
            names.append(name)
        }
        return .entries(names)
    }

    /// Bind the archive directories once, validate through those descriptors,
    /// and copy the manifest-approved files through the same descriptors. The
    /// parser never reopens a canonical archive pathname after admission, so a
    /// parent-directory replacement cannot redirect validation or copying.
    /// SQLite may create or rebuild `store.db-shm` in the disposable directory
    /// without changing the canonical archive.
    private static func archiveParseSnapshot(at url: URL) -> ArchiveParseResult {
        guard let archiveRoot = archiveRoot() else { return .unavailable }
        let binding: ArchiveBinding
        switch openArchiveBinding(at: url, root: archiveRoot) {
        case .opened(let value):
            binding = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        defer { closeArchiveBinding(binding) }

        let manifest: SessionArchiveManifest
        switch validatedArchiveManifest(at: url, binding: binding) {
        case .valid(let value):
            manifest = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

#if DEBUG
        archiveParseHook?()
#endif

        let tempPath = FileManager.default.temporaryDirectory.path
        let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
        let snapshotRoot = URL(fileURLWithPath: canonicalTempPath, isDirectory: true)
            .appendingPathComponent("AgentSessions-ACP-\(UUID().uuidString)", isDirectory: true)
        let snapshotDataRoot = snapshotRoot.appendingPathComponent("data", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: snapshotDataRoot,
                                                     withIntermediateDirectories: true)

            var totalSize: Int64 = 0
            var latestMtime = Date.distantPast
            for entry in manifest.entries {
                guard ["store.db", "meta.json", "store.db-wal"].contains(entry.relativePath) else {
                    throw SnapshotCopyFailure.invalid
                }
                let destination = snapshotDataRoot.appendingPathComponent(entry.relativePath, isDirectory: false)
                try copyVerifiedArchiveFile(fromDirectory: binding.dataDescriptor,
                                            relativePath: entry.relativePath,
                                            to: destination,
                                            expected: entry)
                totalSize += entry.sizeBytes
                latestMtime = max(latestMtime, Date(timeIntervalSince1970: entry.mtimeSeconds))
            }

            guard manifest.entries.contains(where: { $0.relativePath == "store.db" }),
                  manifest.entries.contains(where: { $0.relativePath == "meta.json" }) else {
                throw SnapshotCopyFailure.invalid
            }
            let storeURL = snapshotDataRoot.appendingPathComponent("store.db", isDirectory: false)
            return .snapshot(ArchiveParseSnapshot(
                rootURL: snapshotRoot,
                storeURL: storeURL,
                logicalStat: SessionFileStat(mtime: Int64(latestMtime.timeIntervalSince1970),
                                              size: totalSize)
            ))
        } catch let failure as SnapshotCopyFailure {
            try? FileManager.default.removeItem(at: snapshotRoot)
            return failure == .invalid ? .invalid : .unavailable
        } catch {
            try? FileManager.default.removeItem(at: snapshotRoot)
            return .unavailable
        }
    }

    private static func copyVerifiedArchiveFile(fromDirectory dataDescriptor: Int32,
                                                relativePath: String,
                                                to destination: URL,
                                                expected: SessionArchiveManifest.Entry) throws {
        let sourceDescriptor: Int32
        switch openArchiveFileDescriptor(relativePath, under: dataDescriptor) {
        case .opened(let descriptor):
            sourceDescriptor = descriptor
        case .invalid:
            throw SnapshotCopyFailure.invalid
        case .unavailable:
            throw SnapshotCopyFailure.unavailable
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStat) == 0 else {
            throw SnapshotCopyFailure.unavailable
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG,
              sourceStat.st_size == off_t(expected.sizeBytes) else {
            throw SnapshotCopyFailure.invalid
        }

        let destinationDescriptor = Darwin.open(destination.path,
                                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                                                 0o600)
        guard destinationDescriptor >= 0 else { throw SnapshotCopyFailure.unavailable }
        var removeDestination = true
        defer {
            Darwin.close(destinationDescriptor)
            if removeDestination { try? FileManager.default.removeItem(at: destination) }
        }

        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: false)
        var hasher = SHA256()
        var copiedSize: Int64 = 0
        do {
            while let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                copiedSize += Int64(chunk.count)
                hasher.update(data: chunk)
                try destinationHandle.write(contentsOf: chunk)
            }
        } catch {
            throw SnapshotCopyFailure.unavailable
        }

        var finalSourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &finalSourceStat) == 0 else {
            throw SnapshotCopyFailure.unavailable
        }
        guard copiedSize == expected.sizeBytes,
              finalSourceStat.st_size == sourceStat.st_size,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw SnapshotCopyFailure.invalid
        }
        removeDestination = false
    }

    private static func snapshotError() -> NSError {
        NSError(domain: "CursorACPStoreReader", code: 1)
    }

    private static func schemaVersion(in sidecar: [String: Any]) -> Int? {
        if let value = sidecar["schemaVersion"] as? Int { return value }
        return (sidecar["schemaVersion"] as? NSNumber)?.intValue
    }

    private static func liveOrArchiveSessionID(for url: URL) -> (value: String, isArchived: Bool)? {
        let sessionDir = url.deletingLastPathComponent()
        if UUID(uuidString: sessionDir.lastPathComponent) != nil {
            return (sessionDir.lastPathComponent.lowercased(), false)
        }
        guard sessionDir.lastPathComponent == "data" else { return nil }
        let archiveID = sessionDir.deletingLastPathComponent().lastPathComponent
        guard archiveID.hasPrefix(idPrefix),
              UUID(uuidString: String(archiveID.dropFirst(idPrefix.count))) != nil else { return nil }
        return (archiveID, true)
    }

    private static func archiveRoot() -> URL? {
#if DEBUG
        if let provider = archiveRootProvider, let root = provider() { return root }
#endif
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("cursor", isDirectory: true)
    }

    private enum PathEntryResult {
        case regular
        case directory
        case symbolicLink
        case other
        case missing
        case unavailable
    }

    private enum SafeRootPathResult {
        case valid(String)
        case invalid
        case unavailable
    }

    private static func isSafeArchiveStore(_ url: URL, root: URL) -> Bool {
        if case .valid = validatedArchiveManifest(at: url, root: root) {
            return true
        }
        return false
    }

    private static func liveStoreAdmission(_ url: URL,
                                           root: URL) -> ACPStoreAdmissionResult {
        let rootPath: String
        switch safeStoreRootPath(url, root: root) {
        case .valid(let value):
            rootPath = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        switch symlinkSafety(of: url, rootPath: rootPath) {
        case .safe:
            break
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        let liveRoot = url.deletingLastPathComponent()
        let sidecar = liveRoot.appendingPathComponent("meta.json")
        switch requiredRegularFile(sidecar, rootPath: rootPath) {
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        case .valid:
            break
        }

        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: url.path + suffix)
            switch optionalRegularFile(companion, rootPath: rootPath) {
            case .valid:
                continue
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }
        return .valid
    }

    private static func descriptorFileAdmission(named name: String,
                                                in sessionDirectoryDescriptor: Int32,
                                                required: Bool) -> ACPStoreAdmissionResult {
        let descriptor = name.withCString {
            Darwin.openat(sessionDirectoryDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                return required ? .invalid : .valid
            case ELOOP, ENOTDIR:
                return .invalid
            default:
                return .unavailable
            }
        }
        defer { Darwin.close(descriptor) }

        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
        return .valid
    }

    private static func safeStoreRootPath(_ url: URL,
                                          root: URL) -> SafeRootPathResult {
        switch pathEntry(at: url) {
        case .regular:
            break
        case .missing:
            return .unavailable
        case .unavailable:
            return .unavailable
        case .directory, .symbolicLink, .other:
            return .invalid
        }
        switch pathEntry(at: root) {
        case .directory:
            break
        case .missing, .unavailable:
            return .unavailable
        case .regular, .symbolicLink, .other:
            return .invalid
        }
        let rootPath = root.standardizedFileURL.path
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalStore = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard rootPath == canonicalRoot,
              canonicalStore == url.standardizedFileURL.path,
              canonicalStore == rootPath || canonicalStore.hasPrefix(rootPath + "/") else { return .invalid }
        return .valid(rootPath)
    }

    private enum SymlinkSafetyResult {
        case safe
        case invalid
        case unavailable
    }

    private static func pathEntry(at url: URL) -> PathEntryResult {
        var fileStat = stat()
        guard Darwin.lstat(url.path, &fileStat) == 0 else {
            return errno == ENOENT ? .missing : .unavailable
        }
        switch fileStat.st_mode & S_IFMT {
        case S_IFREG:
            return .regular
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    private static func requiredRegularFile(_ url: URL,
                                            rootPath: String) -> ACPStoreAdmissionResult {
        switch pathEntry(at: url) {
        case .regular:
            switch symlinkSafety(of: url, rootPath: rootPath) {
            case .safe:
                return .valid
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        case .missing, .directory, .symbolicLink, .other:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private static func optionalRegularFile(_ url: URL,
                                           rootPath: String) -> ACPStoreAdmissionResult {
        switch pathEntry(at: url) {
        case .missing:
            return .valid
        case .regular:
            switch symlinkSafety(of: url, rootPath: rootPath) {
            case .safe:
                return .valid
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        case .directory, .symbolicLink, .other:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private static func symlinkSafety(of url: URL,
                                      rootPath: String) -> SymlinkSafetyResult {
        var current = url
        while current.path.hasPrefix(rootPath + "/") || current.path == rootPath {
            switch pathEntry(at: current) {
            case .symbolicLink:
                return .invalid
            case .missing:
                return .unavailable
            case .unavailable:
                return .unavailable
            case .regular, .directory, .other:
                break
            }
            if current.path == rootPath { break }
            current = current.deletingLastPathComponent()
        }
        return .safe
    }

    private static func validatedArchiveManifest(at url: URL, root: URL) -> ArchiveManifestResult {
        switch openArchiveBinding(at: url, root: root) {
        case .opened(let binding):
            defer { closeArchiveBinding(binding) }
            return validatedArchiveManifest(at: url, binding: binding)
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private static func validatedArchiveManifest(at url: URL,
                                                 binding: ArchiveBinding) -> ArchiveManifestResult {
        let archiveSession = url.deletingLastPathComponent().deletingLastPathComponent()
        let allowedEntries = Set(["store.db", "meta.json", "store.db-wal"])
        let metadataData: Data
        switch readArchiveRegularFile(in: binding.sessionDescriptor, name: "meta.json") {
        case .data(let data):
            metadataData = data
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard let archiveInfo = try? JSONDecoder().decode(SessionArchiveInfo.self, from: metadataData),
              archiveInfo.source == .cursor,
              archiveInfo.sessionID == archiveSession.lastPathComponent,
              archiveInfo.isCursorACPArchive else { return .invalid }

        let manifestData: Data
        switch readArchiveRegularFile(in: binding.sessionDescriptor, name: "manifest.json") {
        case .data(let data):
            manifestData = data
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard let savedManifest = try? JSONDecoder().decode(SessionArchiveManifest.self,
                                                              from: manifestData),
              savedManifest.entries.contains(where: { $0.relativePath == "store.db" }),
              savedManifest.entries.contains(where: { $0.relativePath == "meta.json" }),
              savedManifest.entries.count == Set(savedManifest.entries.map(\.relativePath)).count,
              Set(savedManifest.entries.map(\.relativePath)).isSubset(of: allowedEntries) else {
            return .invalid
        }

        switch readArchiveRegularFile(in: binding.dataDescriptor, name: "meta.json") {
        case .data:
            break
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        let dataFiles: [String]
        switch archiveDataEntryNames(in: binding.dataDescriptor) {
        case .entries(let names):
            dataFiles = names
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard dataFiles.count == savedManifest.entries.count,
              Set(dataFiles) == Set(savedManifest.entries.map(\.relativePath)) else {
            return .invalid
        }

        for entry in savedManifest.entries {
            switch validateArchiveManifestEntry(entry, dataDescriptor: binding.dataDescriptor) {
            case .valid:
                continue
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }
        return .valid(savedManifest)
    }

    private static func validateArchiveManifestEntry(_ entry: SessionArchiveManifest.Entry,
                                                     dataDescriptor: Int32) -> ArchiveValidationResult {
        let relativePath = entry.relativePath
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              entry.sizeBytes >= 0,
              let expectedHash = entry.sha256,
              !expectedHash.isEmpty else { return .invalid }

        let descriptor: Int32
        switch openArchiveFileDescriptor(relativePath, under: dataDescriptor) {
        case .opened(let value):
            descriptor = value
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        defer { Darwin.close(descriptor) }

        switch archiveFileFingerprint(descriptor) {
        case .value(let size, let sha256):
            return size == entry.sizeBytes && sha256 == expectedHash
                ? .valid
                : .invalid
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }

    private enum ArchiveFingerprintResult {
        case value(size: Int64, sha256: String)
        case invalid
        case unavailable
    }

    private static func archiveFileFingerprint(_ descriptor: Int32) -> ArchiveFingerprintResult {
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return .unavailable
        }
        return .value(size: Int64(fileStat.st_size),
                      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func hasNoSymlinkComponents(_ url: URL, rootPath: String) -> Bool {
        let fm = FileManager.default
        var current = url
        while current.path.hasPrefix(rootPath + "/") || current.path == rootPath {
            guard let attrs = try? fm.attributesOfItem(atPath: current.path),
                  let type = attrs[.type] as? FileAttributeType,
                  type != .typeSymbolicLink else { return false }
            if current.path == rootPath { break }
            current = current.deletingLastPathComponent()
        }
        return true
    }

    private final class Store {
        private var db: OpaquePointer?
        private var readTransactionStarted = false
        private(set) var hadOperationalFailure = false

        private init(db: OpaquePointer) {
            self.db = db
        }

        static func open(url: URL) -> StoreOpenResult {
            // parseSnapshot is called only after the source companions have
            // been copied into a private disposable directory. Keep the
            // database read-only; on macOS SQLite needs to create/rebuild a
            // missing WAL -shm sidecar in that disposable directory.
            var db: OpaquePointer?
            let openResult = sqlite3_open_v2(url.path,
                                             &db,
                                             SQLITE_OPEN_READONLY,
                                             nil)
            guard openResult == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                switch openResult {
                case SQLITE_CORRUPT, SQLITE_NOTADB:
                    return .invalid
                default:
                    return .unavailable
                }
            }
            let store = Store(db: db)
            sqlite3_busy_timeout(db, 250)
            switch store.schemaStatus() {
            case .valid:
                break
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
            guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
                store.hadOperationalFailure = true
                return .unavailable
            }
            store.readTransactionStarted = true
            return .opened(store)
        }

        deinit {
            if readTransactionStarted {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
            sqlite3_close(db)
        }

        var rootJSONResult: StoreQueryResult<[String: Any]> {
            switch scalar("SELECT value FROM meta WHERE key = '0'") {
            case .value(let hex):
                guard let data = Data(hexString: hex),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? [String: Any] else { return .invalid }
                return .value(dictionary)
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }

        func blob(id: String) -> StoreQueryResult<Data> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data FROM blobs WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
                if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                    return .invalid
                }
                hadOperationalFailure = true
                return .unavailable
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(statement, 1, id, -1, CursorACPStoreReader.sqliteTransient) == SQLITE_OK else {
                hadOperationalFailure = true
                return .unavailable
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_BLOB else { return .invalid }
                let count = Int(sqlite3_column_bytes(statement, 0))
                let data: Data
                if count == 0 {
                    data = Data()
                } else if let bytes = sqlite3_column_blob(statement, 0) {
                    data = Data(bytes: bytes, count: count)
                } else {
                    return .invalid
                }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return digest == id.lowercased() ? .value(data) : .invalid
            case SQLITE_DONE:
                return .invalid
            default:
                if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                    return .invalid
                }
                hadOperationalFailure = true
                return .unavailable
            }
        }

        private func schemaStatus() -> ArchiveValidationResult {
            switch scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('blobs', 'meta')") {
            case .value(let count) where count == "2":
                break
            case .unavailable:
                return .unavailable
            case .value, .invalid:
                return .invalid
            }
            switch columnNames(for: "blobs") {
            case .unavailable:
                return .unavailable
            case .invalid:
                return .invalid
            case .value(let names) where names == ["id", "data"]:
                break
            case .value:
                return .invalid
            }
            switch columnNames(for: "meta") {
            case .unavailable:
                return .unavailable
            case .invalid:
                return .invalid
            case .value(let names):
                return names == ["key", "value"] ? .valid : .invalid
            }
        }

        private func columnNames(for table: String) -> StoreQueryResult<[String]> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
                if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                    return .invalid
                }
                hadOperationalFailure = true
                return .unavailable
            }
            defer { sqlite3_finalize(statement) }
            var names: [String] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let text = sqlite3_column_text(statement, 1) else { return .invalid }
                    names.append(String(cString: text))
                case SQLITE_DONE:
                    return names.isEmpty ? .invalid : .value(names)
                default:
                    if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                        return .invalid
                    }
                    hadOperationalFailure = true
                    return .unavailable
                }
            }
        }

        private func scalar(_ sql: String) -> StoreQueryResult<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                    return .invalid
                }
                hadOperationalFailure = true
                return .unavailable
            }
            defer { sqlite3_finalize(statement) }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { return .invalid }
                return .value(String(cString: text))
            case SQLITE_DONE:
                return .invalid
            default:
                if isDeterministicallyInvalidSQLiteError(sqlite3_extended_errcode(db)) {
                    return .invalid
                }
                hadOperationalFailure = true
                return .unavailable
            }
        }

        private func isDeterministicallyInvalidSQLiteError(_ code: Int32) -> Bool {
            code == SQLITE_CORRUPT || code == SQLITE_NOTADB || code == SQLITE_SCHEMA
        }
    }
}

/// Minimal protobuf wire decoder. It is intentionally failable: malformed or
/// truncated fields cannot be mistaken for an empty optional field.
private struct ProtoMessage {
    private let fields: [(number: Int, data: Data)]

    init?(_ data: Data) {
        let bytes = Array(data)
        var offset = 0
        var parsed: [(number: Int, data: Data)] = []
        while offset < bytes.count {
            guard let key = Self.readVarint(bytes, &offset), key >> 3 > 0 else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard Self.readVarint(bytes, &offset) != nil else { return nil }
            case 1:
                guard bytes.count - offset >= 8 else { return nil }
                offset += 8
            case 2:
                guard let length = Self.readVarint(bytes, &offset),
                      length <= UInt64(bytes.count - offset),
                      length <= UInt64(Int.max) else { return nil }
                let end = offset + Int(length)
                parsed.append((field, Data(bytes[offset..<end])))
                offset = end
            case 5:
                guard bytes.count - offset >= 4 else { return nil }
                offset += 4
            default:
                return nil
            }
        }
        fields = parsed
    }

    func dataFields(number: Int) -> [Data] { fields.filter { $0.number == number }.map(\.data) }
    func firstData(number: Int) -> Data? { dataFields(number: number).first }
    func firstString(number: Int) -> String? { firstData(number: number).flatMap { String(data: $0, encoding: .utf8) } }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            if index == 9, byte > 1 { return nil }
            value |= UInt64(byte & 0x7f) << UInt64(index * 7)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard clean.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        self = result
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
