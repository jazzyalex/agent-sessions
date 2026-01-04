import Foundation
import CryptoKit
import SQLite3

enum SessionArchiveStatus: String, Codable {
    case none
    case staging
    case syncing
    case final
    case error
}

struct SessionArchiveInfo: Codable, Equatable {
    var sessionID: String
    var source: SessionSource

    var upstreamPath: String
    var upstreamIsDirectory: Bool
    var primaryRelativePath: String

    var pinnedAt: Date
    var lastSyncAt: Date?
    var lastUpstreamChangeAt: Date?
    var lastUpstreamSeenAt: Date?
    var upstreamMissing: Bool

    var status: SessionArchiveStatus
    var lastError: String?

    // For UI row/detail display without parsing.
    var startTime: Date?
    var endTime: Date?
    var model: String?
    var cwd: String?
    var title: String?
    var estimatedEventCount: Int?
    var estimatedCommands: Int?
    var archiveSizeBytes: Int64?
}

struct SessionArchiveManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var relativePath: String
        var sizeBytes: Int64
        var mtimeSeconds: TimeInterval
        var sha256: String?
    }

    var entries: [Entry]
}

final class SessionArchiveManager: ObservableObject, @unchecked Sendable {
    static let shared = SessionArchiveManager()

    @Published private(set) var infoByKey: [String: SessionArchiveInfo] = [:]

    private enum LogRotation {
        static let maxBytes: Int64 = 1_000_000 // ~1 MB
        static let backupsToKeep: Int = 2
    }

    private enum TempCleanup {
        static let minAgeSeconds: TimeInterval = 24 * 60 * 60 // 24h
    }

    // Pinning is a user action; keep the queue responsive.
    private let ioQueue = DispatchQueue(label: "AgentSessions.SessionArchiveManager.io", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var inFlightKeys: Set<String> = []
    private var missingResolutionLogged: Set<String> = []
    private var didLogArchivesRoot: Bool = false
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        // Eagerly warm cache for UI.
        ioQueue.async { [weak self] in
            self?.reloadCache()
            self?.cleanupOrphanedTempDirs()
        }
        startPeriodicSync()
    }

    func key(source: SessionSource, id: String) -> String { "\(source.rawValue):\(id)" }

    func info(source: SessionSource, id: String) -> SessionArchiveInfo? {
        infoByKey[key(source: source, id: id)]
    }

    func archiveFolderURL(source: SessionSource, id: String) -> URL? {
        let root = sessionRoot(source: source, id: id)
        // This action is user-initiated; prefer creating the folder so Finder can reveal it.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func archivesRootURL() -> URL {
        archivesRoot()
    }

    func pin(session: Session) {
        let k = key(source: session.source, id: session.id)
        // Update UI immediately, but move all file IO/logging off the main thread.
        let placeholder = SessionArchiveInfo(
            sessionID: session.id,
            source: session.source,
            upstreamPath: session.filePath,
            upstreamIsDirectory: false,
            primaryRelativePath: URL(fileURLWithPath: session.filePath).lastPathComponent,
            pinnedAt: Date(),
            lastSyncAt: nil,
            lastUpstreamChangeAt: nil,
            lastUpstreamSeenAt: nil,
            upstreamMissing: false,
            status: .staging,
            lastError: nil,
            startTime: session.startTime,
            endTime: session.endTime,
            model: session.model,
            cwd: session.cwd,
            title: session.title,
            estimatedEventCount: session.eventCount,
            estimatedCommands: session.lightweightCommands,
            archiveSizeBytes: nil
        )
        DispatchQueue.main.async { [weak self] in
            self?.infoByKey[k] = placeholder
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.inFlightKeys.contains(k) { return }
            self.inFlightKeys.insert(k)
            defer { self.inFlightKeys.remove(k) }

            self.logArchivesRootIfNeeded()
            self.log("pin requested source=\(session.source.rawValue) id=\(session.id) path=\(session.filePath)")
            self.writePinPlaceholder(session: session, key: k)
            self.ensureArchiveExistsAndSync(session: session, reason: "pin")
            self.reloadCache()
        }
    }

    func unstarred(source: SessionSource, id: String, removeArchive: Bool) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if removeArchive {
                self.deleteArchive(source: source, id: id)
            }
            self.reloadCache()
        }
    }

    func deleteArchiveNow(source: SessionSource, id: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.deleteArchive(source: source, id: id)
            self.reloadCache()
        }
    }

    func syncPinnedSessionsNow() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.syncPinnedSessions(reason: "manual")
            self.reloadCache()
        }
    }

    /// Merge archive-only placeholders for pinned sessions that are missing upstream.
    /// Must be called off the main thread.
    func mergePinnedArchiveFallbacks(into sessions: [Session], source: SessionSource) -> [Session] {
        let pinned = StarredSessionsStore().pinnedIDs(for: source)
        guard !pinned.isEmpty else { return sessions }

        let existing = Set(sessions.map(\.id))
        var out = sessions
        out.reserveCapacity(out.count + pinned.count)

        for id in pinned where !existing.contains(id) {
            guard let info = loadInfoIfExists(source: source, id: id) else { continue }
            let archivePath = archivedPrimaryPath(info: info).path
            guard FileManager.default.fileExists(atPath: archivePath) else { continue }

            let placeholder = Session(
                id: id,
                source: source,
                startTime: info.startTime,
                endTime: info.endTime,
                model: info.model,
                filePath: archivePath,
                fileSizeBytes: (info.archiveSizeBytes.map { Int($0) }),
                eventCount: info.estimatedEventCount ?? 0,
                events: [],
                cwd: info.cwd,
                repoName: nil,
                lightweightTitle: info.title,
                lightweightCommands: info.estimatedCommands
            )
            out.append(placeholder)
        }

        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Paths

    private func archivesRoot() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
    }

    private func sourceRoot(_ source: SessionSource) -> URL {
        archivesRoot().appendingPathComponent(source.rawValue, isDirectory: true)
    }

    private func sessionRoot(source: SessionSource, id: String) -> URL {
        sourceRoot(source).appendingPathComponent(id, isDirectory: true)
    }

    private func metaURL(source: SessionSource, id: String) -> URL {
        sessionRoot(source: source, id: id).appendingPathComponent("meta.json", isDirectory: false)
    }

    private func manifestURL(source: SessionSource, id: String) -> URL {
        sessionRoot(source: source, id: id).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func dataRootURL(source: SessionSource, id: String) -> URL {
        sessionRoot(source: source, id: id).appendingPathComponent("data", isDirectory: true)
    }

    private func archivedPrimaryPath(info: SessionArchiveInfo) -> URL {
        dataRootURL(source: info.source, id: info.sessionID).appendingPathComponent(info.primaryRelativePath, isDirectory: false)
    }

    // MARK: - Cache

    private func reloadCache() {
        let fm = FileManager.default
        let root = archivesRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var map: [String: SessionArchiveInfo] = [:]
        for source in SessionSource.allCases {
            let src = sourceRoot(source)
            guard let dirs = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for dir in dirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let id = dir.lastPathComponent
                let url = metaURL(source: source, id: id)
                guard let data = try? Data(contentsOf: url),
                      let info = try? JSONDecoder().decode(SessionArchiveInfo.self, from: data) else { continue }
                map[key(source: source, id: id)] = info
            }
        }

        DispatchQueue.main.async { self.infoByKey = map }
    }

    private func loadInfoIfExists(source: SessionSource, id: String) -> SessionArchiveInfo? {
        let url = metaURL(source: source, id: id)
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(SessionArchiveInfo.self, from: data) else { return nil }
        return info
    }

    private func writeInfo(_ info: SessionArchiveInfo) throws {
        let fm = FileManager.default
        let root = sessionRoot(source: info.source, id: info.sessionID)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(info)
        try data.write(to: metaURL(source: info.source, id: info.sessionID), options: [.atomic])
    }

    private func writeManifest(_ manifest: SessionArchiveManifest, source: SessionSource, id: String) throws {
        let fm = FileManager.default
        let root = sessionRoot(source: source, id: id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(source: source, id: id), options: [.atomic])
    }

    // MARK: - Sync

    private func startPeriodicSync() {
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now() + 8, repeating: .seconds(45), leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            self?.syncPinnedSessions(reason: "timer")
            self?.reloadCache()
        }
        t.resume()
        timer = t

        // Also do a small delayed initial pass.
        ioQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.syncPinnedSessions(reason: "startup")
            self?.reloadCache()
        }
    }

    private func syncPinnedSessions(reason: String) {
        let pinsEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        guard pinsEnabled else { return }
        let store = StarredSessionsStore()
        for source in SessionSource.allCases {
            let pinned = store.pinnedIDs(for: source)
            guard !pinned.isEmpty else { continue }
            var fallbackURLs: [String: URL]? = nil
            for id in pinned {
                if var info = loadInfoIfExists(source: source, id: id) {
                    ensureArchiveExistsAndSync(info: &info, reason: reason)
                    let key = key(source: source, id: id)
                    missingResolutionLogged.remove(key)
                    continue
                }

                // Backfill: older starred sessions won't have an archive folder yet.
                // If we can resolve their upstream path from IndexDB.session_meta, pin immediately.
                if let session = resolveSessionFromIndexDB(source: source, sessionID: id) {
                    ensureArchiveExistsAndSync(session: session, reason: reason)
                    continue
                }

                // Fallback: if the index DB doesn't have this session yet (or is missing/corrupt),
                // try resolving the upstream path directly from the filesystem.
                if fallbackURLs == nil {
                    fallbackURLs = resolveBackfillURLsFromFilesystem(source: source)
                }
                if let url = fallbackURLs?[id],
                   let session = resolveSessionForBackfill(source: source, sessionID: id, upstreamURL: url) {
                    log("pin backfill resolved via filesystem source=\(source.rawValue) id=\(id) path=\(url.path)")
                    ensureArchiveExistsAndSync(session: session, reason: reason)
                    continue
                }

                let key = key(source: source, id: id)
                if !missingResolutionLogged.contains(key) {
                    log("pin backfill failed source=\(source.rawValue) id=\(id) reason=missing_session_meta_and_upstream")
                    missingResolutionLogged.insert(key)
                }
            }
        }
    }

    private func resolveBackfillURLsFromFilesystem(source: SessionSource) -> [String: URL] {
        let defaults = UserDefaults.standard
        var map: [String: URL] = [:]

        switch source {
        case .copilot:
            let custom = defaults.string(forKey: PreferencesKey.Paths.copilotSessionsRootOverride)
            let discovery = CopilotSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
            for url in discovery.discoverSessionFiles() {
                let base = url.deletingPathExtension().lastPathComponent
                if !base.isEmpty { map[base] = url }
            }
        case .codex:
            let custom = defaults.string(forKey: "SessionsRootOverride")
            let discovery = CodexSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
            for url in discovery.discoverSessionFiles() {
                map[sha256Hex(url.path)] = url
            }
        case .claude:
            let custom = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
            let discovery = ClaudeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
            for url in discovery.discoverSessionFiles() {
                map[sha256Hex(url.path)] = url
            }
        case .gemini:
            let custom = defaults.string(forKey: "GeminiSessionsRootOverride")
            let discovery = GeminiSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
            for url in discovery.discoverSessionFiles() {
                map[sha256Hex(url.path)] = url
            }
        case .opencode:
            let custom = defaults.string(forKey: "OpenCodeSessionsRootOverride")
            let discovery = OpenCodeSessionDiscovery(customRoot: custom?.isEmpty == false ? custom : nil)
            for url in discovery.discoverSessionFiles() {
                let base = url.deletingPathExtension().lastPathComponent
                if base.isEmpty { continue }
                map[base] = url
                if base.hasPrefix("ses_") {
                    map[String(base.dropFirst("ses_".count))] = url
                }
            }
        case .droid:
            let sessionsCustom = defaults.string(forKey: PreferencesKey.Paths.droidSessionsRootOverride)
            let projectsCustom = defaults.string(forKey: PreferencesKey.Paths.droidProjectsRootOverride)
            let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsCustom?.isEmpty == false ? sessionsCustom : nil,
                                                 customProjectsRoot: projectsCustom?.isEmpty == false ? projectsCustom : nil)
            for url in discovery.discoverSessionFiles() {
                if let s = DroidSessionParser.parseFile(at: url), !s.id.isEmpty {
                    map[s.id] = url
                }
            }
        }

        return map
    }

    private func resolveSessionForBackfill(source: SessionSource, sessionID: String, upstreamURL: URL) -> Session? {
        switch source {
        case .copilot:
            return CopilotSessionParser.parseFile(at: upstreamURL, forcedID: sessionID) ?? minimalSession(source: source, id: sessionID, url: upstreamURL)
        case .claude:
            return ClaudeSessionParser.parseFile(at: upstreamURL) ?? minimalSession(source: source, id: sessionID, url: upstreamURL)
        case .gemini:
            return GeminiSessionParser.parseFile(at: upstreamURL, forcedID: sessionID) ?? minimalSession(source: source, id: sessionID, url: upstreamURL)
        case .opencode:
            return OpenCodeSessionParser.parseFile(at: upstreamURL) ?? minimalSession(source: source, id: sessionID, url: upstreamURL)
        case .codex:
            // SessionIndexer’s lightweight parsing helpers are currently private; for backfill we only need
            // a stable upstream path so the archive can be created. Metadata will be refreshed on later scans.
            return minimalSession(source: source, id: sessionID, url: upstreamURL)
        case .droid:
            return DroidSessionParser.parseFile(at: upstreamURL, forcedID: sessionID) ?? minimalSession(source: source, id: sessionID, url: upstreamURL)
        }
    }

    private func minimalSession(source: SessionSource, id: String, url: URL) -> Session {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        return Session(
            id: id,
            source: source,
            startTime: mtime,
            endTime: mtime,
            model: nil,
            filePath: url.path,
            fileSizeBytes: size,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: nil
        )
    }

    private func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func ensureArchiveExistsAndSync(session: Session, reason: String) {
        var info = SessionArchiveInfo(
            sessionID: session.id,
            source: session.source,
            upstreamPath: session.filePath,
            upstreamIsDirectory: isDirectory(path: session.filePath),
            primaryRelativePath: URL(fileURLWithPath: session.filePath).lastPathComponent,
            pinnedAt: Date(),
            lastSyncAt: nil,
            lastUpstreamChangeAt: nil,
            lastUpstreamSeenAt: nil,
            upstreamMissing: false,
            status: .staging,
            lastError: nil,
            startTime: session.startTime,
            endTime: session.endTime,
            model: session.model,
            cwd: session.cwd,
            title: session.title,
            estimatedEventCount: session.eventCount,
            estimatedCommands: session.lightweightCommands,
            archiveSizeBytes: nil
        )

        // If archive already exists, keep the existing pinnedAt and upstream path, but refresh display metadata.
        if var existing = loadInfoIfExists(source: session.source, id: session.id) {
            existing.startTime = info.startTime
            existing.endTime = info.endTime
            existing.model = info.model
            existing.cwd = info.cwd
            existing.title = info.title
            existing.estimatedEventCount = info.estimatedEventCount
            existing.estimatedCommands = info.estimatedCommands
            info = existing
        }

        ensureArchiveExistsAndSync(info: &info, reason: reason)
    }

    private func writePinPlaceholder(session: Session, key: String) {
        var info = SessionArchiveInfo(
            sessionID: session.id,
            source: session.source,
            upstreamPath: session.filePath,
            upstreamIsDirectory: isDirectory(path: session.filePath),
            primaryRelativePath: URL(fileURLWithPath: session.filePath).lastPathComponent,
            pinnedAt: Date(),
            lastSyncAt: nil,
            lastUpstreamChangeAt: nil,
            lastUpstreamSeenAt: nil,
            upstreamMissing: false,
            status: .staging,
            lastError: nil,
            startTime: session.startTime,
            endTime: session.endTime,
            model: session.model,
            cwd: session.cwd,
            title: session.title,
            estimatedEventCount: session.eventCount,
            estimatedCommands: session.lightweightCommands,
            archiveSizeBytes: nil
        )

        if var existing = loadInfoIfExists(source: session.source, id: session.id) {
            existing.upstreamPath = info.upstreamPath
            existing.upstreamIsDirectory = info.upstreamIsDirectory
            existing.primaryRelativePath = info.primaryRelativePath
            existing.status = .staging
            existing.lastError = nil

            existing.startTime = info.startTime
            existing.endTime = info.endTime
            existing.model = info.model
            existing.cwd = info.cwd
            existing.title = info.title
            existing.estimatedEventCount = info.estimatedEventCount
            existing.estimatedCommands = info.estimatedCommands
            info = existing
        }

        do {
            try writeInfo(info)
            log("pin placeholder written source=\(session.source.rawValue) id=\(session.id)")
            log("pin meta path=\(metaURL(source: session.source, id: session.id).path)")
            let metaExists = FileManager.default.fileExists(atPath: metaURL(source: session.source, id: session.id).path)
            log("pin meta exists=\(metaExists) source=\(session.source.rawValue) id=\(session.id)")
        } catch {
            info.status = .error
            info.lastError = "Failed to initialize archive: \(error.localizedDescription)"
            log("pin placeholder failed source=\(session.source.rawValue) id=\(session.id) error=\(error.localizedDescription)")
        }

        DispatchQueue.main.async { [weak self] in
            self?.infoByKey[key] = info
        }
    }

    private func resolveSessionFromIndexDB(source: SessionSource, sessionID: String) -> Session? {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbURL = appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("index.db", isDirectory: false)
        guard fm.fileExists(atPath: dbURL.path) else { return nil }

        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT path, start_ts, end_ts, model, cwd, title, messages, commands, size
        FROM session_meta
        WHERE session_id = ? AND source = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, source.rawValue, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cPath = sqlite3_column_text(stmt, 0) else { return nil }

        let path = String(cString: cPath)
        let startTS = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 1)
        let endTS = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 2)
        let model = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let cwd = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let title = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5))
        let messages = Int(sqlite3_column_int64(stmt, 6))
        let commands = Int(sqlite3_column_int64(stmt, 7))
        let size = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 8))

        let start = startTS > 0 ? Date(timeIntervalSince1970: TimeInterval(startTS)) : nil
        let end = endTS > 0 ? Date(timeIntervalSince1970: TimeInterval(endTS)) : nil

        return Session(
            id: sessionID,
            source: source,
            startTime: start,
            endTime: end,
            model: model,
            filePath: path,
            fileSizeBytes: size,
            eventCount: messages,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: title,
            lightweightCommands: commands
        )
    }

    private func ensureArchiveExistsAndSync(info: inout SessionArchiveInfo, reason: String) {
        do {
            log("sync start source=\(info.source.rawValue) id=\(info.sessionID) reason=\(reason)")
            try ensureSynced(info: &info, reason: reason)
            log("sync done source=\(info.source.rawValue) id=\(info.sessionID) status=\(info.status.rawValue)")
        } catch {
            info.status = .error
            info.lastError = error.localizedDescription
            try? writeInfo(info)
            reloadCache()
            log("sync error source=\(info.source.rawValue) id=\(info.sessionID) error=\(error.localizedDescription)")
        }
    }

    private func ensureSynced(info: inout SessionArchiveInfo, reason: String) throws {
        let fm = FileManager.default
        let upstreamURL = URL(fileURLWithPath: info.upstreamPath)
        let upstreamExists = fm.fileExists(atPath: upstreamURL.path)
        info.lastUpstreamSeenAt = upstreamExists ? Date() : info.lastUpstreamSeenAt
        info.upstreamMissing = !upstreamExists

        try fm.createDirectory(at: sourceRoot(info.source), withIntermediateDirectories: true)

        guard upstreamExists else {
            // Upstream missing: keep archive as-is and surface as final (safe).
            if fm.fileExists(atPath: sessionRoot(source: info.source, id: info.sessionID).path) {
                info.status = .final
                try writeInfo(info)
                reloadCache()
            }
            log("sync upstream missing source=\(info.source.rawValue) id=\(info.sessionID) path=\(info.upstreamPath)")
            return
        }

        // Decide whether to sync.
        let existingManifest: SessionArchiveManifest? = {
            let url = manifestURL(source: info.source, id: info.sessionID)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SessionArchiveManifest.self, from: data)
        }()

        let snapshotBefore = try scanUpstreamSnapshot(at: upstreamURL, primaryRelativePath: info.primaryRelativePath)

        // Only surface the "Saving…" staging state when we actually need to copy.
        // Otherwise periodic sync checks can cause UI flicker even when nothing changes.
        let hasArchivedPrimary = fm.fileExists(atPath: archivedPrimaryPath(info: info).path)
        let isNoop = (existingManifest != nil && existingManifest == snapshotBefore && hasArchivedPrimary)
        if !isNoop {
            info.status = .staging
            try writeInfo(info)
            reloadCache()
        }

        if isNoop {
            // No changes; maybe transition to final if quiet long enough.
            let now = Date()
            if info.lastUpstreamChangeAt == nil { info.lastUpstreamChangeAt = info.lastSyncAt ?? now }
            if shouldMarkFinal(lastChangeAt: info.lastUpstreamChangeAt) {
                info.status = .final
            } else {
                info.status = .syncing
            }
            try writeInfo(info)
            reloadCache()
            log("sync noop source=\(info.source.rawValue) id=\(info.sessionID) status=\(info.status.rawValue)")
            return
        }

        // Copy with consistency check.
        let attemptsMax = 4
        var attempt = 0
        var snapshot = snapshotBefore

        while attempt < attemptsMax {
            attempt += 1
            let staging = try makeStagingDir(source: info.source, sessionID: info.sessionID)
            defer { try? fm.removeItem(at: staging) }

            let stagingSessionRoot = staging.appendingPathComponent(info.sessionID, isDirectory: true)
            let stagingDataRoot = stagingSessionRoot.appendingPathComponent("data", isDirectory: true)
            try fm.createDirectory(at: stagingDataRoot, withIntermediateDirectories: true)
            log("sync staging created path=\(stagingSessionRoot.path) exists=\(fm.fileExists(atPath: stagingSessionRoot.path))")

            try copySnapshot(snapshot, from: upstreamURL, upstreamIsDirectory: info.upstreamIsDirectory, to: stagingDataRoot)
            let snapshotAfter = try scanUpstreamSnapshot(at: upstreamURL, primaryRelativePath: info.primaryRelativePath)

            if snapshotAfter == snapshot {
                // Stable enough to commit.
                var committedInfo = info
                committedInfo.status = .syncing
                committedInfo.lastSyncAt = Date()
                committedInfo.lastUpstreamSeenAt = Date()
                committedInfo.lastError = nil
                committedInfo.upstreamMissing = false
                committedInfo.lastUpstreamChangeAt = committedInfo.lastSyncAt
                committedInfo.archiveSizeBytes = try computeArchiveSizeBytes(dataRoot: stagingDataRoot)

                try fm.createDirectory(at: stagingSessionRoot, withIntermediateDirectories: true)
                try writeInfoTo(path: stagingSessionRoot.appendingPathComponent("meta.json", isDirectory: false), info: committedInfo)
                try writeManifestTo(path: stagingSessionRoot.appendingPathComponent("manifest.json", isDirectory: false), manifest: snapshot)

                try commitStaging(stagingSessionRoot, source: info.source, sessionID: info.sessionID)
                let final = sessionRoot(source: info.source, id: info.sessionID)
                log("sync commit final=\(final.path) exists=\(fm.fileExists(atPath: final.path))")
                log("sync commit staging still exists=\(fm.fileExists(atPath: stagingSessionRoot.path))")

                info = committedInfo
                // Mark final if quiet long enough.
                if shouldMarkFinal(lastChangeAt: info.lastUpstreamChangeAt) {
                    info.status = .final
                    try writeInfo(info)
                }
                log("sync committed source=\(info.source.rawValue) id=\(info.sessionID) size=\(info.archiveSizeBytes ?? 0)")
                return
            }

            // Upstream changed during copy; retry with new snapshot.
            snapshot = snapshotAfter
        }

        // If upstream is churning, commit a best-effort snapshot and keep syncing.
        let staging = try makeStagingDir(source: info.source, sessionID: info.sessionID)
        defer { try? fm.removeItem(at: staging) }
        let stagingSessionRoot = staging.appendingPathComponent(info.sessionID, isDirectory: true)
        let stagingDataRoot = stagingSessionRoot.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: stagingDataRoot, withIntermediateDirectories: true)
        try copySnapshot(snapshot, from: upstreamURL, upstreamIsDirectory: info.upstreamIsDirectory, to: stagingDataRoot)

        var committedInfo = info
        committedInfo.status = .syncing
        committedInfo.lastSyncAt = Date()
        committedInfo.lastUpstreamSeenAt = Date()
        committedInfo.upstreamMissing = false
        committedInfo.lastUpstreamChangeAt = committedInfo.lastSyncAt
        committedInfo.archiveSizeBytes = try computeArchiveSizeBytes(dataRoot: stagingDataRoot)
        committedInfo.lastError = "Session was updating continuously; archived a best-effort snapshot (reason=\(reason))"

        try fm.createDirectory(at: stagingSessionRoot, withIntermediateDirectories: true)
        try writeInfoTo(path: stagingSessionRoot.appendingPathComponent("meta.json", isDirectory: false), info: committedInfo)
        try writeManifestTo(path: stagingSessionRoot.appendingPathComponent("manifest.json", isDirectory: false), manifest: snapshot)
        try commitStaging(stagingSessionRoot, source: info.source, sessionID: info.sessionID)
        let final = sessionRoot(source: info.source, id: info.sessionID)
        log("sync commit final=\(final.path) exists=\(fm.fileExists(atPath: final.path))")
        log("sync commit staging still exists=\(fm.fileExists(atPath: stagingSessionRoot.path))")

        info = committedInfo
        log("sync committed best-effort source=\(info.source.rawValue) id=\(info.sessionID) size=\(info.archiveSizeBytes ?? 0)")
    }

    private func shouldMarkFinal(lastChangeAt: Date?) -> Bool {
        guard let lastChangeAt else { return false }
        let minutes = UserDefaults.standard.object(forKey: PreferencesKey.Archives.stopSyncAfterInactivityMinutes) as? Int ?? 30
        let threshold = TimeInterval(max(1, minutes)) * 60.0
        return Date().timeIntervalSince(lastChangeAt) >= threshold
    }

    private func scanUpstreamSnapshot(at upstream: URL, primaryRelativePath: String) throws -> SessionArchiveManifest {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: upstream.path, isDirectory: &isDir)

        if isDir.boolValue {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let enumerator = fm.enumerator(at: upstream, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var entries: [SessionArchiveManifest.Entry] = []
            while let url = enumerator?.nextObject() as? URL {
                let rv = try url.resourceValues(forKeys: Set(keys))
                guard rv.isRegularFile == true else { continue }
                let rel = url.path.replacingOccurrences(of: upstream.path + "/", with: "")
                let size = Int64(rv.fileSize ?? 0)
                let mtime = (rv.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
                entries.append(.init(relativePath: rel, sizeBytes: size, mtimeSeconds: mtime, sha256: hashIfSmall(url: url, sizeBytes: size)))
            }
            entries.sort { $0.relativePath < $1.relativePath }
            return SessionArchiveManifest(entries: entries)
        } else {
            let rv = try upstream.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(rv.fileSize ?? 0)
            let mtime = (rv.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
            return SessionArchiveManifest(entries: [
                .init(relativePath: primaryRelativePath, sizeBytes: size, mtimeSeconds: mtime, sha256: hashIfSmall(url: upstream, sizeBytes: size))
            ])
        }
    }

    private func copySnapshot(_ manifest: SessionArchiveManifest, from upstream: URL, upstreamIsDirectory: Bool, to destDataRoot: URL) throws {
        let fm = FileManager.default
        if upstreamIsDirectory {
            for e in manifest.entries {
                let src = upstream.appendingPathComponent(e.relativePath, isDirectory: false)
                let dst = destDataRoot.appendingPathComponent(e.relativePath, isDirectory: false)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
            }
        } else {
            guard let e = manifest.entries.first else { return }
            let dst = destDataRoot.appendingPathComponent(e.relativePath, isDirectory: false)
            try fm.copyItem(at: upstream, to: dst)
        }
    }

    private func commitStaging(_ stagingSessionRoot: URL, source: SessionSource, sessionID: String) throws {
        let fm = FileManager.default
        let final = sessionRoot(source: source, id: sessionID)
        if fm.fileExists(atPath: final.path) {
            let parent = final.deletingLastPathComponent()
            let backupURL = parent.appendingPathComponent(".backup-\(sessionID)-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: final, to: backupURL)
            do {
                try fm.moveItem(at: stagingSessionRoot, to: final)
                try? fm.removeItem(at: backupURL)
            } catch {
                if fm.fileExists(atPath: final.path) {
                    try? fm.removeItem(at: final)
                }
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.moveItem(at: backupURL, to: final)
                }
                throw error
            }
        } else {
            try fm.moveItem(at: stagingSessionRoot, to: final)
        }
    }

    private func makeStagingDir(source: SessionSource, sessionID: String) throws -> URL {
        let fm = FileManager.default
        let parent = sourceRoot(source)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".staging-\(sessionID)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func writeInfoTo(path: URL, info: SessionArchiveInfo) throws {
        let data = try JSONEncoder().encode(info)
        try data.write(to: path, options: [.atomic])
    }

    private func writeManifestTo(path: URL, manifest: SessionArchiveManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: path, options: [.atomic])
    }

    private func computeArchiveSizeBytes(dataRoot: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dataRoot.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let rv = try dataRoot.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv.fileSize ?? 0)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = fm.enumerator(at: dataRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let rv = try url.resourceValues(forKeys: Set(keys))
            guard rv.isRegularFile == true else { continue }
            total += Int64(rv.fileSize ?? 0)
        }
        return total
    }

    private func isDirectory(path: String) -> Bool {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func hashIfSmall(url: URL, sizeBytes: Int64) -> String? {
        // Hash only small files to keep sync lightweight.
        guard sizeBytes > 0, sizeBytes <= 128 * 1024 else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func deleteArchive(source: SessionSource, id: String) {
        let fm = FileManager.default
        let root = sessionRoot(source: source, id: id)
        log("delete archive source=\(source.rawValue) id=\(id) path=\(root.path)")
        // Prefer moving to Trash so the action is reversible.
        if (try? fm.trashItem(at: root, resultingItemURL: nil)) != nil {
            return
        }
        try? fm.removeItem(at: root)
    }

    private func log(_ message: String) {
        let fm = FileManager.default
        let logURL = archivesRoot().appendingPathComponent("archive.log", isDirectory: false)
        rotateArchiveLogIfNeeded(logURL: logURL)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        } else {
            try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func rotateArchiveLogIfNeeded(logURL: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber else {
            return
        }
        if size.int64Value < LogRotation.maxBytes { return }

        // Keep a small number of backups: archive.log.1, archive.log.2, ...
        let parent = logURL.deletingLastPathComponent()
        let base = logURL.lastPathComponent

        // Remove the oldest backup first (best-effort).
        if LogRotation.backupsToKeep >= 1 {
            let oldest = parent.appendingPathComponent("\(base).\(LogRotation.backupsToKeep)", isDirectory: false)
            try? fm.removeItem(at: oldest)
        }

        // Shift backups down: .(n-1) -> .n
        if LogRotation.backupsToKeep >= 2 {
            for i in stride(from: LogRotation.backupsToKeep - 1, through: 1, by: -1) {
                let from = parent.appendingPathComponent("\(base).\(i)", isDirectory: false)
                let to = parent.appendingPathComponent("\(base).\(i + 1)", isDirectory: false)
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }

        // Move current log to .1
        let first = parent.appendingPathComponent("\(base).1", isDirectory: false)
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: logURL, to: first)
    }

    private func cleanupOrphanedTempDirs() {
        let fm = FileManager.default
        let root = archivesRoot()
        let cutoff = Date().addingTimeInterval(-TempCleanup.minAgeSeconds)

        // Ensure the root exists so enumeration is stable.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        for source in SessionSource.allCases {
            let dir = root.appendingPathComponent(source.rawValue, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for url in children {
                let name = url.lastPathComponent
                guard name.hasPrefix(".staging-") || name.hasPrefix(".backup-") else { continue }
                let rv = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                let mtime = rv?.contentModificationDate ?? .distantPast
                guard mtime < cutoff else { continue }
                try? fm.removeItem(at: url)
            }
        }
    }

    private func logArchivesRootIfNeeded() {
        guard !didLogArchivesRoot else { return }
        didLogArchivesRoot = true
        log("archivesRoot=\(archivesRoot().path)")
    }
}
