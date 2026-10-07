import Foundation
import SQLite3
import CryptoKit

/// Read-only telemetry adapter for Hermes' current `state.db` store.
///
/// Hermes writes both a session aggregate and a `session_model_usage` rollup.
/// The latter is the useful authority when present because it keeps model
/// attribution, but its `title_generation` row is bookkeeping rather than
/// session usage. The aggregate is retained as a checked fallback for older
/// databases without the rollup table.
struct HermesTelemetryReader {
    private static let databaseName = "state.db"
    private static let speed = "standard-normalized"
    private static let titleGenerationTask = "title_generation"

    private struct SessionRow {
        let model: String?
        let modelConfig: String?
        let startedAt: Date?
        let endedAt: Date?
        let lastActivityAt: Date?
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let reasoning: Int
        let bytesScanned: UInt64
    }

    private struct ModelUsageRow {
        let rowID: Int64
        let model: String
        let task: String?
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let reasoning: Int
        let firstSeen: Date?
        let lastSeen: Date?
        let bytesScanned: UInt64
    }

    private struct ModelUsageQuery {
        let tableExists: Bool
        let rows: [ModelUsageRow]
    }

    private struct UsageTotals {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var reasoning = 0

        var hasUsage: Bool {
            input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0 || reasoning != 0
        }

        var topLineTokens: Int? {
            guard let inputAndOutput = Self.adding(input, output),
                  let cacheReadAndWrite = Self.adding(cacheRead, cacheWrite),
                  let context = Self.adding(inputAndOutput, cacheReadAndWrite) else { return nil }
            return context
        }

        mutating func add(_ row: ModelUsageRow) -> Bool {
            guard let input = Self.adding(input, row.input),
                  let output = Self.adding(output, row.output),
                  let cacheRead = Self.adding(cacheRead, row.cacheRead),
                  let cacheWrite = Self.adding(cacheWrite, row.cacheWrite),
                  let reasoning = Self.adding(reasoning, row.reasoning) else {
                return false
            }
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.reasoning = reasoning
            return true
        }

        mutating func addSession(_ row: SessionRow) -> Bool {
            guard let input = Self.adding(input, row.input),
                  let output = Self.adding(output, row.output),
                  let cacheRead = Self.adding(cacheRead, row.cacheRead),
                  let cacheWrite = Self.adding(cacheWrite, row.cacheWrite),
                  let reasoning = Self.adding(reasoning, row.reasoning) else {
                return false
            }
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.reasoning = reasoning
            return true
        }

        static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : value
        }
    }

    /// The engine's cache key must follow logical session content, not only the
    /// database file stat: Hermes writes its live database through WAL.
    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard isSupportedSession(session),
              let db = openReadOnly(path: session.filePath) else { return nil }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db),
              let sessionRow = querySession(db: db, sessionID: session.id),
              let usageQuery = queryModelUsage(db: db, sessionID: session.id) else { return nil }
        defer { rollbackReadTransaction(db) }

        var hasher = SHA256()
        feed("session.id", session.id, into: &hasher)
        feedOptional("session.model", sessionRow.model, into: &hasher)
        feedOptional("session.model_config", sessionRow.modelConfig, into: &hasher)
        feed("session.started_at", revisionDate(sessionRow.startedAt), into: &hasher)
        feed("session.ended_at", revisionDate(sessionRow.endedAt), into: &hasher)
        feed("session.last_activity_at", revisionDate(sessionRow.lastActivityAt), into: &hasher)
        feed("session.input", String(sessionRow.input), into: &hasher)
        feed("session.output", String(sessionRow.output), into: &hasher)
        feed("session.cache_read", String(sessionRow.cacheRead), into: &hasher)
        feed("session.cache_write", String(sessionRow.cacheWrite), into: &hasher)
        feed("session.reasoning", String(sessionRow.reasoning), into: &hasher)
        feed("usage.table", usageQuery.tableExists ? "present" : "absent", into: &hasher)
        for row in usageQuery.rows {
            guard !Task.isCancelled else { return nil }
            feed("usage.rowid", String(row.rowID), into: &hasher)
            feed("usage.model", row.model, into: &hasher)
            feedOptional("usage.task", row.task, into: &hasher)
            feed("usage.input", String(row.input), into: &hasher)
            feed("usage.output", String(row.output), into: &hasher)
            feed("usage.cache_read", String(row.cacheRead), into: &hasher)
            feed("usage.cache_write", String(row.cacheWrite), into: &hasher)
            feed("usage.reasoning", String(row.reasoning), into: &hasher)
            feed("usage.first_seen", revisionDate(row.firstSeen), into: &hasher)
            feed("usage.last_seen", revisionDate(row.lastSeen), into: &hasher)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .logical(digest)
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard isSupportedSession(session),
              let db = openReadOnly(path: session.filePath) else { return nil }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        guard let sessionRow = querySession(db: db, sessionID: session.id),
              let usageQuery = queryModelUsage(db: db, sessionID: session.id),
              let bytesScanned = checkedBytesScanned(sessionRow: sessionRow,
                                                     usageRows: usageQuery.rows) else { return nil }
        guard !Task.isCancelled else { return cancelledScan(bytesScanned: bytesScanned) }

        let usageRows = usageQuery.rows.filter { $0.task != titleGenerationTask }
        let mainLoopRows = usageRows.filter { $0.task == nil }
        let aggregateHasUsage = sessionHasUsage(sessionRow)
        let usageFamily = usageQuery.tableExists
            ? "hermes.session_model_usage"
            : "hermes.sessions"
        var unavailableReason: String?
        if usageQuery.tableExists, mainLoopRows.isEmpty, aggregateHasUsage {
            let detail = usageQuery.rows.isEmpty
                ? "contains no rows"
                : usageRows.isEmpty
                    ? "contains only bookkeeping rows"
                    : "contains no main-loop rollup rows"
            unavailableReason = "Hermes model usage table \(detail); session tokens are unavailable because no attributable rollup was recorded."
        }

        var displayTotals = UsageTotals()
        var mainLoopTotals = UsageTotals()
        var events: [TelemetryUsageEvent] = []
        var slices: [String: TelemetryUsageSlice] = [:]

        if unavailableReason == nil, usageQuery.tableExists {
            for (index, row) in usageRows.enumerated() {
                guard !Task.isCancelled else { return cancelledScan(bytesScanned: bytesScanned) }
                guard displayTotals.add(row) else {
                    unavailableReason = "Hermes token totals exceed the supported integer range."
                    break
                }
                if row.task == nil {
                    guard mainLoopTotals.add(row) else {
                        unavailableReason = "Hermes token totals exceed the supported integer range."
                        break
                    }
                }
                append(row: row,
                       index: index,
                       usageFamily: usageFamily,
                       events: &events,
                       slices: &slices)
            }
            if unavailableReason == nil, !mainLoopRows.isEmpty,
               !matchesSessionAggregate(mainLoopTotals, sessionRow) {
                unavailableReason = "Hermes model usage does not match the session aggregate; token totals are unavailable until the provider records a consistent rollup."
            }
        } else if unavailableReason == nil {
            guard displayTotals.addSession(sessionRow) else {
                unavailableReason = "Hermes token totals exceed the supported integer range."
                return makeScan(session: session,
                                sessionRow: sessionRow,
                                usageRows: usageRows,
                                events: [],
                                slices: [:],
                                usageSummary: unavailableSummary(reason: unavailableReason,
                                                                  usageFamily: usageFamily),
                                bytesScanned: bytesScanned)
            }
            if aggregateHasUsage {
                let row = ModelUsageRow(rowID: 0,
                                        model: "",
                                        task: nil,
                                        input: sessionRow.input,
                                        output: sessionRow.output,
                                        cacheRead: sessionRow.cacheRead,
                                        cacheWrite: sessionRow.cacheWrite,
                                        reasoning: sessionRow.reasoning,
                                        firstSeen: sessionRow.startedAt,
                                        lastSeen: sessionRow.lastActivityAt ?? sessionRow.endedAt,
                                        bytesScanned: 0)
                append(row: row,
                       index: 0,
                       usageFamily: usageFamily,
                       events: &events,
                       slices: &slices)
            }
        }

        if unavailableReason != nil {
            events.removeAll(keepingCapacity: false)
            slices.removeAll(keepingCapacity: false)
        }
        if unavailableReason == nil, displayTotals.topLineTokens == nil {
            unavailableReason = "Hermes token totals exceed the supported integer range."
            events.removeAll(keepingCapacity: false)
            slices.removeAll(keepingCapacity: false)
        }
        let topLineTokens = unavailableReason == nil ? displayTotals.topLineTokens ?? 0 : 0
        let hasUsage = unavailableReason == nil && displayTotals.hasUsage
        let usageSummary: TelemetryUsageSummary? = if unavailableReason != nil {
            unavailableSummary(reason: unavailableReason, usageFamily: usageFamily)
        } else if hasUsage {
            TelemetryUsageSummary(topLineTokens: topLineTokens,
                                  hasComponentBreakdown: true,
                                  recordedTotalTokens: nil,
                                  usageFamilies: [usageFamily],
                                  usageFamilyConflict: false,
                                  displayTotalTokens: topLineTokens,
                                  unavailableReason: nil)
        } else {
            nil
        }

        let configuration = makeConfiguration(sessionRow: sessionRow,
                                              usageRows: mainLoopRows)
        let telemetry = SessionTelemetry(
            source: .hermes,
            initialConfiguration: configuration.initial,
            currentConfiguration: configuration.current,
            configurationChanges: configuration.changes,
            usageSlices: slices.values.sorted { ($0.model ?? "") < ($1.model ?? "") },
            usageEvents: events,
            usageSummary: usageSummary,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func makeScan(session: Session,
                                 sessionRow: SessionRow,
                                 usageRows: [ModelUsageRow],
                                 events: [TelemetryUsageEvent],
                                 slices: [String: TelemetryUsageSlice],
                                 usageSummary: TelemetryUsageSummary?,
                                 bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let configuration = makeConfiguration(sessionRow: sessionRow, usageRows: usageRows)
        let telemetry = SessionTelemetry(source: .hermes,
                                         initialConfiguration: configuration.initial,
                                         currentConfiguration: configuration.current,
                                         configurationChanges: configuration.changes,
                                         usageSlices: slices.values.sorted { ($0.model ?? "") < ($1.model ?? "") },
                                         usageEvents: events,
                                         usageSummary: usageSummary,
                                         costEstimate: nil,
                                         weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func append(row: ModelUsageRow,
                               index: Int,
                               usageFamily: String,
                               events: inout [TelemetryUsageEvent],
                               slices: inout [String: TelemetryUsageSlice]) {
        guard row.input != 0 || row.output != 0 || row.cacheRead != 0 || row.cacheWrite != 0 else { return }
        let model = row.model.isEmpty ? nil : row.model
        events.append(TelemetryUsageEvent(
            recordID: row.rowID == 0 ? nil : "\(usageFamily).\(row.rowID)",
            observedAt: row.lastSeen ?? row.firstSeen,
            anchorLine: index,
            usageFamily: usageFamily,
            ownership: .session,
            model: model,
            reasoningEffort: nil,
            speed: speed,
            freshInputTokens: row.input,
            cacheReadTokens: row.cacheRead,
            cacheWrite5mTokens: row.cacheWrite,
            cacheWrite1hTokens: 0,
            outputTokens: row.output,
            reasoningOutputTokens: row.reasoning,
            contextInputTokens: UsageTotals.adding(row.input, row.cacheRead).flatMap {
                UsageTotals.adding($0, row.cacheWrite)
            }))

        var slice = slices[row.model] ?? TelemetryUsageSlice(model: model,
                                                              reasoningEffort: nil,
                                                              speed: speed)
        slice.freshInputTokens += row.input
        slice.cacheReadTokens += row.cacheRead
        slice.cacheWrite5mTokens += row.cacheWrite
        slice.outputTokens += row.output
        slice.reasoningOutputTokens += row.reasoning
        slices[row.model] = slice
    }

    private static func makeConfiguration(
        sessionRow: SessionRow,
        usageRows: [ModelUsageRow]
    ) -> (initial: SessionConfiguration?, current: SessionConfiguration?, changes: [ConfigurationChange]) {
        let ordered = usageRows.sorted {
            switch ($0.firstSeen, $1.firstSeen) {
            case (nil, nil):
                return $0.rowID < $1.rowID
            case (nil, _):
                return false
            case (_, nil):
                return true
            case (let lhs?, let rhs?):
                return (lhs, $0.rowID) < (rhs, $1.rowID)
            }
        }
        var first: SessionConfiguration?
        for (index, row) in ordered.enumerated() {
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let date = row.firstSeen else { continue }
            first = SessionConfiguration(model: model,
                                         reasoningEffort: nil,
                                         observedAt: date,
                                         anchorLine: index,
                                         provenance: .inferredFirstObservation,
                                         modelObservedAt: date,
                                         modelAnchorLine: index,
                                         modelProvenance: .inferredFirstObservation)
            break
        }

        let currentDate = sessionRow.lastActivityAt ?? sessionRow.endedAt ?? sessionRow.startedAt
        let currentReasoning = reasoningEffort(from: sessionRow.modelConfig)
        let current: SessionConfiguration? = if sessionRow.model != nil || currentReasoning != nil {
            SessionConfiguration(model: sessionRow.model,
                                 reasoningEffort: currentReasoning,
                                 observedAt: currentDate,
                                 anchorLine: ordered.count,
                                 provenance: .sessionMetadata,
                                 modelObservedAt: sessionRow.model == nil ? nil : currentDate,
                                 modelAnchorLine: sessionRow.model == nil ? nil : ordered.count,
                                 modelProvenance: sessionRow.model == nil ? nil : .sessionMetadata,
                                 reasoningEffortObservedAt: currentReasoning == nil ? nil : currentDate,
                                 reasoningEffortAnchorLine: currentReasoning == nil ? nil : ordered.count,
                                 reasoningEffortProvenance: currentReasoning == nil ? nil : .sessionMetadata)
        } else {
            nil
        }
        // `session_model_usage` is a per-model aggregate, not an ordered stream of
        // model changes. It can prove the first observed model, but it cannot prove
        // the immediately previous model after a session revisits one. Keep the
        // current metadata and first observation without inventing intermediate changes.
        return (first, current, [])
    }

    private static func reasoningEffort(from raw: String?) -> String? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let directKeys = ["reasoning_effort", "reasoningEffort", "thinking_level", "thinkingLevel", "effort"]
        for key in directKeys {
            if let value = string(object[key]) { return value }
        }
        for key in ["reasoning_config", "reasoningConfig"] {
            if let nested = object[key] as? [String: Any] {
                for nestedKey in ["effort", "level", "thinking_level"] {
                    if let value = string(nested[nestedKey]) { return value }
                }
            }
        }
        return nil
    }

    private static func matchesSessionAggregate(_ totals: UsageTotals, _ session: SessionRow) -> Bool {
        totals.input == session.input
            && totals.output == session.output
            && totals.cacheRead == session.cacheRead
            && totals.cacheWrite == session.cacheWrite
            && totals.reasoning == session.reasoning
    }

    private static func sessionHasUsage(_ row: SessionRow) -> Bool {
        row.input != 0 || row.output != 0 || row.cacheRead != 0 || row.cacheWrite != 0 || row.reasoning != 0
    }

    private static func unavailableSummary(reason: String?, usageFamily: String) -> TelemetryUsageSummary {
        TelemetryUsageSummary(topLineTokens: 0,
                              hasComponentBreakdown: false,
                              recordedTotalTokens: nil,
                              usageFamilies: [usageFamily],
                              usageFamilyConflict: false,
                              displayTotalTokens: nil,
                              unavailableReason: reason)
    }

    private static func cancelledScan(bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(source: .hermes,
                                         initialConfiguration: nil,
                                         currentConfiguration: nil,
                                         configurationChanges: [],
                                         usageSlices: [],
                                         usageEvents: [],
                                         usageSummary: nil,
                                         costEstimate: nil,
                                         weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func isSupportedSession(_ session: Session) -> Bool {
        session.source == .hermes
            && URL(fileURLWithPath: session.filePath).lastPathComponent == databaseName
            && !session.id.isEmpty
    }

    private static func openReadOnly(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func beginReadTransaction(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK
    }

    private static func rollbackReadTransaction(_ db: OpaquePointer?) {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }

    private static func querySession(db: OpaquePointer?, sessionID: String) -> SessionRow? {
        let sql = """
            SELECT model, model_config, started_at, ended_at, last_activity_at,
                   input_tokens, output_tokens, cache_read_tokens,
                   cache_write_tokens, reasoning_tokens
            FROM sessions WHERE id = ? LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard (2...4).allSatisfy({ validDateStorage(statement, index: Int32($0)) }),
              let model = textOrNull(statement, index: 0),
              let modelConfig = textOrNull(statement, index: 1) else { return nil }
        guard let input = integer(statement, index: 5),
              let output = integer(statement, index: 6),
              let cacheRead = integer(statement, index: 7),
              let cacheWrite = integer(statement, index: 8),
              let reasoning = integer(statement, index: 9) else { return nil }
        return SessionRow(
            model: model.value,
            modelConfig: modelConfig.value,
            startedAt: date(statement, index: 2),
            endedAt: date(statement, index: 3),
            lastActivityAt: date(statement, index: 4),
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning,
            bytesScanned: bytes(statement, indices: 0...9))
    }

    private static func queryModelUsage(db: OpaquePointer?, sessionID: String) -> ModelUsageQuery? {
        guard let tableExists = tablePresence(db, name: "session_model_usage") else {
            return nil
        }
        guard tableExists else {
            return ModelUsageQuery(tableExists: false, rows: [])
        }
        let sql = """
            SELECT rowid, model, task, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens, reasoning_tokens,
                   first_seen, last_seen
            FROM session_model_usage
            WHERE session_id = ?
            ORDER BY first_seen IS NULL, first_seen, rowid;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: sessionID)
        var rows: [ModelUsageRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard !Task.isCancelled else {
                return ModelUsageQuery(tableExists: true, rows: rows)
            }
            guard let model = textOrNull(statement, index: 1),
                  let task = textOrNull(statement, index: 2),
                  validDateStorage(statement, index: 8),
                  validDateStorage(statement, index: 9) else { return nil }
            guard let model = model.value,
                  let input = integer(statement, index: 3),
                  let output = integer(statement, index: 4),
                  let cacheRead = integer(statement, index: 5),
                  let cacheWrite = integer(statement, index: 6),
                  let reasoning = integer(statement, index: 7) else { return nil }
            rows.append(ModelUsageRow(
                rowID: sqlite3_column_int64(statement, 0),
                model: model,
                task: task.value,
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning,
                firstSeen: date(statement, index: 8),
                lastSeen: date(statement, index: 9),
                bytesScanned: bytes(statement, indices: 1...9)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return nil }
        return ModelUsageQuery(tableExists: true, rows: rows)
    }

    private static func checkedBytesScanned(sessionRow: SessionRow,
                                            usageRows: [ModelUsageRow]) -> UInt64? {
        var total = sessionRow.bytesScanned
        for row in usageRows {
            let (next, overflow) = total.addingReportingOverflow(row.bytesScanned)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func tablePresence(_ db: OpaquePointer?, name: String) -> Bool? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                                 "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
                                 -1,
                                 &statement,
                                 nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: name)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            return nil
        }
    }

    private static func bind(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private struct TextOrNull {
        let value: String?
    }

    private static func textOrNull(_ statement: OpaquePointer?, index: Int32) -> TextOrNull? {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_NULL || type == SQLITE_TEXT else { return nil }
        guard type == SQLITE_TEXT else { return TextOrNull(value: nil) }
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let byteCount = sqlite3_column_bytes(statement, index)
        guard byteCount >= 0 else { return nil }
        let data = Data(bytes: value, count: Int(byteCount))
        guard !data.contains(0),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let string = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextOrNull(value: string.isEmpty ? nil : string)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else { return nil }
        return Int(exactly: value)
    }

    private static func date(_ statement: OpaquePointer?, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, index)
        return value.isFinite && value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private static func validDateStorage(_ statement: OpaquePointer?, index: Int32) -> Bool {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_NULL || type == SQLITE_INTEGER || type == SQLITE_FLOAT else { return false }
        return type == SQLITE_NULL || sqlite3_column_double(statement, index).isFinite
    }

    private static func revisionDate(_ date: Date?) -> String {
        guard let date else { return "<null>" }
        return String(date.timeIntervalSince1970.bitPattern, radix: 16)
    }

    private static func feedOptional(_ label: String,
                                     _ value: String?,
                                     into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        guard let value else {
            hasher.update(data: Data([0]))
            return
        }
        hasher.update(data: Data([1]))
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }

    private static func bytes(_ statement: OpaquePointer?, indices: ClosedRange<Int32>) -> UInt64 {
        indices.reduce(0) { total, index in
            let count = max(0, sqlite3_column_bytes(statement, index))
            return total + UInt64(count)
        }
    }

    private static func feed(_ label: String, _ value: String, into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }
}
