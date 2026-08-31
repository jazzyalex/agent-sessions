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
    private static let validRecordTypes: Set<String> = [
        "user", "assistant", "tool_result", "system"
    ]
    private static let artifactSubtypes: Set<String> = [
        "session_artifact_event", "session_artifact_snapshot"
    ]
    private static let runtimeUserSubtypes: Set<String> = [
        "goal_runtime", "cron", "notification"
    ]

    /// `KNOWN_RECORD_SUBTYPES` as shipped in 0.22.3
    /// (`packages/core/src/utils/transcript-records.ts`, read from the installed
    /// `@qwen-code/qwen-code@0.22.3` package). Used only to decide whether a record is
    /// *novel*; it deliberately does not change how any of these render. Everything here
    /// is written with `createBaseRecord("system")` except `goal_runtime` and
    /// `mid_turn_user_message` (`"user"`) and `realtime_message` (the entry's own role),
    /// so the system-typed ones already reach the transcript as meta.
    ///
    /// `user_text_elements` is included because 0.22.3 writes it, even though upstream
    /// omitted it from its own known set — without it every such record would read as
    /// novelty on the first real transcript.
    private static let knownRecordSubtypes: Set<String> = [
        "chat_compression", "slash_command", "ui_telemetry", "at_command",
        "attribution_snapshot", "notification", "cron", "mid_turn_user_message",
        "realtime_message", "custom_title", "parent_session", "rewind",
        "agent_bootstrap", "agent_launch_prompt", "agent_retry",
        "file_history_snapshot", "session_source", "session_model",
        "branch_checkpoint", "goal_state", "goal_runtime", "turn_result",
        "user_text_elements",
        "session_artifact_event", "session_artifact_snapshot"
    ]

    /// Counts records this parser does not recognise, keyed by the unknown top-level
    /// `type`, or `"<type>/<subtype>"` when the type is known and the subtype is not.
    ///
    /// Unknown *types* are the reason this exists: `validatedRecord` rejects them, so
    /// such a record leaves no trace at all — it is not mis-bucketed, it is gone. 0.22.3
    /// skips them too, so the chain walk keeps matching upstream; this only makes the
    /// omission visible instead of silent.
    ///
    /// Scope is the **whole file**, including dead rewind branches, because the caller
    /// is format monitoring: what is on disk is the question, not what one transcript
    /// renders. The in-transcript notice is scoped differently and deliberately — see
    /// `build(url:includeEvents:)`. Returns `nil` when the file cannot be read, which
    /// callers must not conflate with "nothing unrecognised".
    static func unrecognizedRecordCensus(at url: URL) -> [String: Int]? {
        guard let loaded = loadRecords(from: url) else { return nil }
        var census = loaded.unknownTypes
        for (key, count) in loaded.unknownSubtypes {
            census[key, default: 0] += count
        }
        return census
    }

    /// The census already computed while parsing, read back from the notice event rather
    /// than by reading the transcript a second time. Empty when nothing was unrecognised.
    static func unrecognizedRecordCensus(in session: Session) -> [String: Int] {
        guard let notice = session.events.first(where: { $0.role == unrecognizedNoticeRole }),
              let data = notice.rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return object
    }

    static let unrecognizedNoticeRole = "unrecognized_records"

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
        build(url: url, includeEvents: false)
    }

    /// No size ceiling: every call site (descriptor, indexer reload) deliberately parses
    /// whatever the user has, because refusing to open a large transcript is worse than
    /// the parse cost. The `allowLargeFile:` seam other parsers carry was dead here — no
    /// caller ever took the guarded path — so it is not kept as decoration.
    static func parseFileFull(at url: URL) -> Session? {
        build(url: url, includeEvents: true)
    }

    static func isValidHeadObject(_ object: [String: Any], expectedSessionID: String) -> Bool {
        guard let record = validatedRecord(object, physicalIndex: 0) else { return false }
        return record.sessionID.caseInsensitiveCompare(expectedSessionID) == .orderedSame
    }

    private static func build(url: URL, includeEvents: Bool) -> Session? {
        guard let expectedSessionID = QwenSessionDiscovery.sessionID(forTranscript: url) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard let loaded = loadRecords(from: url) else { return nil }
        let allRecords = loaded.records
        guard !allRecords.isEmpty else { return nil }
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

        // Scoped to the active chain on purpose: an unknown subtype on a dead rewind
        // branch renders nowhere, so reporting it would point at content this transcript
        // deliberately does not show. Unknown *types* below stay whole-file, because
        // they are dropped from every branch and there is no chain to scope them to.
        var chainUnknownSubtypes: [String: Int] = [:]

        for record in selectedRecords {
            if let subtype = record.subtype, !knownRecordSubtypes.contains(subtype) {
                chainUnknownSubtypes["\(record.type)/\(subtype)", default: 0] += 1
            }

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

        // One trailing notice, only when something genuinely unrecognised was read. A
        // 0.14.3 transcript never produces it, so no existing event count moves. The two
        // buckets are described separately because only one of them is hidden.
        let noticeCensus = chainUnknownSubtypes.merging(loaded.unknownTypes) { lhs, rhs in lhs + rhs }
        if includeEvents, !noticeCensus.isEmpty {
            func summarize(_ counts: [String: Int]) -> String {
                counts.sorted { $0.key < $1.key }
                    .map { "\($0.key) ×\($0.value)" }
                    .joined(separator: ", ")
            }
            var sentences: [String] = []
            if !loaded.unknownTypes.isEmpty {
                sentences.append(
                    "Skipped and not shown anywhere in this transcript — records with an "
                        + "unrecognized top-level type: \(summarize(loaded.unknownTypes)). "
                        + "The Qwen CLI's own reader skips these too."
                )
            }
            if !chainUnknownSubtypes.isEmpty {
                sentences.append(
                    "Shown above as metadata, with their raw JSON intact — records with an "
                        + "unrecognized subtype: \(summarize(chainUnknownSubtypes))."
                )
            }
            renderedEvents.append(
                event(
                    id: "\(expectedSessionID)-unrecognized",
                    timestamp: nil,
                    kind: .meta,
                    role: unrecognizedNoticeRole,
                    text: sentences.joined(separator: " "),
                    rawJSON: jsonString(noticeCensus) ?? "{}",
                    parentID: nil
                )
            )
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

    private static func loadRecords(
        from url: URL
    ) -> (records: [Record], unknownTypes: [String: Int], unknownSubtypes: [String: Int])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var records: [Record] = []
        var unknownTypes: [String: Int] = [:]
        var unknownSubtypes: [String: Int] = [:]
        var buffer = Data()
        var physicalIndex = 0
        let newline = Data([0x0A])

        func consume(_ data: Data, physicalIndex: Int) {
            guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
            for object in QwenJSONL.objects(inPhysicalLine: line) {
                noteIfUnrecognized(object, types: &unknownTypes, subtypes: &unknownSubtypes)
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
        return (records, unknownTypes, unknownSubtypes)
    }

    /// Only records that carry a plausible identity are censused. A line missing `uuid`
    /// or `sessionId` is malformed rather than novel, and counting it would turn
    /// corruption into a format-change report.
    ///
    /// Unknown types and unknown subtypes are kept apart because their fates differ: a
    /// record with an unknown type is dropped and can never be displayed, while a record
    /// with an unknown subtype renders as meta. Conflating them produces a notice that
    /// is false about one of the two.
    private static func noteIfUnrecognized(
        _ object: [String: Any],
        types: inout [String: Int],
        subtypes: inout [String: Int]
    ) {
        guard let uuid = object["uuid"] as? String, !uuid.isEmpty,
              object["sessionId"] is String,
              let type = object["type"] as? String else { return }

        guard validRecordTypes.contains(type) else {
            types[type, default: 0] += 1
            return
        }
        if let subtype = object["subtype"] as? String, !knownRecordSubtypes.contains(subtype) {
            subtypes["\(type)/\(subtype)", default: 0] += 1
        }
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
                                    toolOutput: toolResponseText(response["response"]),
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

    /// Mirrors the display projection read from the installed Qwen Code 0.22.3
    /// package source (`projectUserTranscriptForDisplay` /
    /// `isUserPromptSubmitContextPartText`, unchanged from the earlier 0.21.13
    /// reading): the reserved hook context is removable only when it is a separate
    /// final part, uses the writer's newline-delimited wrapper, and contains no nested
    /// wrapper tag. Behaviour is claimed from reading that source, not from an observed
    /// transcript at any version — the matrix pins `max_verified_version: 0.14.3`.
    private static func isUserPromptSubmitContextPart(_ value: Any) -> Bool {
        guard let part = value as? [String: Any],
              let text = part["text"] as? String else { return false }
        let open = "<qwen:user-prompt-submit-context>"
        let close = "</qwen:user-prompt-submit-context>"
        let prefix = "\(open)\n"
        let suffix = "\n\(close)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return false }

        // A degenerate wrapper such as "<open>\n</close>" satisfies both hasPrefix and
        // hasSuffix by sharing the single newline, so the two offsets overlap. Treat any
        // overlap as an empty body (matching Qwen's own slice semantics) instead of
        // forming an invalid Range, which would crash the whole indexing pass.
        guard trimmed.count > prefix.count + suffix.count else { return true }
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

    /// Qwen wraps every tool result as `{"output": "<text>"}` (or `{"error": …}`), including
    /// the `agent` subagent's markdown report. Unwrap single-key envelopes so the transcript
    /// shows the text rather than a JSON literal with escaped newlines.
    static func toolResponseText(_ value: Any?) -> String? {
        if let dict = value as? [String: Any], dict.count == 1 {
            if let output = dict["output"] as? String { return output }
            if let error = dict["error"] as? String { return error }
        }
        return jsonString(value)
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
