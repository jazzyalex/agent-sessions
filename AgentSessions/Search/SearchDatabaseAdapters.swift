import Foundation
import SQLite3

extension SearchSourceScanner {
    static func scanDatabase(session: Session, summary: inout SearchScanSummary,
                             consume: (SearchTextSegment) throws -> Void) throws {
        let reader = try SearchSQLiteReader(session: session)
        defer { summary = reader.finish() }
        func emit(_ events: [SessionEvent]) throws {
            for event in events {
                try Task.checkCancellation()
                count(event, into: &reader.summary)
                for segment in SearchSourceText.segments(event: event, source: session.source) { try consume(segment) }
            }
        }
        switch session.source {
        case .opencode:
            let v2 = OpenCodeSqliteReader.searchUsesV2(reader.db, sessionID: session.id)
            guard try reader.hasRow("SELECT id, time_updated FROM \(v2 ? "session_v2" : "session") WHERE id = ?;", strings: [session.id]) else { throw Failure.unsupported }
            if v2 {
                let hasPartTable = try reader.hasRow("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_part';")
                try reader.rows("SELECT id, type, time_created, time_updated, data FROM session_message WHERE session_id = ? ORDER BY seq;", strings: [session.id]) { statement in
                    guard let id = reader.text(statement, 0), let type = reader.text(statement, 1),
                          let raw = reader.text(statement, 4) else { throw Failure.malformed }
                    let object = try reader.json(raw)
                    let created = sqlite3_column_int64(statement, 2)
                    let updated = sqlite3_column_int64(statement, 3)
                    let time = created > 0 ? Date(timeIntervalSince1970: Double(created) / 1000) : nil
                    func emitPart(_ part: (id: String, dict: [String: Any]),
                                  message: OpenCodeSessionParser.MessageJSON) throws {
                        try Task.checkCancellation()
                        let events = OpenCodeSessionParser.buildPartEvents(for: message, effectiveMsgID: id,
                            parts: [(id: part.id, dict: part.dict, rawJSON: "")], fallbackTimestamp: time)
                        try emit(events.text); try emit(events.tool); try emit(events.meta)
                    }
                    func adapt(hasExternalParts: Bool) throws
                        -> (OpenCodeSessionParser.MessageJSON, OpenCodeV2MessageAdapter.Adapted) {
                        let adapted = OpenCodeV2MessageAdapter.adapt(rowID: id, type: type,
                            timeCreatedMillis: created, timeUpdatedMillis: updated, data: object,
                            hasExternalParts: hasExternalParts)
                        guard let message = OpenCodeSqliteReader.searchMessage(adapted.message) else { throw Failure.malformed }
                        return (message, adapted)
                    }
                    var external: (OpenCodeSessionParser.MessageJSON, OpenCodeV2MessageAdapter.Adapted)?
                    if hasPartTable, type == "assistant" {
                        try reader.rows(OpenCodeSqliteReader.v2PartsSQL, strings: [session.id, id]) { partStatement in
                            guard let rawPart = reader.text(partStatement, 1) else { throw Failure.malformed }
                            let item = try reader.json(rawPart)
                            guard item["type"] is String else { throw Failure.malformed }
                            if external == nil { external = try adapt(hasExternalParts: true) }
                            guard let (message, _) = external else { throw Failure.malformed }
                            let part = OpenCodeV2MessageAdapter.contentPart(item, messageID: id,
                                ordinal: sqlite3_column_int64(partStatement, 0))
                            try emitPart(part, message: message)
                        }
                    }
                    let (message, adapted) = try external ?? adapt(hasExternalParts: false)
                    for part in adapted.parts { try emitPart(part, message: message) }
                }
            } else {
                try reader.rows("SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created, id;", strings: [session.id]) { statement in
                    guard let id = reader.text(statement, 0), let raw = reader.text(statement, 2) else { throw Failure.malformed }
                    let object = try reader.json(raw)
                    guard let message = OpenCodeSqliteReader.searchMessage(object) else { throw Failure.malformed }
                    let created = sqlite3_column_int64(statement, 1)
                    let time = created > 0 ? Date(timeIntervalSince1970: Double(created) / 1000) : nil
                    var sawText = false
                    try reader.rows("SELECT id, data FROM part WHERE message_id = ? ORDER BY time_created, id;", strings: [id]) { partStatement in
                        guard let partID = reader.text(partStatement, 0), let rawPart = reader.text(partStatement, 1) else { throw Failure.malformed }
                        let part = try reader.json(rawPart)
                        let events = OpenCodeSessionParser.buildPartEvents(for: message, effectiveMsgID: id,
                            parts: [(id: partID, dict: part, rawJSON: "")], fallbackTimestamp: time)
                        sawText = sawText || !events.text.isEmpty
                        try emit(events.text); try emit(events.tool); try emit(events.meta)
                    }
                    if !sawText { try emit(OpenCodeSqliteReader.searchFallbackEvents(message, id: id, time: time)) }
                }
            }
        case .hermes:
            guard try reader.hasRow("SELECT id FROM sessions WHERE id = ?;", strings: [session.id]) else { throw Failure.unsupported }
            try reader.rows("""
                SELECT id, role, content, tool_call_id, tool_calls, tool_name, timestamp,
                       finish_reason, reasoning, reasoning_content, codex_reasoning_items
                FROM messages WHERE session_id = ? ORDER BY timestamp, id;
                """, strings: [session.id]) { statement in
                if let tools = reader.text(statement, 4), !tools.isEmpty {
                    let data = Data(tools.utf8)
                    _ = try validateJSON(data)
                    guard try reader.isStrictJSON(tools) else { throw Failure.malformed }
                    guard (try? JSONSerialization.jsonObject(with: data)) is [[String: Any]] else {
                        throw Failure.malformed
                    }
                }
                try emit(HermesStateDBReader.searchEvents(statement: statement))
            }
        case .devin:
            var node: Int64?
            var found = false
            try reader.rows("SELECT main_chain_id FROM sessions WHERE id = ?;", strings: [session.id]) { statement in
                found = true
                if sqlite3_column_type(statement, 0) != SQLITE_NULL { node = sqlite3_column_int64(statement, 0) }
            }
            guard found else { throw Failure.unsupported }
            var seen = Set<Int64>()
            while let current = node {
                try Task.checkCancellation()
                guard seen.count < 65_536 else { throw Failure.resourceLimit }
                guard seen.insert(current).inserted else { throw Failure.malformed }
                var count = 0
                try reader.rows("SELECT parent_node_id, chat_message, created_at FROM message_nodes WHERE session_id = ?1 AND node_id = ?2;",
                                strings: [session.id], integers: [2: current]) { statement in
                    count += 1
                    guard count == 1, let raw = reader.text(statement, 1) else { throw Failure.malformed }
                    _ = try reader.json(raw)
                    node = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
                    let created = sqlite3_column_int64(statement, 2)
                    try emit(DevinSessionParser.events(fromChatMessage: raw, nodeID: current,
                        time: created > 0 ? Date(timeIntervalSince1970: Double(created)) : nil, forSearch: true))
                }
                guard count == 1 else { throw Failure.malformed }
            }
        case .openclaw:
            let components = session.id.split(separator: ":", maxSplits: 2)
            let id = session.id.hasPrefix("openclaw:") && components.count == 3 ? String(components[2]) : session.id
            guard try reader.hasRow("SELECT session_id, updated_at FROM session_windows WHERE session_id = ?;", strings: [id]) else { throw Failure.unsupported }
            if try reader.hasRow("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_transcript_cold_archives';"),
               try reader.hasRow("SELECT session_id FROM session_transcript_cold_archives WHERE session_id = ?;", strings: [id]) {
                throw Failure.unsupported
            }
            var columns = Set<String>()
            try reader.rows("PRAGMA table_info(transcript_events);") { statement in
                if let name = reader.text(statement, 1) { columns.insert(name) }
            }
            let compressed = columns.contains("event_zstd")
            let sql = compressed
                ? "SELECT seq, event_json, event_zstd, event_utf8_bytes FROM transcript_events WHERE session_id = ? ORDER BY seq;"
                : "SELECT seq, event_json FROM transcript_events WHERE session_id = ? ORDER BY seq;"
            var accumulator = OpenClawSessionParser.ParseAccumulator()
            try reader.rows(sql, strings: [id]) { statement in
                let raw: String
                if let text = reader.text(statement, 1) { raw = text }
                else if compressed {
                    let decodedBytes = sqlite3_column_int64(statement, 3)
                    guard decodedBytes > 0, decodedBytes <= 1024 * 1024,
                          sqlite3_column_bytes(statement, 2) <= 1024 * 1024 else { throw Failure.resourceLimit }
                    guard let text = OpenClawSqliteReader.searchDecodedPayload(statement, column: 2, decodedBytes: decodedBytes) else { throw Failure.malformed }
                    raw = text
                    reader.summary.decompressedBytes += UInt64(decodedBytes)
                } else { throw Failure.malformed }
                let object = try reader.json(raw)
                accumulator.events.removeAll(keepingCapacity: false)
                OpenClawSessionParser.appendRecord(object, url: URL(fileURLWithPath: session.filePath),
                    index: Int(sqlite3_column_int64(statement, 0)), into: &accumulator, forSearch: true)
                try emit(accumulator.events)
                accumulator.events.removeAll(keepingCapacity: false)
            }
        default: throw Failure.unsupported
        }
    }
}
