import Foundation

/// Parser for OpenCode sessions stored under ~/.local/share/opencode/storage
final class OpenCodeSessionParser {
    private enum StorageSchemaVersion: Int {
        case legacy = 1
        case v2 = 2
    }

    private struct SessionJSON: Decodable {
        struct Time: Decodable {
            let created: Int64?
            let updated: Int64?
        }
        struct Summary: Decodable {
            let additions: Int?
            let deletions: Int?
            let files: Int?
        }
        let id: String
        let version: String?
        let projectID: String?
        let directory: String?
        let parentID: String?
        let title: String?
        let time: Time?
        let summary: Summary?
    }

    private struct MessageJSON: Decodable {
        struct Time: Decodable {
            let created: Int64?
        }
        struct Summary: Decodable {
            let title: String?
            let body: String?
            let diffs: [String]?
        }
        struct Model: Decodable {
            let providerID: String?
            let modelID: String?
        }
        struct Tools: Decodable {
            let todowrite: Bool?
            let todoread: Bool?
            let task: Bool?
        }
        let id: String
        let sessionID: String
        let role: String?
        let time: Time?
        let summary: Summary?
        let agent: String?
        let model: Model?
        // Some OpenCode message records store model fields at the top level.
        let providerID: String?
        let modelID: String?
        let tools: Tools?
    }

    private protocol OpenCodeStorageLayout {
        var schemaVersion: StorageSchemaVersion { get }
        func partFiles(forMessageID messageID: String, storageRoot: URL, legacyIndex: inout [String: [URL]]?) -> [URL]
    }

    private struct V2Layout: OpenCodeStorageLayout {
        let schemaVersion: StorageSchemaVersion = .v2

        func partFiles(forMessageID messageID: String, storageRoot: URL, legacyIndex: inout [String: [URL]]?) -> [URL] {
            let partDir = storageRoot
                .appendingPathComponent("part", isDirectory: true)
                .appendingPathComponent(messageID, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: partDir.path, isDirectory: &isDir), isDir.boolValue else {
                return []
            }
            guard let files = try? FileManager.default.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return []
            }
            return files
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private struct LegacyLayout: OpenCodeStorageLayout {
        let schemaVersion: StorageSchemaVersion = .legacy

        func partFiles(forMessageID messageID: String, storageRoot: URL, legacyIndex: inout [String: [URL]]?) -> [URL] {
            // Prefer v2-style folder when present even if migration is missing.
            let v2Files = V2Layout().partFiles(forMessageID: messageID, storageRoot: storageRoot, legacyIndex: &legacyIndex)
            if !v2Files.isEmpty { return v2Files }

            if legacyIndex == nil {
                legacyIndex = buildLegacyPartIndex(storageRoot: storageRoot)
            }
            return (legacyIndex?[messageID] ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        private func buildLegacyPartIndex(storageRoot: URL) -> [String: [URL]] {
            let partRoot = storageRoot.appendingPathComponent("part", isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: partRoot.path, isDirectory: &isDir), isDir.boolValue else {
                return [:]
            }

            guard let enumerator = FileManager.default.enumerator(at: partRoot,
                                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                                 options: [.skipsHiddenFiles]) else {
                return [:]
            }

            var index: [String: [URL]] = [:]
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "json",
                      url.lastPathComponent.hasPrefix("prt_") else {
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messageID = obj["messageID"] as? String else {
                    continue
                }
                index[messageID, default: []].append(url)
            }
            return index
        }
    }

    /// Lightweight parse of an OpenCode session file into a Session with no events.
    /// Uses message metadata to estimate message count, preferred model, and command count.
    static func parseFile(at url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let obj = try? decoder.decode(SessionJSON.self, from: data) else { return nil }

        let createdDate = obj.time?.created.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        let updatedDate = obj.time?.updated.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }

        // Count messages + commands cheaply by scanning the corresponding message directory, if present.
        let (eventCount, modelID, commandCount) = lightweightMessageMetadata(for: obj.id, sessionURL: url)

        return Session(
            id: obj.id,
            source: .opencode,
            startTime: createdDate,
            endTime: updatedDate,
            model: modelID,
            filePath: url.path,
            fileSizeBytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
            eventCount: eventCount,
            events: [],
            cwd: obj.directory,
            repoName: nil,
            lightweightTitle: obj.title,
            lightweightCommands: commandCount > 0 ? commandCount : nil
        )
    }

    /// Full parse of an OpenCode session, including all message events.
    static func parseFileFull(at url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let obj = try? decoder.decode(SessionJSON.self, from: data) else { return nil }

        let createdDate = obj.time?.created.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        let updatedDate = obj.time?.updated.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }

        let (events, modelID, commandCount) = loadMessages(for: obj.id, sessionURL: url)
        let storageRootURL = storageRoot(for: url)
        let warningEvents = storageDiagnosticsEvents(storageRoot: storageRootURL)
        let allEvents = warningEvents + events

        let nonMetaCount = allEvents.filter { $0.kind != .meta }.count
        return Session(
            id: obj.id,
            source: .opencode,
            startTime: createdDate,
            endTime: updatedDate,
            model: modelID,
            filePath: url.path,
            fileSizeBytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
            eventCount: nonMetaCount,
            events: allEvents,
            cwd: obj.directory,
            repoName: nil,
            lightweightTitle: obj.title,
            lightweightCommands: commandCount > 0 ? commandCount : nil
        )
    }

    // MARK: - Message loading helpers

    private static func storageRoot(for sessionURL: URL) -> URL {
        // sessionURL: ~/.local/share/opencode/storage/session/<projectID>/ses_<ID>.json
        // Strip /ses_<ID>.json -> .../storage/session/<projectID>
        // Strip project -> .../storage/session
        // Strip session -> .../storage
        return sessionURL
            .deletingLastPathComponent()        // .../storage/session/<projectID>
            .deletingLastPathComponent()        // .../storage/session
            .deletingLastPathComponent()        // .../storage
    }

    private static func detectSchemaVersion(storageRoot: URL) -> StorageSchemaVersion {
        let migrationURL = storageRoot.appendingPathComponent("migration", isDirectory: false)
        guard let data = try? Data(contentsOf: migrationURL),
              let str = String(data: data, encoding: .utf8) else {
            return .legacy
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(trimmed), let parsed = StorageSchemaVersion(rawValue: v) {
            return parsed
        }
        return .legacy
    }

    private static func storageLayout(for storageRoot: URL) -> any OpenCodeStorageLayout {
        switch detectSchemaVersion(storageRoot: storageRoot) {
        case .v2: return V2Layout()
        case .legacy: return LegacyLayout()
        }
    }

    private static func messagesRoot(for sessionID: String, sessionURL: URL) -> URL {
        // sessionURL: ~/.local/share/opencode/storage/session/<projectID>/ses_<ID>.json
        let projectDir = sessionURL.deletingLastPathComponent()
        let sessionRoot = projectDir.deletingLastPathComponent()
        let storageRoot = sessionRoot.deletingLastPathComponent()
        return storageRoot
            .appendingPathComponent("message", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private static func lightweightMessageMetadata(for sessionID: String, sessionURL: URL) -> (count: Int, modelID: String?, commands: Int) {
        let root = messagesRoot(for: sessionID, sessionURL: sessionURL)
        let storageRoot = storageRoot(for: sessionURL)
        let layout = storageLayout(for: storageRoot)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (0, nil, 0)
        }
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            return (0, nil, 0)
        }
        var count = 0
        var firstModelID: String?
        var commands = 0
        var legacyIndex: [String: [URL]]? = nil
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("msg_") && url.pathExtension.lowercased() == "json" {
                count += 1
                guard let data = try? Data(contentsOf: url),
                      let msg = try? JSONDecoder().decode(MessageJSON.self, from: data) else {
                    continue
                }
                if firstModelID == nil,
                   let mid = (msg.model?.modelID ?? msg.modelID), !mid.isEmpty {
                    firstModelID = mid
                }
                if let tools = msg.tools,
                   (tools.todowrite ?? false) || (tools.todoread ?? false) || (tools.task ?? false) {
                    commands += 1
                }
                if containsToolPart(for: msg.id, storageRoot: storageRoot, layout: layout, legacyIndex: &legacyIndex) {
                    commands += 1
                }
            }
        }
        return (count, firstModelID, commands)
    }

    private static func loadMessages(for sessionID: String, sessionURL: URL) -> ([SessionEvent], String?, Int) {
        let root = messagesRoot(for: sessionID, sessionURL: sessionURL)
        let storageRoot = storageRoot(for: sessionURL)
        let layout = storageLayout(for: storageRoot)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return ([], nil, 0)
        }
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return ([], nil, 0)
        }

        var events: [SessionEvent] = []
        var modelID: String?
        var commandCount = 0
        var legacyIndex: [String: [URL]]? = nil

        // Collect message files first so we can enforce stable ordering.
        var messageFiles: [(url: URL, created: Date?, fileName: String)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("msg_"), url.pathExtension.lowercased() == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let msg = try? JSONDecoder().decode(MessageJSON.self, from: data) else {
                continue
            }
            guard msg.sessionID == sessionID else { continue }
            let created = msg.time?.created.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            messageFiles.append((url: url, created: created, fileName: url.lastPathComponent))
        }

        messageFiles.sort { lhs, rhs in
            switch (lhs.created, rhs.created) {
            case let (l?, r?): return l < r
            default: return lhs.fileName < rhs.fileName
            }
        }

        for item in messageFiles {
            let url = item.url
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let msg = try? JSONDecoder().decode(MessageJSON.self, from: data) else { continue }

            let ts = msg.time?.created.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            if modelID == nil, let mid = (msg.model?.modelID ?? msg.modelID), !mid.isEmpty {
                modelID = mid
            }

            let partEvents = loadPartEvents(for: msg, storageRoot: storageRoot, layout: layout, legacyIndex: &legacyIndex, fallbackTimestamp: ts)
            let hasToolParts = !partEvents.tool.isEmpty
            let hasTextParts = !partEvents.text.isEmpty

            let rawJSON: String = {
                if let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return ""
            }()

            // Treat messages with tools flags as command/tool-call events for terminal view + filters
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }
            commandCount += partEvents.tool.filter { $0.kind == .tool_call }.count

            // Preserve the raw message record for JSON view/debugging, but do not let it
            // drive transcript rendering (OpenCode stores actual text content in part files).
            let messageMetaEvent = SessionEvent(
                id: msg.id + "-meta",
                timestamp: ts,
                kind: .meta,
                role: msg.role,
                text: nil,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: msg.id,
                parentID: nil,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(messageMetaEvent)

            if hasTextParts {
                events.append(contentsOf: partEvents.text)
            } else {
                // Fallback: use message summary fields when text parts are unavailable.
                // (Some older OpenCode versions or compact records only store summary text.)
                let baseKind = SessionEventKind.from(role: msg.role, type: nil)
                let normalizedRole = msg.role?.lowercased()

                // Build event text with sensible fallbacks
                var text: String?
                if normalizedRole == "user" {
                    // Prefer title for user (older OpenCode sometimes placed assistant-style content in body).
                    text = msg.summary?.title
                    if (text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) {
                        text = msg.summary?.body
                    }
                } else {
                    // For assistant/tool/other messages, use body with title fallback
                    text = msg.summary?.body
                    if (text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true),
                       let title = msg.summary?.title, !title.isEmpty {
                        text = title
                    }
                }

                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isUser = normalizedRole == "user"

                // If this message is purely a tool-call wrapper (common for assistant turns),
                // rely on tool-part events instead of rendering an empty assistant/tool line.
                if trimmed.isEmpty && (hasTools || hasToolParts) && !isUser {
                    // no-op
                } else if trimmed.isEmpty && !isUser {
                    // Drop completely empty non-user messages to avoid blank rows.
                } else {
                    let event = SessionEvent(
                        id: msg.id,
                        timestamp: ts,
                        kind: baseKind,
                        role: msg.role,
                        text: text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: msg.id,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                    events.append(event)
                }
            }
            // Include tool parts and any other non-text parts (reasoning/step/etc.) as meta so JSON view stays complete.
            events.append(contentsOf: partEvents.tool)
            events.append(contentsOf: partEvents.meta)
        }

        return (events, modelID, commandCount)
    }

    // MARK: - Tool part helpers

    private struct PartEvents {
        var text: [SessionEvent] = []
        var tool: [SessionEvent] = []
        var meta: [SessionEvent] = []
    }

    private static func loadPartEvents(for msg: MessageJSON,
                                       storageRoot: URL,
                                       layout: any OpenCodeStorageLayout,
                                       legacyIndex: inout [String: [URL]]?,
                                       fallbackTimestamp: Date?) -> PartEvents {
        let files = layout.partFiles(forMessageID: msg.id, storageRoot: storageRoot, legacyIndex: &legacyIndex)
        if files.isEmpty { return PartEvents() }

        let kind = SessionEventKind.from(role: msg.role, type: nil)

        struct LoadedPart {
            let url: URL
            let raw: String
            let dict: [String: Any]
            let type: String
            let start: Date?
            let fileName: String
        }

        var loaded: [LoadedPart] = []
        loaded.reserveCapacity(files.count)

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let typeAny = obj["type"] as? String else {
                continue
            }
            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            let type = typeAny.lowercased()
            let start = dateFromMillis((obj["time"] as? [String: Any])?["start"])
                ?? dateFromMillis(((obj["state"] as? [String: Any])?["time"] as? [String: Any])?["start"])
            loaded.append(LoadedPart(url: file, raw: rawJSON, dict: obj, type: type, start: start, fileName: file.lastPathComponent))
        }

        loaded.sort { lhs, rhs in
            switch (lhs.start, rhs.start) {
            case let (l?, r?): return l < r
            default: return lhs.fileName < rhs.fileName
            }
        }

        var parts = PartEvents()

        for part in loaded {
            let obj = part.dict
            let partID = (obj["id"] as? String) ?? part.fileName
            let ts = fallbackTimestamp ?? part.start

            switch part.type {
            case "text":
                let text = (obj["text"] as? String) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                parts.text.append(SessionEvent(
                    id: partID,
                    timestamp: ts,
                    kind: kind,
                    role: msg.role,
                    text: text,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: msg.id,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: part.raw
                ))

            case "tool":
                let callID = obj["callID"] as? String
                let toolName = obj["tool"] as? String
                let state = obj["state"] as? [String: Any] ?? [:]
                let status = (state["status"] as? String)?.lowercased()
                let inputStr = stringifyJSON(state["input"])
                let outputStr = stringifyJSON(state["output"]) ?? stringifyJSON(state["stdout"])
                let errorStr = stringifyJSON(state["error"]) ?? stringifyJSON(state["stderr"])

                let timeDict = state["time"] as? [String: Any]
                let startDate = dateFromMillis(timeDict?["start"]) ?? fallbackTimestamp ?? part.start
                let endDate = dateFromMillis(timeDict?["end"]) ?? dateFromMillis(timeDict?["start"]) ?? fallbackTimestamp ?? part.start

                let callEvent = SessionEvent(
                    id: partID + "-call",
                    timestamp: startDate,
                    kind: .tool_call,
                    role: "assistant",
                    text: nil,
                    toolName: toolName,
                    toolInput: inputStr,
                    toolOutput: nil,
                    messageID: callID ?? msg.id,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: part.raw
                )
                parts.tool.append(callEvent)

                let isError = status == "error" || (errorStr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                let resultKind: SessionEventKind = isError ? .error : .tool_result
                let resultText: String? = {
                    if isError { return (errorStr?.isEmpty == false ? errorStr : outputStr) }
                    return outputStr
                }()

                parts.tool.append(SessionEvent(
                    id: partID + (isError ? "-error" : "-result"),
                    timestamp: endDate,
                    kind: resultKind,
                    role: nil,
                    text: resultText,
                    toolName: toolName,
                    toolInput: nil,
                    toolOutput: outputStr,
                    messageID: callID ?? msg.id,
                    parentID: callEvent.id,
                    isDelta: false,
                    rawJSON: part.raw
                ))

            case "reasoning":
                parts.meta.append(SessionEvent(
                    id: partID + "-meta",
                    timestamp: ts,
                    kind: .meta,
                    role: msg.role,
                    text: "[OpenCode reasoning part]",
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: msg.id,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: part.raw
                ))

            default:
                parts.meta.append(SessionEvent(
                    id: partID + "-meta",
                    timestamp: ts,
                    kind: .meta,
                    role: msg.role,
                    text: "[OpenCode part: \(part.type)]",
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: msg.id,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: part.raw
                ))
            }
        }

        return parts
    }

    private static func containsToolPart(for messageID: String,
                                         storageRoot: URL,
                                         layout: any OpenCodeStorageLayout,
                                         legacyIndex: inout [String: [URL]]?) -> Bool {
        let files = layout.partFiles(forMessageID: messageID, storageRoot: storageRoot, legacyIndex: &legacyIndex)
        if files.isEmpty { return false }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type.lowercased() == "tool" else {
                continue
            }
            return true
        }
        return false
    }

    private static func storageDiagnosticsEvents(storageRoot: URL) -> [SessionEvent] {
        let fm = FileManager.default
        let diffDir = storageRoot.appendingPathComponent("session_diff", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: diffDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        // Only surface a warning when there is actually content.
        let items = (try? fm.contentsOfDirectory(at: diffDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if items.isEmpty { return [] }

        let payload = """
        {"type":"opencode_import_warning","warning":"OpenCode session_diff is present; diffs are not imported yet.","path":"\(diffDir.path)"}
        """
        return [
            SessionEvent(
                id: "opencode-session-diff-warning",
                timestamp: nil,
                kind: .meta,
                role: nil,
                text: "OpenCode: session_diff present (diffs not imported).",
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: nil,
                parentID: nil,
                isDelta: false,
                rawJSON: payload
            )
        ]
    }

    private static func stringifyJSON(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let str = any as? String { return str }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: any)
    }

    private static func dateFromMillis(_ value: Any?) -> Date? {
        guard let num = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: num.doubleValue / 1000.0)
    }
}
