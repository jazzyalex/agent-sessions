import Foundation

/// JSONL decoding shared by Qwen discovery and parsing.
///
/// Qwen's reader first tries one JSON object per physical line, then recovers
/// the known `}{` corruption shape by scanning balanced top-level objects. The
/// fallback here is deliberately stricter about everything between objects:
/// arbitrary prefix, infix, or suffix bytes reject the entire line.
enum QwenJSONL {
    static func objects(inPhysicalLine line: String) -> [[String: Any]] {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }

        let bytes = Array(data)
        var objects: [[String: Any]] = []
        var cursor = 0

        while true {
            while cursor < bytes.count, isJSONWhitespace(bytes[cursor]) { cursor += 1 }
            if cursor == bytes.count { break }
            guard bytes[cursor] == 0x7B else { return [] } // {

            let start = cursor
            var depth = 0
            var inString = false
            var escaped = false
            var end: Int?

            while cursor < bytes.count {
                let byte = bytes[cursor]
                if escaped {
                    escaped = false
                } else if inString {
                    if byte == 0x5C { // \\
                        escaped = true
                    } else if byte == 0x22 { // "
                        inString = false
                    }
                } else {
                    switch byte {
                    case 0x22: // "
                        inString = true
                    case 0x7B: // {
                        depth += 1
                    case 0x7D: // }
                        depth -= 1
                        if depth == 0 {
                            end = cursor
                        } else if depth < 0 {
                            return []
                        }
                    default:
                        break
                    }
                }

                cursor += 1
                if end != nil { break }
            }

            guard let end, !inString, depth == 0 else { return [] }
            let fragment = Data(bytes[start...end])
            guard let object = try? JSONSerialization.jsonObject(with: fragment) as? [String: Any] else {
                return []
            }
            objects.append(object)
        }

        // A single malformed object is not a recovery case. Requiring multiple
        // complete objects prevents the fallback from accepting JSON plus junk.
        return objects.count > 1 ? objects : []
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

/// Parses Qwen Code's tree-structured JSONL transcript.
///
/// Qwen records rewinds as branches. Its current reader selects the last
/// non-artifact record as the active leaf, walks parent UUIDs back to the root,
/// and aggregates repeated-UUID fragments. Agent Sessions mirrors that
/// topology before deriving any list metadata or rendered event so dead rewind
/// branches cannot leak into titles, counts, search, analytics, or resume cwd.
enum QwenSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024

    private static let validRecordTypes: Set<String> = [
        "user", "assistant", "tool_result", "system"
    ]
    private static let artifactSubtypes: Set<String> = [
        "session_artifact_event", "session_artifact_snapshot"
    ]
    private static let runtimeUserSubtypes: Set<String> = [
        "goal_runtime", "cron", "notification"
    ]

    private struct Record {
        var object: [String: Any]
        let uuid: String
        let parentUUID: String?
        let sessionID: String
        let type: String
        let subtype: String?
        let physicalIndex: Int

        var isArtifact: Bool {
            type == "system" && subtype.map(artifactSubtypes.contains) == true
        }
    }

    static func parseFile(at url: URL) -> Session? {
        // Lightweight rows still require the complete topology: the active leaf,
        // title, cwd, and counts may all be written after an arbitrary rewind.
        build(url: url, includeEvents: false, allowLargeFile: true)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        build(url: url, includeEvents: true, allowLargeFile: allowLargeFile)
    }

    static func isValidHeadObject(_ object: [String: Any], expectedSessionID: String) -> Bool {
        guard let record = validatedRecord(object, physicalIndex: 0) else { return false }
        return record.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame
    }

    private static func build(url: URL, includeEvents: Bool, allowLargeFile: Bool) -> Session? {
        guard let expectedSessionID = QwenSessionDiscovery.sessionID(forTranscript: url) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }

        guard let allRecords = loadRecords(from: url), !allRecords.isEmpty else { return nil }
        guard allRecords.allSatisfy({
            $0.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame
        }) else { return nil }

        let conversationRecords = allRecords.filter { !$0.isArtifact }
        guard let leafUUID = conversationRecords.last?.uuid else { return nil }

        var fragmentsByUUID: [String: [Record]] = [:]
        var firstByUUID: [String: Record] = [:]
        for record in conversationRecords {
            fragmentsByUUID[record.uuid, default: []].append(record)
            if firstByUUID[record.uuid] == nil { firstByUUID[record.uuid] = record }
        }

        var reverseChain: [String] = []
        var visited: Set<String> = []
        var current: String? = leafUUID
        while let uuid = current, !uuid.isEmpty {
            guard !visited.contains(uuid) else { break }
            visited.insert(uuid)
            guard let record = firstByUUID[uuid] else { break }
            reverseChain.append(uuid)
            guard let parent = record.parentUUID, !parent.isEmpty else { break }
            guard firstByUUID[parent] != nil else { break }
            current = parent
        }

        let chainUUIDs = Array(reverseChain.reversed())
        let selectedRecords = chainUUIDs.compactMap { uuid in
            fragmentsByUUID[uuid].flatMap(aggregate)
        }
        guard !selectedRecords.isEmpty else { return nil }

        let selectedUUIDs = Set(chainUUIDs)
        let selectedPhysicalRecords = conversationRecords.filter { selectedUUIDs.contains($0.uuid) }

        var renderedEvents: [SessionEvent] = []
        var nonMetaCount = 0
        var commandCount = 0
        var firstUserTitle: String?

        for record in selectedRecords {
            if firstUserTitle == nil,
               record.type == "user",
               !runtimeUserSubtypes.contains(record.subtype ?? ""),
               let text = userDisplayText(from: record.object),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstUserTitle = text
            }

            let events = makeEvents(from: record)
            nonMetaCount += events.reduce(into: 0) { count, event in
                if event.kind != .meta { count += 1 }
            }
            commandCount += events.reduce(into: 0) { count, event in
                if event.kind == .tool_call { count += 1 }
            }
            if includeEvents { renderedEvents.append(contentsOf: events) }
        }

        let dates = selectedPhysicalRecords.compactMap { timestamp(from: $0.object) }
        let cwd = selectedPhysicalRecords.reversed().compactMap { record -> String? in
            guard let value = record.object["cwd"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.first
        let model = selectedRecords.reversed().compactMap { record -> String? in
            guard let value = record.object["model"] as? String, !value.isEmpty else { return nil }
            return value
        }.first
        let customTitle = selectedRecords.reversed().compactMap { record -> String? in
            guard record.type == "system", record.subtype == "custom_title",
                  let payload = record.object["systemPayload"] as? [String: Any],
                  let value = payload["customTitle"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.first

        return Session(
            id: expectedSessionID,
            source: .qwen,
            startTime: dates.min(),
            endTime: dates.max(),
            model: model,
            filePath: url.path,
            fileSizeBytes: size,
            eventCount: nonMetaCount,
            events: renderedEvents,
            cwd: cwd,
            repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            lightweightTitle: firstUserTitle,
            lightweightCommands: commandCount,
            customTitle: customTitle,
            surface: .cli
        )
    }

    private static func loadRecords(from url: URL) -> [Record]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var records: [Record] = []
        var buffer = Data()
        var physicalIndex = 0
        let newline = Data([0x0A])

        func consume(_ data: Data, physicalIndex: Int) {
            guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
            for object in QwenJSONL.objects(inPhysicalLine: line) {
                if let record = validatedRecord(object, physicalIndex: physicalIndex) {
                    records.append(record)
                }
            }
        }

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = Data(buffer[range.upperBound..<buffer.endIndex])
                consume(line, physicalIndex: physicalIndex)
                physicalIndex += 1
            }
        }

        if !buffer.isEmpty { consume(buffer, physicalIndex: physicalIndex) }
        return records
    }

    private static func validatedRecord(_ object: [String: Any], physicalIndex: Int) -> Record? {
        guard let uuid = object["uuid"] as? String, !uuid.isEmpty,
              object.keys.contains("parentUuid"),
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
              let type = object["type"] as? String, validRecordTypes.contains(type) else {
            return nil
        }

        let parentUUID: String?
        switch object["parentUuid"] {
        case let value as String:
            parentUUID = value.isEmpty ? nil : value
        case is NSNull:
            parentUUID = nil
        default:
            return nil
        }

        var normalized = object
        if let rawTimestamp = object["timestamp"] {
            guard let timestamp = rawTimestamp as? String, parseDate(timestamp) != nil else {
                normalized.removeValue(forKey: "timestamp")
                return Record(object: normalized, uuid: uuid, parentUUID: parentUUID,
                              sessionID: sessionID, type: type,
                              subtype: object["subtype"] as? String,
                              physicalIndex: physicalIndex)
            }
        }

        if let rawMessage = object["message"] {
            guard let message = rawMessage as? [String: Any] else {
                normalized.removeValue(forKey: "message")
                return Record(object: normalized, uuid: uuid, parentUUID: parentUUID,
                              sessionID: sessionID, type: type,
                              subtype: object["subtype"] as? String,
                              physicalIndex: physicalIndex)
            }
            var cleanMessage: [String: Any] = [:]
            if let role = message["role"] as? String { cleanMessage["role"] = role }
            if let parts = message["parts"] as? [Any] { cleanMessage["parts"] = parts }
            normalized["message"] = cleanMessage
        }

        if object["subtype"] != nil, !(object["subtype"] is String) {
            normalized.removeValue(forKey: "subtype")
        }

        return Record(object: normalized, uuid: uuid, parentUUID: parentUUID,
                      sessionID: sessionID, type: type,
                      subtype: normalized["subtype"] as? String,
                      physicalIndex: physicalIndex)
    }

    private static func aggregate(_ fragments: [Record]) -> Record? {
        guard let first = fragments.first else { return nil }
        var object = first.object
        var message = copiedMessage(first.object["message"])

        for fragment in fragments.dropFirst() {
            if let next = copiedMessage(fragment.object["message"]) {
                if let current = message {
                    var merged: [String: Any] = [:]
                    if let role = current["role"] as? String { merged["role"] = role }
                    let currentParts = current["parts"] as? [Any] ?? []
                    let nextParts = next["parts"] as? [Any] ?? []
                    merged["parts"] = currentParts + nextParts
                    message = merged
                } else {
                    message = next
                }
            }
            if let usage = fragment.object["usageMetadata"], !(usage is NSNull) {
                object["usageMetadata"] = usage
            }
            if (object["toolCallResult"] == nil || object["toolCallResult"] is NSNull),
               let result = fragment.object["toolCallResult"], !(result is NSNull) {
                object["toolCallResult"] = result
            }
            if ((object["model"] as? String)?.isEmpty != false),
               let model = fragment.object["model"] as? String, !model.isEmpty {
                object["model"] = model
            }
            if let timestamp = fragment.object["timestamp"] as? String,
               (object["timestamp"] as? String).map({ timestamp > $0 }) ?? true {
                object["timestamp"] = timestamp
            }
        }

        if let message { object["message"] = message } else { object.removeValue(forKey: "message") }
        return Record(object: object, uuid: first.uuid, parentUUID: first.parentUUID,
                      sessionID: first.sessionID, type: first.type,
                      subtype: first.subtype, physicalIndex: first.physicalIndex)
    }

    private static func copiedMessage(_ value: Any?) -> [String: Any]? {
        guard let message = value as? [String: Any] else { return nil }
        var copy: [String: Any] = [:]
        if let role = message["role"] as? String { copy["role"] = role }
        if let parts = message["parts"] as? [Any] { copy["parts"] = parts }
        return copy
    }

    private static func makeEvents(from record: Record) -> [SessionEvent] {
        let timestamp = timestamp(from: record.object)
        let rawJSON = jsonString(record.object) ?? "{}"
        let role = (record.object["message"] as? [String: Any])?["role"] as? String
        let parts = ((record.object["message"] as? [String: Any])?["parts"] as? [Any]) ?? []

        switch record.type {
        case "user":
            let text = userDisplayText(from: record.object)
            if runtimeUserSubtypes.contains(record.subtype ?? "") {
                return [event(id: "\(record.uuid)-m", timestamp: timestamp, kind: .meta,
                              role: record.subtype, text: text, rawJSON: rawJSON,
                              parentID: record.parentUUID)]
            }
            return [event(id: "\(record.uuid)-u", timestamp: timestamp, kind: .user,
                          role: role ?? "user", text: text, rawJSON: rawJSON,
                          parentID: record.parentUUID)]

        case "assistant":
            var output: [SessionEvent] = []
            for (partIndex, value) in parts.enumerated() {
                guard let part = value as? [String: Any] else { continue }
                if let text = part["text"] as? String, !text.isEmpty {
                    if (part["thought"] as? Bool) == true {
                        output.append(event(id: "\(record.uuid)-think\(partIndex)", timestamp: timestamp,
                                            kind: .meta, role: "reasoning", text: text,
                                            rawJSON: rawJSON, parentID: record.parentUUID))
                    } else {
                        output.append(event(id: "\(record.uuid)-a\(partIndex)", timestamp: timestamp,
                                            kind: .assistant, role: role ?? "assistant", text: text,
                                            rawJSON: rawJSON, parentID: record.parentUUID))
                    }
                }
                if let call = part["functionCall"] as? [String: Any] {
                    output.append(event(id: "\(record.uuid)-t\(partIndex)", timestamp: timestamp,
                                        kind: .tool_call, role: role ?? "assistant", text: nil,
                                        toolName: call["name"] as? String,
                                        toolInput: jsonString(call["args"]),
                                        messageID: call["id"] as? String,
                                        rawJSON: rawJSON, parentID: record.parentUUID))
                }
            }
            if output.isEmpty {
                output.append(event(id: "\(record.uuid)-m", timestamp: timestamp, kind: .meta,
                                    role: role ?? "assistant", text: nil, rawJSON: rawJSON,
                                    parentID: record.parentUUID))
            }
            return output

        case "tool_result":
            var output: [SessionEvent] = []
            for (partIndex, value) in parts.enumerated() {
                guard let part = value as? [String: Any],
                      let response = part["functionResponse"] as? [String: Any] else { continue }
                output.append(event(id: "\(record.uuid)-r\(partIndex)", timestamp: timestamp,
                                    kind: toolResultIsError(record.object) ? .error : .tool_result,
                                    role: role ?? "tool", text: nil,
                                    toolName: response["name"] as? String,
                                    toolOutput: jsonString(response["response"]),
                                    messageID: response["id"] as? String,
                                    rawJSON: rawJSON, parentID: record.parentUUID))
            }
            if output.isEmpty {
                let result = record.object["toolCallResult"] as? [String: Any]
                output.append(event(id: "\(record.uuid)-r", timestamp: timestamp,
                                    kind: toolResultIsError(record.object) ? .error : .tool_result,
                                    role: role ?? "tool", text: nil,
                                    toolName: result?["name"] as? String,
                                    toolOutput: jsonString(result?["resultDisplay"]),
                                    messageID: result?["callId"] as? String,
                                    rawJSON: rawJSON, parentID: record.parentUUID))
            }
            return output

        case "system":
            return [event(id: "\(record.uuid)-m", timestamp: timestamp, kind: .meta,
                          role: record.subtype ?? "system", text: systemText(from: record.object),
                          rawJSON: rawJSON, parentID: record.parentUUID)]

        default:
            return []
        }
    }

    private static func event(id: String,
                              timestamp: Date?,
                              kind: SessionEventKind,
                              role: String?,
                              text: String?,
                              toolName: String? = nil,
                              toolInput: String? = nil,
                              toolOutput: String? = nil,
                              messageID: String? = nil,
                              rawJSON: String,
                              parentID: String?) -> SessionEvent {
        SessionEvent(id: id, timestamp: timestamp, kind: kind, role: role, text: text,
                     toolName: toolName, toolInput: toolInput, toolOutput: toolOutput,
                     messageID: messageID, parentID: parentID, isDelta: false, rawJSON: rawJSON)
    }

    private static func userDisplayText(from object: [String: Any]) -> String? {
        if let payload = object["systemPayload"] as? [String: Any],
           let displayText = payload["displayText"] as? String {
            return displayText
        }

        guard let message = object["message"] as? [String: Any],
              var parts = message["parts"] as? [Any] else { return nil }
        if !(object["systemPayload"] is [String: Any]),
           parts.count > 1,
           isUserPromptSubmitContextPart(parts[parts.count - 1]) {
            parts.removeLast()
        }
        return messageText(from: parts)
    }

    private static func systemText(from object: [String: Any]) -> String? {
        if let payload = object["systemPayload"] as? [String: Any] {
            for key in ["customTitle", "displayText", "text", "message", "content"] {
                if let value = payload[key] as? String, !value.isEmpty { return value }
            }
        }
        return messageText(from: object)
    }

    private static func messageText(from object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let parts = message["parts"] as? [Any] else { return nil }
        return messageText(from: parts)
    }

    private static func messageText(from parts: [Any]) -> String? {
        let chunks = parts.compactMap { value -> String? in
            guard let part = value as? [String: Any],
                  (part["thought"] as? Bool) != true,
                  let text = part["text"] as? String, !text.isEmpty else { return nil }
            return text
        }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Mirrors Qwen 0.21.13's display projection exactly: the reserved hook
    /// context is removable only when it is a separate final part, uses the
    /// writer's newline-delimited wrapper, and contains no nested wrapper tag.
    private static func isUserPromptSubmitContextPart(_ value: Any) -> Bool {
        guard let part = value as? [String: Any],
              let text = part["text"] as? String else { return false }
        let open = "<qwen:user-prompt-submit-context>"
        let close = "</qwen:user-prompt-submit-context>"
        let prefix = "\(open)\n"
        let suffix = "\n\(close)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return false }

        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
        let body = trimmed[bodyStart..<bodyEnd]
        return !body.contains(open) && !body.contains(close)
    }

    private static func toolResultIsError(_ object: [String: Any]) -> Bool {
        guard let result = object["toolCallResult"] as? [String: Any] else { return false }
        if result["error"] != nil, !(result["error"] is NSNull) { return true }
        return (result["status"] as? String)?.lowercased() == "error"
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        if data.count > 32_768 { return "[OMITTED large JSON payload bytes=\(data.count)]" }
        return String(data: data, encoding: .utf8)
    }

    private static func timestamp(from object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        return parseDate(value)
    }

    private static func parseDate(_ value: String) -> Date? {
        dateLock.lock()
        defer { dateLock.unlock() }
        return isoFractional.date(from: value) ?? isoBasic.date(from: value)
    }

    private static let dateLock = NSLock()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
