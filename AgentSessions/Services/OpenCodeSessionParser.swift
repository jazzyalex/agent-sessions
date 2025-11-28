import Foundation

/// Parser for OpenCode sessions stored under ~/.local/share/opencode/storage
final class OpenCodeSessionParser {
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
        let tools: Tools?
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

        return Session(
            id: obj.id,
            source: .opencode,
            startTime: createdDate,
            endTime: updatedDate,
            model: modelID,
            filePath: url.path,
            fileSizeBytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
            eventCount: events.count,
            events: events,
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
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("msg_") && url.pathExtension.lowercased() == "json" {
                count += 1
                guard let data = try? Data(contentsOf: url),
                      let msg = try? JSONDecoder().decode(MessageJSON.self, from: data) else {
                    continue
                }
                if firstModelID == nil,
                   let mid = msg.model?.modelID, !mid.isEmpty {
                    firstModelID = mid
                }
                if let tools = msg.tools,
                   (tools.todowrite ?? false) || (tools.todoread ?? false) || (tools.task ?? false) {
                    commands += 1
                }
                if containsToolPart(for: msg.id, storageRoot: storageRoot) {
                    commands += 1
                }
            }
        }
        return (count, firstModelID, commands)
    }

    private static func loadMessages(for sessionID: String, sessionURL: URL) -> ([SessionEvent], String?, Int) {
        let root = messagesRoot(for: sessionID, sessionURL: sessionURL)
        let storageRoot = storageRoot(for: sessionURL)
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

        for case let url as URL in enumerator {
            if !url.lastPathComponent.hasPrefix("msg_") || url.pathExtension.lowercased() != "json" {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let msg = try? JSONDecoder().decode(MessageJSON.self, from: data) else { continue }
            if msg.sessionID != sessionID {
                continue
            }

            let ts = msg.time?.created.flatMap { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            if modelID == nil, let mid = msg.model?.modelID, !mid.isEmpty {
                modelID = mid
            }

            let toolPartEvents = loadToolPartEvents(for: msg.id, storageRoot: storageRoot, fallbackTimestamp: ts)
            let hasToolParts = !toolPartEvents.isEmpty

            let rawJSON: String = {
                if let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return ""
            }()

            // Treat messages with tools flags as command/tool-call events for terminal view + filters
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }
            commandCount += toolPartEvents.filter { $0.kind == .tool_call }.count

            let baseKind = SessionEventKind.from(role: msg.role, type: nil)
            // Heuristic error detection: tool messages whose body clearly indicates failure become .error
            var isError = false
            if hasTools, let body = msg.summary?.body?.lowercased() {
                if body.contains("error") || body.contains("failed") || body.contains("exception") || body.contains("traceback") {
                    isError = true
                }
            }
            let kind: SessionEventKind
            if isError {
                kind = .error
            } else if hasTools {
                kind = .tool_call
            } else {
                kind = baseKind
            }

            let toolName: String? = {
                guard let tools = msg.tools else { return nil }
                if tools.task == true { return "task" }
                if tools.todowrite == true { return "write" }
                if tools.todoread == true { return "read" }
                return nil
            }()

            // Build event text with sensible fallbacks
            var text: String?
            if msg.role?.lowercased() == "user" {
                // For user messages, ALWAYS use title (contains user's request summary)
                text = msg.summary?.title
            } else {
                // For assistant/tool/other messages, use body with title fallback
                text = msg.summary?.body
                if (text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true),
                   let title = msg.summary?.title, !title.isEmpty {
                    text = title
                }
            }

            // Drop completely empty, non-tool, non-error messages to avoid blank rows.
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isUser = msg.role?.lowercased() == "user"
            if trimmed.isEmpty && !hasTools && !hasToolParts && !isError && !isUser {
                continue
            }

            let event = SessionEvent(
                id: msg.id,
                timestamp: ts,
                kind: kind,
                role: msg.role,
                text: text,
                toolName: toolName,
                toolInput: nil,
                toolOutput: nil,
                messageID: nil,
                parentID: nil,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(event)
            events.append(contentsOf: toolPartEvents)
        }

        events.sort { (lhs, rhs) in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }

        return (events, modelID, commandCount)
    }

    // MARK: - Tool part helpers

    private static func containsToolPart(for messageID: String, storageRoot: URL) -> Bool {
        let partDir = storageRoot
            .appendingPathComponent("part", isDirectory: true)
            .appendingPathComponent(messageID, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: partDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil) else {
            return false
        }
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

    private static func loadToolPartEvents(for messageID: String, storageRoot: URL, fallbackTimestamp: Date?) -> [SessionEvent] {
        let partDir = storageRoot
            .appendingPathComponent("part", isDirectory: true)
            .appendingPathComponent(messageID, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: partDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var events: [SessionEvent] = []
        let sortedFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in sortedFiles {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type.lowercased() == "tool" else {
                continue
            }

            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            let partID = (obj["id"] as? String) ?? file.lastPathComponent
            let callID = obj["callID"] as? String
            let toolName = obj["tool"] as? String

            let state = obj["state"] as? [String: Any] ?? [:]
            let status = (state["status"] as? String)?.lowercased()
            let inputStr = stringifyJSON(state["input"])
            let outputStr = stringifyJSON(state["output"]) ?? stringifyJSON(state["stdout"])
            let errorStr = stringifyJSON(state["error"]) ?? stringifyJSON(state["stderr"])

            let timeDict = state["time"] as? [String: Any]
            let startDate = dateFromMillis(timeDict?["start"]) ?? fallbackTimestamp
            let endDate = dateFromMillis(timeDict?["end"]) ?? dateFromMillis(timeDict?["start"]) ?? fallbackTimestamp

            let callEvent = SessionEvent(
                id: partID + "-call",
                timestamp: startDate,
                kind: .tool_call,
                role: "assistant",
                text: nil,
                toolName: toolName,
                toolInput: inputStr,
                toolOutput: nil,
                messageID: callID ?? messageID,
                parentID: nil,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(callEvent)

            let isError = status == "error" || (errorStr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let resultKind: SessionEventKind = isError ? .error : .tool_result
            let resultText: String? = {
                if isError { return (errorStr?.isEmpty == false ? errorStr : outputStr) }
                return outputStr
            }()

            let resultEvent = SessionEvent(
                id: partID + (isError ? "-error" : "-result"),
                timestamp: endDate,
                kind: resultKind,
                role: nil,
                text: resultText,
                toolName: toolName,
                toolInput: nil,
                toolOutput: outputStr,
                messageID: callID ?? messageID,
                parentID: callEvent.id,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(resultEvent)
        }

        return events
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
