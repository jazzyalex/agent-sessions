import Foundation

/// Registry-owned telemetry reader for Cursor's two non-ACP storage surfaces.
///
/// Cursor Agent JSONL records conversation content and tool calls, but the
/// audited format does not record model, effort, token, or cost fields. Cursor's
/// chat store can expose a `lastUsedModel` value, and the indexer already folds
/// that value into `Session.model`. This reader deliberately treats that value
/// as current session metadata: it is not a first-observed model and it does
/// not imply a historical configuration timeline.
enum CursorTelemetryReader {
    private static let revisionPrefix = "cursor-telemetry-v1"
    private static let unavailableTokensReason =
        "Cursor Agent transcript JSONL and chat metadata do not record attributable token components."

#if DEBUG
    /// Test-only seam for an A -> B -> A replacement around the metadata read.
    /// Production telemetry never mutates or replaces Cursor storage.
    static var testBeforeMetadataReadHook: (() -> Void)?
    static var testAfterMetadataReadHook: (() -> Void)?
#endif

    static func isSupportedSession(_ session: Session) -> Bool {
        guard session.source == .cursor, !session.filePath.isEmpty else { return false }
        let url = URL(fileURLWithPath: session.filePath)
        if url.pathExtension.lowercased() == "jsonl" { return true }
        return isMetadataStoreURL(url) && !isACPStorePath(url)
    }

    /// Resolve the per-session chat metadata store for a transcript when the
    /// transcript's project path can be matched to Cursor's chats layout.
    /// Exposed internally so tests can pin the path pairing without duplicating
    /// the storage-boundary logic.
    static func metadataStoreURL(for session: Session) -> URL? {
        guard session.source == .cursor, !session.filePath.isEmpty else { return nil }
        let fileURL = URL(fileURLWithPath: session.filePath)
        if isMetadataStoreURL(fileURL) {
            return isACPStorePath(fileURL) ? nil : fileURL
        }
        guard fileURL.pathExtension.lowercased() == "jsonl",
              let cursorRoot = cursorRoot(forTranscript: fileURL),
              let cwd = normalized(session.cwd)
                ?? CursorSessionParser.inferCWDBestEffort(from: fileURL),
              let sessionID = normalized(session.id) else {
            return nil
        }
        let workspaceHash = CursorChatMetaReader.md5String(cwd)
        return cursorRoot
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("store.db", isDirectory: false)
    }

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard isSupportedSession(session),
              let primaryStat = SessionFileStat.precise(from: URL(fileURLWithPath: session.filePath)) else {
            return nil
        }

        let metadataURL = metadataStoreURL(for: session)
        let metadata = metadataURL.flatMap { CursorChatMetaReader.sessionMeta(dbPath: $0.path) }
        return revision(for: session,
                        primaryStat: primaryStat,
                        metadataURL: metadataURL,
                        metadata: metadata)
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard isSupportedSession(session), !Task.isCancelled,
              let primaryStat = SessionFileStat.precise(from: URL(fileURLWithPath: session.filePath)) else {
            return nil
        }

        let metadataURL = metadataStoreURL(for: session)
#if DEBUG
        testBeforeMetadataReadHook?()
#endif
        let metadata = metadataURL.flatMap { CursorChatMetaReader.sessionMeta(dbPath: $0.path) }
#if DEBUG
        testAfterMetadataReadHook?()
#endif
        guard !Task.isCancelled else { return nil }
        if let metadata, metadata.agentId != session.id {
            return nil
        }

        // The scan revision includes the digest returned by the exact SQLite
        // read above. If the pathname was swapped A -> B -> A while SQLite was
        // open, the engine can reject the B digest instead of publishing it
        // under A's file stat.
        let inputRevision = revision(for: session,
                                     primaryStat: primaryStat,
                                     metadataURL: metadataURL,
                                     metadata: metadata)

        let model = normalized(session.model)
            ?? metadata.flatMap { normalized($0.lastUsedModel) }
        let currentConfiguration = model.map {
            SessionConfiguration(model: $0,
                                 reasoningEffort: nil,
                                 observedAt: nil,
                                 anchorLine: -1,
                                 provenance: .sessionMetadata)
        }
        let telemetry = SessionTelemetry(
            source: .cursor,
            initialConfiguration: nil,
            currentConfiguration: currentConfiguration,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: unavailableTokensReason),
            costEstimate: nil)

        let bytesScanned = metadata.map(\.metadataBytes) ?? 0
        guard let finalRevision = telemetryRevision(for: session) else { return nil }
        guard finalRevision == inputRevision else {
            return SessionTelemetryProviderScan(
                result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                       durableAccountHash: nil),
                bytesScanned: bytesScanned,
                inputRevision: inputRevision,
                revisionChanged: true)
        }

        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                   durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }

    private static func cursorRoot(forTranscript url: URL) -> URL? {
        let components = url.pathComponents
        guard let projectsIndex = components.lastIndex(of: "projects"), projectsIndex > 0 else {
            return nil
        }

        var root = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst().prefix(projectsIndex - 1) {
            root.appendPathComponent(component, isDirectory: true)
        }
        return root
    }

    private static func isMetadataStoreURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "store.db" || name.hasSuffix("-store.db")
    }

    private static func revision(for session: Session,
                                 primaryStat: SessionFileStat,
                                 metadataURL: URL?,
                                 metadata: CursorSessionMeta?) -> SessionTelemetryRevision {
        .logical([
            revisionPrefix,
            session.id,
            session.filePath,
            statIdentity(primaryStat),
            "model=\(normalized(session.model) ?? "none")",
            "metadataPath=\(metadataURL?.path ?? "none")",
            "metadata=\(metadata?.metadataFingerprint ?? "unavailable")"
        ].joined(separator: "|"))
    }

    private static func isACPStorePath(_ url: URL) -> Bool {
        if CursorACPStoreReader.isACPStore(url) { return true }

        let components = url.pathComponents
        guard url.lastPathComponent.lowercased() == "store.db" else { return false }
        if let index = components.lastIndex(of: "acp-sessions"),
           index + 2 == components.count - 1,
           UUID(uuidString: components[index + 1]) != nil {
            return true
        }

        guard components.count >= 5,
              components[components.count - 2] == "data",
              components[components.count - 3] == "cursor",
              components[components.count - 4].hasPrefix("cursor-acp-") else {
            return false
        }
        let rawID = String(components[components.count - 4].dropFirst("cursor-acp-".count))
        return UUID(uuidString: rawID) != nil
    }

    private static func statIdentity(_ stat: SessionFileStat) -> String {
        [String(stat.mtime), String(stat.size), stat.fingerprint ?? "", String(stat.changeTime ?? 0)]
            .joined(separator: ":")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "default" else { return nil }
        return trimmed
    }
}
