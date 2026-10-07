import Foundation
import CryptoKit
import SQLite3

/// Reads the audited session-level configuration from Devin's shared SQLite store.
///
/// Devin's `sessions` row exposes the current model and agent mode, but the audited
/// store does not expose trustworthy per-message token components, model-change
/// records, or a usable pricing identity. Keep this reader deliberately narrow: it
/// supplies current model provenance through the registry and leaves token, cost,
/// and quota dimensions unavailable rather than guessing from context cursors.
struct DevinTelemetryReader {
    private static let busyTimeoutMilliseconds: Int32 = 2_000
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct SessionRow {
        let model: String?
        let agentMode: String?
        let createdAt: Int64?
        let lastActivityAt: Int64?
        let mainChainID: Int64?
        let bytesScanned: UInt64
    }

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard isSupported(session),
              let row = readSessionRow(databasePath: session.filePath, sessionID: session.id) else {
            return nil
        }
        return .logical(revision(for: session, row: row))
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard isSupported(session), !Task.isCancelled,
              let row = readSessionRow(databasePath: session.filePath, sessionID: session.id) else {
            return nil
        }
        guard !Task.isCancelled else {
            return cancelledScan(bytesScanned: row.bytesScanned,
                                 inputRevision: .logical(revision(for: session, row: row)))
        }

        let model = clean(row.model) ?? clean(session.model)
        let currentConfiguration: SessionConfiguration? = model.map {
            SessionConfiguration(
                unanchoredModel: $0,
                reasoningEffort: nil,
                observedAt: nil,
                anchorLine: nil,
                provenance: .sessionMetadata,
                reasoningEffortObservedAt: nil,
                reasoningEffortAnchorLine: nil,
                reasoningEffortProvenance: nil)
        }
        let telemetry = SessionTelemetry(
            source: .devin,
            initialConfiguration: nil,
            currentConfiguration: currentConfiguration,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: nil,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        let inputRevision = SessionTelemetryRevision.logical(revision(for: session, row: row))
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: row.bytesScanned,
            inputRevision: inputRevision)
    }

    static func isSupported(_ session: Session) -> Bool {
        session.source == .devin
            && URL(fileURLWithPath: session.filePath).pathExtension.lowercased() == "db"
    }

    private static func open(_ databasePath: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        return db
    }

    private static func readSessionRow(databasePath: String, sessionID: String) -> SessionRow? {
        guard !Task.isCancelled,
              let db = open(databasePath) else {
            return nil
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }

        let sql = """
            SELECT model, agent_mode, created_at, last_activity_at, main_chain_id
            FROM sessions
            WHERE id = ?1
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, !Task.isCancelled else { return nil }

        guard let model = textValue(statement, index: 0),
              let agentMode = textValue(statement, index: 1),
              let createdAt = integerValue(statement, index: 2),
              let lastActivityAt = integerValue(statement, index: 3),
              let mainChainID = optionalIntegerValue(statement, index: 4) else {
            return nil
        }
        return SessionRow(
            model: clean(model.value),
            agentMode: clean(agentMode.value),
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            mainChainID: mainChainID,
            // This provider reads only the selected metadata columns. It does
            // not claim to have scanned the full SQLite database.
            bytesScanned: model.bytes + agentMode.bytes)
    }

    private static func textValue(_ statement: OpaquePointer?, index: Int32) -> (value: String?, bytes: UInt64)? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return (nil, 0)
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            let bytes = max(0, sqlite3_column_bytes(statement, index))
            return (String(cString: pointer), UInt64(bytes))
        default:
            return nil
        }
    }

    private static func integerValue(_ statement: OpaquePointer?, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private static func optionalIntegerValue(_ statement: OpaquePointer?, index: Int32) -> Int64?? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .some(nil)
        case SQLITE_INTEGER:
            return .some(sqlite3_column_int64(statement, index))
        default:
            return nil
        }
    }

    private static func revision(for session: Session, row: SessionRow) -> String {
        let sessionModel = clean(session.model) ?? "<session-model:nil>"
        let rowModel = row.model ?? "<row-model:nil>"
        let agentMode = row.agentMode ?? "<agent-mode:nil>"
        let createdAt = row.createdAt.map { String($0) } ?? "<created:nil>"
        let lastActivityAt = row.lastActivityAt.map { String($0) } ?? "<activity:nil>"
        let mainChainID = row.mainChainID.map { String($0) } ?? "<chain:nil>"
        let fields: [String] = [
            session.id,
            sessionModel,
            rowModel,
            agentMode,
            createdAt,
            lastActivityAt,
            mainChainID
        ]
        let payload = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(("devin:v1|" + payload).utf8))
        return "devin:v1:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cancelledScan(bytesScanned: UInt64,
                                      inputRevision: SessionTelemetryRevision) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .devin,
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
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }
}
