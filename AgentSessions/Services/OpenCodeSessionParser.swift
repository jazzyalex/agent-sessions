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
            }
        }
        return (count, firstModelID, commands)
    }

    private static func loadMessages(for sessionID: String, sessionURL: URL) -> ([SessionEvent], String?, Int) {
        let root = messagesRoot(for: sessionID, sessionURL: sessionURL)
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

            let rawJSON: String = {
                if let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return ""
            }()

            // Treat messages with tools flags as command/tool-call events for terminal view + filters
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }

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
            var text = msg.summary?.body
            if (text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true),
               let title = msg.summary?.title, !title.isEmpty {
                text = title
            }

            // Drop completely empty, non-tool, non-error messages to avoid blank rows.
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty && !hasTools && !isError {
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
}
