import Foundation
import SQLite3
import CryptoKit

private struct OpenCodeTelemetryMessageRow {
    let id: String
    let observedAt: Date?
    let role: String?
    let model: String?
    let reasoningEffort: String?
    let object: [String: Any]
    let malformedPayload: Bool
    let bytesScanned: UInt64
}

private struct OpenCodeTelemetryPartRow {
    let id: String
    let messageID: String
    let observedAt: Date?
    let object: [String: Any]
    let malformedPayload: Bool
    let bytesScanned: UInt64
}

private struct OpenCodeTelemetryUsageRow {
    let id: String
    let observedAt: Date?
    /// Timestamp of the owning message, used for fork attribution. OpenCode
    /// may rewrite cloned part timestamps while copying fork history, so a
    /// step-finish part's own timestamp is not a safe attribution boundary.
    let attributionAt: Date?
    let model: String?
    let reasoningEffort: String?
    let tokens: [String: Any]
    let usageFamily: String
}

private struct OpenCodeTelemetryRows<Row> {
    let rows: [Row]
    let cancelled: Bool
    let malformedPayload: Bool
}

private struct OpenCodeTelemetrySessionMetadata {
    let hasModelColumn: Bool
    let model: String?
    let updatedAt: Date?
    let createdAt: Date?
    let parentID: String?
}

/// Read-only adapter for OpenCode's opencode.db SQLite database (v1.2+).
///
/// Opens the database per call using SQLITE_OPEN_READONLY to avoid WAL lock
/// contention with the running OpenCode process. No writes, no migrations.
struct OpenCodeSqliteReader {

    // MARK: - Session list (lightweight, no events)

    /// Returns all non-archived sessions ordered by time_updated descending.
    static func listSessions(customRoot: String?) -> [Session] {
        listSessionsIfReadable(customRoot: customRoot) ?? []
    }

    /// nil distinguishes an open/prepare/step failure from an authoritative empty list.
    static func listSessionsIfReadable(customRoot: String?) -> [Session]? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return querySessionList(db: db, dbPath: url.path)
    }

    // MARK: - Full session (with transcript events)

    /// Returns a Session with fully loaded events for the given session ID.
    static func loadFullSession(customRoot: String?, sessionID: String) -> Session? {
        let metricIdentity = SessionInfoMetricsIdentity(source: .opencode, sessionID: sessionID)
        SessionInfoMetrics.shared.beginTranscript(identity: metricIdentity)
        defer { SessionInfoMetrics.shared.endTranscript(identity: metricIdentity) }
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return queryFullSession(db: db, sessionID: sessionID, dbPath: url.path)
    }

    // MARK: - Freshness probe

    /// Returns the session's `time_updated` without loading any parts. Used to decide
    /// whether a hydrated transcript snapshot is stale while OpenCode is still writing.
    static func sessionUpdatedAt(customRoot: String?, sessionID: String) -> Date? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT time_updated FROM session WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let millis = sqlite3_column_int64(stmt, 0)
        return millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000.0) : nil
    }

    // MARK: - Telemetry backend

    /// Returns a logical revision for one SQLite session. The revision is
    /// intentionally independent of the database file's stat so committed WAL
    /// writes invalidate telemetry even when the main database file is unchanged.
    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard session.source == .opencode,
              URL(fileURLWithPath: session.filePath).lastPathComponent == "opencode.db" else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(session.filePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        guard let revision = logicalRevision(db: db, sessionID: session.id) else { return nil }
        return .logical(revision)
    }

    /// Scans only the selected session's SQLite rows. OpenCode's durable
    /// request-level usage lives in `step-finish` parts; message tokens are a
    /// compatibility fallback for older databases that have no usable parts.
    /// SQLite owns the storage format; the telemetry engine still owns cache,
    /// pricing, and publication policy.
    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        loadTelemetry(for: session, afterRowsLoaded: nil)
    }

    /// Test seam invoked after the selected message/part rows have been read
    /// and their byte count is known, but before usage/configuration reduction.
    /// Production callers use the overload above so this cannot affect normal
    /// telemetry behavior.
    static func loadTelemetry(
        for session: Session,
        afterRowsLoaded: (@Sendable () -> Void)?
    ) -> SessionTelemetryProviderScan? {
        guard session.source == .opencode,
              URL(fileURLWithPath: session.filePath).lastPathComponent == "opencode.db" else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(session.filePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        guard let metadata = queryTelemetrySessionMetadata(db: db, sessionID: session.id),
              let messageScan = queryTelemetryMessages(db: db, sessionID: session.id),
              let partScan = queryTelemetryParts(db: db, sessionID: session.id) else { return nil }
        let messages = messageScan.rows
        let parts = partScan.rows

        struct SliceKey: Hashable {
            let model: String?
            let reasoningEffort: String?
            let speed: String
        }

        let bytesScanned = messages.reduce(0) { $0 + $1.bytesScanned }
            + parts.reduce(0) { $0 + $1.bytesScanned }
        if messageScan.cancelled || partScan.cancelled {
            return cancelledTelemetryScan(bytesScanned: bytesScanned)
        }
        afterRowsLoaded?()
        let messageByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var stepFinishCount = 0
        var malformedStepFinish = false
        var stepUsage: [OpenCodeTelemetryUsageRow] = []
        for part in parts {
            guard let type = stringValue(part.object["type"]),
                  type.lowercased() == "step-finish" else { continue }
            stepFinishCount += 1
            guard let tokens = completeStepFinishTokenObject(from: part.object) else {
                malformedStepFinish = true
                continue
            }
            let message = messageByID[part.messageID]
            stepUsage.append(OpenCodeTelemetryUsageRow(
                id: part.id,
                observedAt: part.observedAt ?? message?.observedAt,
                attributionAt: message?.observedAt,
                model: modelID(from: part.object) ?? message?.model,
                reasoningEffort: reasoningEffort(from: part.object) ?? message?.reasoningEffort,
                tokens: tokens,
                usageFamily: "opencode.step-finish.tokens"))
        }
        let hasPartTable = tableExists(db, table: "part")
        let rawUsageRows: [OpenCodeTelemetryUsageRow]
        var usageUnavailableReason: String?
        if messageScan.malformedPayload || partScan.malformedPayload {
            // An undecodable row may hide a usage record, a message timestamp,
            // or configuration evidence. Do not present the readable subset as
            // a complete session total.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode telemetry is unavailable because one or more stored JSON records is malformed."
        } else if stepFinishCount > 0 && malformedStepFinish {
            // Never present the valid subset as the session total. One malformed
            // step-finish record means the provider's request-level accounting is
            // incomplete, even if neighboring records are readable.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode step-finish usage is incomplete because one or more records are malformed or missing required token components."
        } else if !stepUsage.isEmpty {
            rawUsageRows = stepUsage
        } else if !hasPartTable {
            // Pre-step-finish databases have no part table. Their assistant
            // message tokens are the only available usage evidence.
            rawUsageRows = messages.compactMap { message in
                guard message.role?.lowercased() == "assistant",
                      let tokens = tokenObject(from: message.object) else { return nil }
                return OpenCodeTelemetryUsageRow(
                    id: message.id,
                    observedAt: message.observedAt,
                    attributionAt: message.observedAt,
                    model: message.model,
                    reasoningEffort: message.reasoningEffort,
                    tokens: tokens,
                    usageFamily: "opencode.message.tokens")
            }
        } else {
            // A modern database has a part table, but without a usable
            // step-finish record there is no trustworthy request-level total.
            // Keep that distinction in the result instead of collapsing it into
            // the same empty state as a transcript that truly used no tokens.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode parts contain no usable step-finish usage record."
        }

        // OpenCode forks clone the parent's messages and parts into a new
        // session. Those rows are inherited history, not usage produced by
        // the fork. The fork path does not reliably populate parent_id, so the
        // session creation timestamp is the attribution boundary whenever the
        // schema provides it. If an explicitly parented schema cannot provide
        // that boundary, fail closed instead of presenting an inflated total.
        var usageRows = rawUsageRows
        if let forkBoundary = metadata.createdAt {
            usageRows = rawUsageRows.filter { row in
                guard let attributionAt = row.attributionAt else { return false }
                return attributionAt >= forkBoundary
            }
            if rawUsageRows.contains(where: { $0.attributionAt == nil }) {
                usageUnavailableReason = "Some OpenCode usage could not be attributed to this fork."
            }
        } else if metadata.parentID != nil {
            usageRows = []
            usageUnavailableReason = "OpenCode fork usage is unavailable because the session creation boundary is missing."
        }

        var changes: [ConfigurationChange] = []
        var initialConfiguration: SessionConfiguration?
        var effectiveModel: String?
        var effectiveReasoningEffort: String?
        var modelObservedAt: Date?
        var modelAnchorLine: Int?
        var reasoningObservedAt: Date?
        var reasoningAnchorLine: Int?

        func observeAssistantConfiguration(model: String?,
                                           reasoningEffort: String?,
                                           date: Date?,
                                           anchor: Int) {
            guard model != nil || reasoningEffort != nil else { return }
            let oldModel = effectiveModel
            let oldReasoning = effectiveReasoningEffort
            if let model, model != effectiveModel {
                if let oldModel {
                    changes.append(ConfigurationChange(
                        field: .model, oldValue: oldModel, newValue: model,
                        observedAt: date, anchorLine: anchor, provenance: .assistantRecord))
                }
                effectiveModel = model
                modelObservedAt = date
                modelAnchorLine = anchor
            }
            if let reasoningEffort, reasoningEffort != effectiveReasoningEffort {
                if let oldReasoning {
                    changes.append(ConfigurationChange(
                        field: .reasoningEffort, oldValue: oldReasoning,
                        newValue: reasoningEffort, observedAt: date,
                        anchorLine: anchor, provenance: .assistantRecord))
                }
                effectiveReasoningEffort = reasoningEffort
                reasoningObservedAt = date
                reasoningAnchorLine = anchor
            }
            let configuration = SessionConfiguration(
                model: effectiveModel,
                reasoningEffort: effectiveReasoningEffort,
                observedAt: date,
                anchorLine: anchor,
                provenance: .inferredFirstObservation,
                modelObservedAt: modelObservedAt,
                modelAnchorLine: modelAnchorLine,
                modelProvenance: effectiveModel == nil ? nil : .assistantRecord,
                reasoningEffortObservedAt: reasoningObservedAt,
                reasoningEffortAnchorLine: reasoningAnchorLine,
                reasoningEffortProvenance: effectiveReasoningEffort == nil ? nil : .assistantRecord)
            initialConfiguration = initialConfiguration ?? configuration
        }

        let configurationMessages: [OpenCodeTelemetryMessageRow]
        if messageScan.malformedPayload {
            // A readable suffix cannot establish the first observation or a
            // complete change history when an earlier message may be missing
            // its model or reasoning fields. Session metadata remains an
            // independent source for the current model below.
            configurationMessages = []
        } else if let forkBoundary = metadata.createdAt {
            configurationMessages = messages.filter { message in
                guard let observedAt = message.observedAt else { return false }
                return observedAt >= forkBoundary
            }
        } else if metadata.parentID != nil {
            // Usage already fails closed above when a fork has no creation
            // boundary. Configuration must not leak inherited model/effort
            // observations into the child either.
            configurationMessages = []
        } else {
            configurationMessages = messages
        }
        for (index, message) in configurationMessages.enumerated()
            where message.role?.lowercased() == "assistant" {
            observeAssistantConfiguration(
                model: message.model,
                reasoningEffort: message.reasoningEffort,
                date: message.observedAt,
                anchor: index)
        }

        // A current schema's model column is authoritative even when its value
        // is NULL or malformed. Old schemas have no such column and therefore
        // retain the last assistant observation as their best current evidence.
        let metadataModel = metadata.hasModelColumn ? metadata.model : nil
        if let metadataModel, let effectiveModel, metadataModel != effectiveModel {
            changes.append(ConfigurationChange(
                field: .model,
                oldValue: effectiveModel,
                newValue: metadataModel,
                observedAt: metadata.updatedAt,
                anchorLine: messages.count,
                provenance: .sessionMetadata))
        }
        let currentModel = metadata.hasModelColumn ? metadataModel : effectiveModel
        let currentFromMetadata = metadata.hasModelColumn
        let currentConfiguration: SessionConfiguration? = if currentModel != nil || effectiveReasoningEffort != nil {
            SessionConfiguration(
                model: currentModel,
                reasoningEffort: effectiveReasoningEffort,
                observedAt: currentFromMetadata ? metadata.updatedAt : (modelObservedAt ?? reasoningObservedAt),
                anchorLine: currentFromMetadata ? messages.count : max(messages.count - 1, 0),
                provenance: currentFromMetadata ? .sessionMetadata : .assistantRecord,
                modelObservedAt: currentFromMetadata ? metadata.updatedAt : modelObservedAt,
                modelAnchorLine: currentFromMetadata ? messages.count : modelAnchorLine,
                modelProvenance: currentModel == nil
                    ? nil
                    : (currentFromMetadata ? .sessionMetadata : .assistantRecord),
                reasoningEffortObservedAt: reasoningObservedAt,
                reasoningEffortAnchorLine: reasoningAnchorLine,
                reasoningEffortProvenance: effectiveReasoningEffort == nil ? nil : .assistantRecord)
        } else {
            nil
        }

        var events: [TelemetryUsageEvent] = []
        var slices: [SliceKey: TelemetryUsageSlice] = [:]
        var recordedTotalTokens = 0
        var hasRecordedTotal = false
        var displayTotalTokens = 0
        var hasDisplayTotal = false
        var hasComponentBreakdown = true
        var topLineTokens = 0
        for (index, row) in usageRows.enumerated() {
            guard !Task.isCancelled else {
                return cancelledTelemetryScan(bytesScanned: bytesScanned)
            }
            let tokens = row.tokens
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            guard let input = optionalNonNegativeInteger(tokens["input"]),
                  let cacheRead = optionalNonNegativeInteger(cache["read"] ?? tokens["cacheRead"]),
                  let cacheWrite = optionalNonNegativeInteger(cache["write"] ?? tokens["cacheWrite"]),
                  let storedOutput = optionalNonNegativeInteger(tokens["output"]),
                  let reasoning = optionalNonNegativeInteger(tokens["reasoning"]) else {
                usageUnavailableReason = "OpenCode usage is unavailable because a token component is malformed or out of range."
                break
            }
            // OpenCode stores output excluding reasoning; the common model stores
            // reasoning as a subset of output, so normalize before aggregation.
            guard let output = adding(storedOutput, reasoning),
                  let baseContextInput = adding(input, cacheRead),
                  let contextInput = adding(baseContextInput, cacheWrite),
                  let rowTopLineTokens = adding(contextInput, output) else {
                usageUnavailableReason = "OpenCode usage is unavailable because token totals exceed the supported integer range."
                break
            }
            guard let updatedTopLineTokens = adding(topLineTokens, rowTopLineTokens) else {
                usageUnavailableReason = "OpenCode usage is unavailable because aggregated token totals exceed the supported integer range."
                break
            }
            let total: Int?
            if let rawTotal = tokens["total"] {
                let parsedTotal: Int?
                if row.usageFamily == "opencode.step-finish.tokens" {
                    parsedTotal = nonNegativeJSONInteger(rawTotal)
                } else {
                    parsedTotal = optionalNonNegativeInteger(rawTotal)
                }
                guard let parsedTotal else {
                    usageUnavailableReason = "OpenCode usage is unavailable because a recorded total is malformed or out of range."
                    break
                }
                total = parsedTotal
            } else {
                total = nil
            }
            let hasComponents = tokens["input"] != nil
                || tokens["output"] != nil
                || tokens["reasoning"] != nil
                || cache["read"] != nil
                || cache["write"] != nil
                || tokens["cacheRead"] != nil
                || tokens["cacheWrite"] != nil
            let hasUsableComponents = hasComponents
                && !(rowTopLineTokens == 0 && (total ?? 0) > 0)
            hasComponentBreakdown = hasComponentBreakdown && hasUsableComponents
            if let total {
                guard let updatedRecordedTotal = adding(recordedTotalTokens, total) else {
                    usageUnavailableReason = "OpenCode usage is unavailable because recorded token totals exceed the supported integer range."
                    break
                }
                recordedTotalTokens = updatedRecordedTotal
                hasRecordedTotal = true
            }
            let rowDisplayTokens = total ?? rowTopLineTokens
            guard let updatedDisplayTotal = adding(displayTotalTokens, rowDisplayTokens) else {
                usageUnavailableReason = "OpenCode usage is unavailable because display token totals exceed the supported integer range."
                break
            }
            displayTotalTokens = updatedDisplayTotal
            hasDisplayTotal = true
            if !hasUsableComponents {
                // Preserve a provider-recorded total-only value for the summary,
                // but do not create a zero-valued request that can mask it in the
                // presentation layer or inflate activity counts.
                continue
            }

            let model = row.model ?? metadataModel
            let speed = "standard-normalized"
            events.append(TelemetryUsageEvent(
                recordID: row.id.isEmpty ? nil : row.id,
                observedAt: row.observedAt,
                anchorLine: index,
                usageFamily: row.usageFamily,
                ownership: .session,
                model: model,
                reasoningEffort: row.reasoningEffort,
                speed: speed,
                freshInputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                contextInputTokens: contextInput))

            let key = SliceKey(model: model, reasoningEffort: row.reasoningEffort, speed: speed)
            var slice = slices[key] ?? TelemetryUsageSlice(
                model: model, reasoningEffort: row.reasoningEffort, speed: speed)
            guard let freshInputTokens = adding(slice.freshInputTokens, input),
                  let cacheReadTokens = adding(slice.cacheReadTokens, cacheRead),
                  let cacheWriteTokens = adding(slice.cacheWrite5mTokens, cacheWrite),
                  let outputTokens = adding(slice.outputTokens, output),
                  let reasoningOutputTokens = adding(slice.reasoningOutputTokens, reasoning),
                  let sliceBaseContextInput = adding(freshInputTokens, cacheReadTokens),
                  let sliceContextInput = adding(sliceBaseContextInput, cacheWriteTokens),
                  adding(sliceContextInput, outputTokens) != nil else {
                usageUnavailableReason = "OpenCode usage is unavailable because aggregated token totals exceed the supported integer range."
                break
            }
            slice.freshInputTokens = freshInputTokens
            slice.cacheReadTokens = cacheReadTokens
            slice.cacheWrite5mTokens = cacheWriteTokens
            slice.outputTokens = outputTokens
            slice.reasoningOutputTokens = reasoningOutputTokens
            slices[key] = slice
            topLineTokens = updatedTopLineTokens
        }

        if usageUnavailableReason != nil {
            events.removeAll(keepingCapacity: false)
            slices.removeAll(keepingCapacity: false)
            topLineTokens = 0
            recordedTotalTokens = 0
            hasRecordedTotal = false
            displayTotalTokens = 0
            hasDisplayTotal = false
        }

        guard !Task.isCancelled else {
            return cancelledTelemetryScan(bytesScanned: bytesScanned)
        }
        let usageFamilies = Array(Set(usageRows.map(\.usageFamily))).sorted()
        let usageSummary: TelemetryUsageSummary?
        if events.isEmpty && usageUnavailableReason == nil && !hasRecordedTotal {
            usageSummary = nil
        } else {
            usageSummary = TelemetryUsageSummary(
                topLineTokens: topLineTokens,
                hasComponentBreakdown: usageUnavailableReason == nil && hasComponentBreakdown,
                recordedTotalTokens: usageUnavailableReason == nil && hasRecordedTotal
                    ? recordedTotalTokens : nil,
                usageFamilies: usageFamilies,
                usageFamilyConflict: false,
                displayTotalTokens: usageUnavailableReason == nil && hasDisplayTotal
                    ? displayTotalTokens : nil,
                unavailableReason: usageUnavailableReason)
        }
        let telemetry = SessionTelemetry(
            source: .opencode,
            initialConfiguration: initialConfiguration,
            currentConfiguration: currentConfiguration,
            configurationChanges: changes,
            usageSlices: slices.values.sorted { lhs, rhs in
                (lhs.model ?? "") == (rhs.model ?? "")
                    ? (lhs.reasoningEffort ?? "") < (rhs.reasoningEffort ?? "")
                    : (lhs.model ?? "") < (rhs.model ?? "")
            },
            usageEvents: events,
            usageSummary: usageSummary,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func modelID(from object: [String: Any]) -> String? {
        if let model = object["model"] as? [String: Any] {
            return stringValue(model["id"]) ?? stringValue(model["modelID"])
        }
        return stringValue(object["modelID"]) ?? stringValue(object["model"])
    }

    private static func reasoningEffort(from object: [String: Any]) -> String? {
        stringValue(object["variant"])
            ?? stringValue(object["reasoningEffort"])
            ?? stringValue(object["thinking"])
    }

    private static func tokenObject(from object: [String: Any]) -> [String: Any]? {
        if let tokens = object["tokens"] as? [String: Any] {
            return tokens
        }
        if let usage = object["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private static func completeStepFinishTokenObject(from object: [String: Any]) -> [String: Any]? {
        guard let tokens = tokenObject(from: object),
              nonNegativeJSONInteger(tokens["input"]) != nil,
              nonNegativeJSONInteger(tokens["output"]) != nil,
              nonNegativeJSONInteger(tokens["reasoning"]) != nil else { return nil }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        guard nonNegativeJSONInteger(cache["read"] ?? tokens["cacheRead"]) != nil,
              nonNegativeJSONInteger(cache["write"] ?? tokens["cacheWrite"]) != nil else { return nil }
        return tokens
    }

    /// JSONSerialization bridges numbers through NSNumber, including booleans.
    /// Accept only integral numeric encodings that are non-negative and fit in
    /// Swift's Int; strings, booleans, floats, and negative counts are not
    /// complete usage evidence.
    private static func nonNegativeJSONInteger(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber else {
            return nil
        }
        let type = String(cString: value.objCType)
        guard ["q", "Q", "i", "I", "s", "S", "l", "L"].contains(type) else {
            return nil
        }
        let integer = value.int64Value
        guard integer >= 0,
              NSNumber(value: integer).compare(value) == .orderedSame else {
            return nil
        }
        return Int(exactly: integer)
    }

    /// Legacy message-token records predate the strict step-finish schema and
    /// may omit individual fields. Missing fields remain zero, but a present
    /// value must still be an exact non-negative integer. Numeric strings are
    /// retained only for this compatibility path; modern step-finish records
    /// continue to require JSON NSNumber values above.
    private static func optionalNonNegativeInteger(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        if let integer = nonNegativeJSONInteger(value) {
            return integer
        }
        if let value = value as? String,
           let parsed = Int(value),
           parsed >= 0 {
            return parsed
        }
        return nil
    }

    private static func dateFromMillis(_ value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: Double(value) / 1000.0) : nil
    }

    private static func queryTelemetrySessionMetadata(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetrySessionMetadata? {
        let hasModelColumn = tableHasColumn(db, table: "session", column: "model")
        let hasCreatedColumn = tableHasColumn(db, table: "session", column: "time_created")
        let hasParentColumn = tableHasColumn(db, table: "session", column: "parent_id")
        var columns = ["time_updated"]
        if hasModelColumn { columns.append("model") }
        if hasCreatedColumn { columns.append("time_created") }
        if hasParentColumn { columns.append("parent_id") }
        let sql = "SELECT \(columns.joined(separator: ", ")) FROM session WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var columnIndex: Int32 = 1
        let modelIndex: Int32? = hasModelColumn ? columnIndex : nil
        if hasModelColumn { columnIndex += 1 }
        let createdIndex: Int32? = hasCreatedColumn ? columnIndex : nil
        if hasCreatedColumn { columnIndex += 1 }
        let parentIndex: Int32? = hasParentColumn ? columnIndex : nil
        let rawModel = modelIndex.flatMap { index in
            sqlite3_column_type(stmt, index) != SQLITE_NULL ? text(stmt, index) : nil
        }
        let createdAt = createdIndex.flatMap { dateFromMillis(sqlite3_column_int64(stmt, $0)) }
        let parentID = parentIndex.flatMap { index in
            sqlite3_column_type(stmt, index) != SQLITE_NULL ? stringValue(text(stmt, index)) : nil
        }
        return OpenCodeTelemetrySessionMetadata(
            hasModelColumn: hasModelColumn,
            model: rawModel.flatMap(currentModelID(from:)),
            updatedAt: dateFromMillis(sqlite3_column_int64(stmt, 0)),
            createdAt: createdAt,
            parentID: parentID)
    }

    private static func queryTelemetryMessages(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetryRows<OpenCodeTelemetryMessageRow>? {
        let sql = "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [OpenCodeTelemetryMessageRow] = []
        var step = sqlite3_step(stmt)
        var cancelled = false
        while step == SQLITE_ROW {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let dataString = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let object: [String: Any]
            let malformedPayload: Bool
            if let dataString,
               let data = dataString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
                malformedPayload = false
            } else {
                object = [:]
                malformedPayload = true
            }
            rows.append(OpenCodeTelemetryMessageRow(
                id: text(stmt, 0),
                observedAt: dateFromMillis(sqlite3_column_int64(stmt, 1))
                    ?? dateFromMillis(sqlite3_column_int64(stmt, 2)),
                role: stringValue(object["role"]),
                model: modelID(from: object),
                reasoningEffort: reasoningEffort(from: object),
                object: object,
                malformedPayload: malformedPayload,
                bytesScanned: payloadByteCount(stmt, column: 3)))
            step = sqlite3_step(stmt)
        }
        guard cancelled || step == SQLITE_DONE else { return nil }
        return OpenCodeTelemetryRows(
            rows: rows,
            cancelled: cancelled,
            malformedPayload: rows.contains(where: \.malformedPayload))
    }

    private static func queryTelemetryParts(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetryRows<OpenCodeTelemetryPartRow>? {
        guard tableExists(db, table: "part") else {
            return OpenCodeTelemetryRows(rows: [], cancelled: false, malformedPayload: false)
        }
        let sql = "SELECT id, message_id, time_created, time_updated, data FROM part WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [OpenCodeTelemetryPartRow] = []
        var step = sqlite3_step(stmt)
        var cancelled = false
        while step == SQLITE_ROW {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let dataString = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let object: [String: Any]
            let malformedPayload: Bool
            if let dataString,
               let data = dataString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
                malformedPayload = false
            } else {
                object = [:]
                malformedPayload = true
            }
            rows.append(OpenCodeTelemetryPartRow(
                id: text(stmt, 0),
                messageID: text(stmt, 1),
                observedAt: dateFromMillis(sqlite3_column_int64(stmt, 2))
                    ?? dateFromMillis(sqlite3_column_int64(stmt, 3)),
                object: object,
                malformedPayload: malformedPayload,
                bytesScanned: payloadByteCount(stmt, column: 4)))
            step = sqlite3_step(stmt)
        }
        guard cancelled || step == SQLITE_DONE else { return nil }
        return OpenCodeTelemetryRows(
            rows: rows,
            cancelled: cancelled,
            malformedPayload: rows.contains(where: \.malformedPayload))
    }

    private static func payloadByteCount(_ stmt: OpaquePointer?, column: Int32) -> UInt64 {
        UInt64(max(Int32(0), sqlite3_column_bytes(stmt, column)))
    }

    private static func cancelledTelemetryScan(bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .opencode,
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

    private static func beginReadTransaction(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK
    }

    private static func rollbackReadTransaction(_ db: OpaquePointer?) {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }

    private static func logicalRevision(db: OpaquePointer?, sessionID: String) -> String? {
        guard tableExists(db, table: "message") else { return nil }
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        let hasCreated = tableHasColumn(db, table: "session", column: "time_created")
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        var sessionColumns = ["time_updated"]
        if hasModel { sessionColumns.append("model") }
        if hasCreated { sessionColumns.append("time_created") }
        if hasParent { sessionColumns.append("parent_id") }
        let sessionSQL = "SELECT \(sessionColumns.joined(separator: ", ")) FROM session WHERE id = ? LIMIT 1;"
        var sessionStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionSQL, -1, &sessionStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(sessionStmt) }
        sqlite3_bind_text(sessionStmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sessionStmt) == SQLITE_ROW else { return nil }
        let sessionUpdated = sqlite3_column_int64(sessionStmt, 0)
        var sessionIndex: Int32 = 1
        let modelIndex: Int32? = hasModel ? sessionIndex : nil
        if hasModel { sessionIndex += 1 }
        let createdIndex: Int32? = hasCreated ? sessionIndex : nil
        if hasCreated { sessionIndex += 1 }
        let parentIndex: Int32? = hasParent ? sessionIndex : nil
        let modelRaw = modelIndex.flatMap { index in
            sqlite3_column_type(sessionStmt, index) != SQLITE_NULL
                ? text(sessionStmt, index)
                : nil
        }
        let sessionCreated = createdIndex.flatMap { sqlite3_column_int64(sessionStmt, $0) }
        let parentRaw = parentIndex.flatMap { index in
            sqlite3_column_type(sessionStmt, index) != SQLITE_NULL
                ? stringValue(text(sessionStmt, index))
                : nil
        }

        var hasher = SHA256()
        feedDigest("session.id", value: sessionID, into: &hasher)
        feedDigest("session.time_updated", value: String(sessionUpdated), into: &hasher)
        feedDigest("session.model", value: hasModel ? (modelRaw ?? "<null>") : "<absent>", into: &hasher)
        feedDigest("session.time_created", value: hasCreated ? String(sessionCreated ?? 0) : "<absent>", into: &hasher)
        feedDigest("session.parent_id", value: hasParent ? (parentRaw ?? "<null>") : "<absent>", into: &hasher)

        let messageSQL = "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var messageStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, messageSQL, -1, &messageStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(messageStmt) }
        sqlite3_bind_text(messageStmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var step = sqlite3_step(messageStmt)
        while step == SQLITE_ROW {
            guard !Task.isCancelled else { return nil }
            feedDigest("message.id", value: text(messageStmt, 0), into: &hasher)
            feedDigest("message.time_created", value: String(sqlite3_column_int64(messageStmt, 1)), into: &hasher)
            feedDigest("message.time_updated", value: String(sqlite3_column_int64(messageStmt, 2)), into: &hasher)
            feedDigest("message.data", value: text(messageStmt, 3), into: &hasher)
            step = sqlite3_step(messageStmt)
        }
        guard step == SQLITE_DONE else { return nil }

        if tableExists(db, table: "part") {
            let partSQL = "SELECT id, message_id, time_created, time_updated, data FROM part WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
            var partStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, partSQL, -1, &partStmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(partStmt) }
            sqlite3_bind_text(partStmt, 1, (sessionID as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            step = sqlite3_step(partStmt)
            while step == SQLITE_ROW {
                guard !Task.isCancelled else { return nil }
                feedDigest("part.id", value: text(partStmt, 0), into: &hasher)
                feedDigest("part.message_id", value: text(partStmt, 1), into: &hasher)
                feedDigest("part.time_created", value: String(sqlite3_column_int64(partStmt, 2)), into: &hasher)
                feedDigest("part.time_updated", value: String(sqlite3_column_int64(partStmt, 3)), into: &hasher)
                feedDigest("part.data", value: text(partStmt, 4), into: &hasher)
                step = sqlite3_step(partStmt)
            }
            guard step == SQLITE_DONE else { return nil }
        } else {
            feedDigest("part.table", value: "<absent>", into: &hasher)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func feedDigest(_ label: String,
                                   value: String,
                                   into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }

    private static func tableExists(_ db: OpaquePointer?, table: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            -1,
            &stmt,
            nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Internal query helpers

    private static func querySessionList(db: OpaquePointer?, dbPath: String) -> [Session]? {
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        // OpenCode 1.2+ stores the effective session model as JSON on the
        // session row. That is the authoritative current value for the quick
        // surface; falling back to message metadata is only for older schemas.
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        var columns = ["id", "title", "directory", "time_created", "time_updated"]
        if hasParent { columns.append("parent_id") }
        if hasModel { columns.append("model") }
        let sql = "SELECT " + columns.joined(separator: ", ")
            + " FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let id = text(stmt, 0)
            if id.isEmpty {
                step = sqlite3_step(stmt)
                continue
            }
            let title = text(stmt, 1)
            let directory = text(stmt, 2)
            let timeCreated = sqlite3_column_int64(stmt, 3)
            let timeUpdated = sqlite3_column_int64(stmt, 4)
            let parentIndex: Int32? = hasParent ? 5 : nil
            let modelIndex: Int32? = hasModel ? (hasParent ? 6 : 5) : nil
            let parentID: String? = if let parentIndex,
                                        sqlite3_column_type(stmt, parentIndex) != SQLITE_NULL {
                text(stmt, parentIndex)
            } else {
                nil
            }
            let storedModelID = modelIndex.flatMap { index in
                sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : currentModelID(from: text(stmt, index))
            }

            let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
            let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil

            let storedTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
            let generatedDefaultTitle = OpenCodeSessionParser.isGeneratedDefaultSessionTitle(storedTitle)
            // Fetch message count and first model in a separate quick query. Only
            // timestamp-default rows also inspect their first user text part.
            let (msgCount, modelID, firstUserTitle) = lightweightMessageMeta(
                db: db,
                sessionID: id,
                includeFirstUserTitle: generatedDefaultTitle,
                needsLegacyModelLookup: !hasModel
            )
            // A present session.model column is authoritative even when its
            // value is null or malformed. Only schemas without that column
            // may fall back to message-derived model metadata.
            let currentModel = hasModel ? storedModelID : modelID
            let sessionTitle = OpenCodeSessionParser.effectiveSessionTitle(
                storedTitle: storedTitle,
                firstUserText: firstUserTitle
            )
            let customTitle = generatedDefaultTitle ? nil : storedTitle
            let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(storedTitle)
            sessions.append(Session(
                id: id,
                source: .opencode,
                startTime: startDate,
                endTime: endDate,
                model: currentModel,
                filePath: dbPath,
                fileSizeBytes: nil,
                eventCount: msgCount,
                events: [],
                cwd: directory.isEmpty ? nil : directory,
                repoName: nil,
                lightweightTitle: sessionTitle,
                lightweightCommands: nil,
                parentSessionID: parentID,
                subagentType: subagentType,
                customTitle: customTitle
            ))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        return sessions
    }

    private static func lightweightMessageMeta(
        db: OpaquePointer?,
        sessionID: String,
        includeFirstUserTitle: Bool,
        needsLegacyModelLookup: Bool
    ) -> (count: Int, modelID: String?, firstUserTitle: String?) {
        let orderedMessages = "ORDER BY time_created IS NULL, time_created, id"
        let sql = "SELECT id, data FROM message WHERE session_id = ? \(orderedMessages) LIMIT 20;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, nil, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var count = 0
        var modelID: String?
        var firstUserMessageID: String?
        var firstUserSummary: String?
        func inspectCurrentMessage(_ statement: OpaquePointer?) {
            let messageID = text(statement, 0)
            guard let dataStr = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let data = dataStr.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                return
            }
            if let observedModel = msg.model?.modelID ?? msg.modelID,
               !observedModel.isEmpty {
                // The initial query is bounded for quick metadata. The
                // newest-first fallback below scans all messages when an old
                // schema has no session.model column.
                modelID = observedModel
            }
            if includeFirstUserTitle,
               firstUserMessageID == nil,
               msg.role?.lowercased() == "user" {
                firstUserMessageID = messageID
                firstUserSummary = OpenCodeSessionParser.preferredUserSummaryText(from: msg)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            count += 1
            inspectCurrentMessage(stmt)
        }
        if includeFirstUserTitle, firstUserMessageID == nil {
            let tailSQL = "SELECT id, data FROM message WHERE session_id = ? \(orderedMessages) LIMIT -1 OFFSET 20;"
            var tailStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, tailSQL, -1, &tailStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(tailStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                while sqlite3_step(tailStmt) == SQLITE_ROW, firstUserMessageID == nil {
                    inspectCurrentMessage(tailStmt)
                }
            }
            sqlite3_finalize(tailStmt)
        }
        // Get actual total count
        let countSQL = "SELECT COUNT(*) FROM message WHERE session_id = ?;"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(countStmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }
        var firstUserTitle: String?
        if let firstUserMessageID {
            firstUserTitle = loadPartDicts(db: db, messageID: firstUserMessageID)
                .compactMap { part -> String? in
                    guard (part.dict["type"] as? String)?.lowercased() == "text" else { return nil }
                    guard let text = part.dict["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return text
                }
                .first
            if firstUserTitle == nil {
                firstUserTitle = firstUserSummary
            }
        }
        if needsLegacyModelLookup,
           let latestModel = latestMessageModelID(db: db, sessionID: sessionID) {
            modelID = latestModel
        }
        return (count, modelID, firstUserTitle)
    }

    /// Older OpenCode SQLite schemas do not have the session-level model JSON.
    /// Scan newest-first until the first model-bearing message so a model
    /// switch beyond the quick metadata probe is still represented correctly.
    private static func latestMessageModelID(db: OpaquePointer?, sessionID: String) -> String? {
        let sql = "SELECT data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created DESC, id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dataString = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let data = dataString.data(using: .utf8),
                  let message = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data),
                  let model = message.model?.modelID ?? message.modelID,
                  !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    private static func queryFullSession(db: OpaquePointer?, sessionID: String, dbPath: String) -> Session? {
        // 1. Session metadata
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        var sessionColumns = ["id", "title", "directory", "time_created", "time_updated"]
        if hasParent { sessionColumns.append("parent_id") }
        if hasModel { sessionColumns.append("model") }
        let sesSQL = "SELECT " + sessionColumns.joined(separator: ", ")
            + " FROM session WHERE id = ? LIMIT 1;"
        var sesStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sesSQL, -1, &sesStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(sesStmt) }
        sqlite3_bind_text(sesStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sesStmt) == SQLITE_ROW else { return nil }

        let id = text(sesStmt, 0)
        let title = text(sesStmt, 1)
        let directory = text(sesStmt, 2)
        let timeCreated = sqlite3_column_int64(sesStmt, 3)
        let timeUpdated = sqlite3_column_int64(sesStmt, 4)
        let parentIndex: Int32? = hasParent ? 5 : nil
        let modelIndex: Int32? = hasModel ? (hasParent ? 6 : 5) : nil
        let parentID: String? = if let parentIndex,
                                    sqlite3_column_type(sesStmt, parentIndex) != SQLITE_NULL {
            text(sesStmt, parentIndex)
        } else {
            nil
        }
        let storedModelID = modelIndex.flatMap { index in
            sqlite3_column_type(sesStmt, index) == SQLITE_NULL ? nil : currentModelID(from: text(sesStmt, index))
        }
        let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
        let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil

        // 2. Load all messages ordered by time_created
        let msgSQL = "SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var msgStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, msgSQL, -1, &msgStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(msgStmt) }
        sqlite3_bind_text(msgStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var events: [SessionEvent] = []
        var modelID: String? = storedModelID
        var commandCount = 0

        while sqlite3_step(msgStmt) == SQLITE_ROW {
            let msgID = text(msgStmt, 0)
            let msgTimeMs = sqlite3_column_int64(msgStmt, 1)
            guard let dataStr = sqlite3_column_text(msgStmt, 2).map({ String(cString: $0) }) else { continue }
            let rawJSON = dataStr

            guard let data = dataStr.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                continue
            }

            let ts = msgTimeMs > 0 ? Date(timeIntervalSince1970: Double(msgTimeMs) / 1000.0) : nil
            if !hasModel,
               let mid = msg.model?.modelID ?? msg.modelID, !mid.isEmpty {
                // Messages are oldest-first. This is the fallback current
                // model for pre-1.2 schemas without session.model.
                modelID = mid
            }

            // 3. Load parts for this message
            let partDicts = loadPartDicts(db: db, messageID: msgID)
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }

            let partEvents = OpenCodeSessionParser.buildPartEvents(
                for: msg,
                effectiveMsgID: msgID,
                parts: partDicts,
                fallbackTimestamp: ts
            )
            commandCount += partEvents.tool.filter { $0.kind == .tool_call }.count

            // Meta event for the raw message
            let messageMetaEvent = SessionEvent(
                id: msgID + "-meta",
                timestamp: ts,
                kind: .meta,
                role: msg.role,
                text: nil,
                toolName: nil,
                toolInput: nil,
                toolOutput: nil,
                messageID: msgID,
                parentID: nil,
                isDelta: false,
                rawJSON: rawJSON
            )
            events.append(messageMetaEvent)

            if !partEvents.text.isEmpty {
                events.append(contentsOf: partEvents.text)
            } else {
                // Fallback: render from message summary fields
                let baseKind = SessionEventKind.from(role: msg.role, type: nil)
                let normalizedRole = msg.role?.lowercased()
                var text: String?
                if normalizedRole == "user" {
                    text = msg.summary?.title
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        text = msg.summary?.body
                    }
                } else {
                    text = msg.summary?.body
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                       let t = msg.summary?.title, !t.isEmpty {
                        text = t
                    }
                }
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isUser = normalizedRole == "user"
                let hasToolParts = !partEvents.tool.isEmpty
                if trimmed.isEmpty && (hasTools || hasToolParts) && !isUser {
                    // no-op: tool-call wrapper with no display text
                } else if trimmed.isEmpty && !isUser {
                    // Drop completely empty non-user messages to avoid blank rows.
                } else {
                    events.append(SessionEvent(
                        id: msgID,
                        timestamp: ts,
                        kind: baseKind,
                        role: msg.role,
                        text: text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: msgID,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    ))
                }
            }
            events.append(contentsOf: partEvents.tool)
            events.append(contentsOf: partEvents.meta)
        }

        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let storedTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
        let generatedDefaultTitle = OpenCodeSessionParser.isGeneratedDefaultSessionTitle(storedTitle)
        let firstUserTitle = events.first(where: { $0.kind == .user })?.text
        let sessionTitle = OpenCodeSessionParser.effectiveSessionTitle(
            storedTitle: storedTitle,
            firstUserText: firstUserTitle
        )
        let customTitle = generatedDefaultTitle ? nil : storedTitle
        let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(storedTitle)
        return Session(
            id: id,
            source: .opencode,
            startTime: startDate,
            endTime: endDate,
            model: modelID,
            filePath: dbPath,
            fileSizeBytes: nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: directory.isEmpty ? nil : directory,
            repoName: nil,
            lightweightTitle: sessionTitle,
            lightweightCommands: commandCount > 0 ? commandCount : nil,
            parentSessionID: parentID,
            subagentType: subagentType,
            customTitle: customTitle
        )
    }

    private static func loadPartDicts(db: OpaquePointer?, messageID: String) -> [(id: String, dict: [String: Any], rawJSON: String)] {
        let sql = "SELECT id, data FROM part WHERE message_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(id: String, dict: [String: Any], rawJSON: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let partID = text(stmt, 0)
            guard let dataStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawJSON = OpenCodeSessionParser.cappedPartJSON(obj: obj, source: dataStr.data(using: .utf8))
            results.append((id: partID, dict: obj, rawJSON: rawJSON))
        }
        return results
    }

    // MARK: - SQLite helpers

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private static func tableHasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), name == column {
                return true
            }
        }
        return false
    }

    /// Session.model is a JSON object in current OpenCode databases. Keep this
    /// parser tolerant of older scalar forms so the quick value remains a
    /// current-model fact rather than being relabelled first-observed.
    private static func currentModelID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                for key in ["id", "modelID", "model"] {
                    if let value = dictionary[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                    if let nested = dictionary[key] as? [String: Any],
                       let value = nested["id"] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
                // A JSON object with no recognized model field is not a model
                // name. Do not render the entire blob as user-facing text.
                return nil
            }
            if let scalar = object as? String {
                let value = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            return nil
        }
        // Preserve legacy unquoted scalar model IDs, but do not surface a
        // malformed JSON object/array/string as if it were a model name.
        if let first = trimmed.first, ["{", "[", "\""].contains(String(first)) {
            return nil
        }
        return trimmed
    }
}
