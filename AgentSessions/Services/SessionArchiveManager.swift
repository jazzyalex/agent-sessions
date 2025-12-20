import Foundation
import CryptoKit

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

final class SessionArchiveManager: ObservableObject {
    static let shared = SessionArchiveManager()

    @Published private(set) var infoByKey: [String: SessionArchiveInfo] = [:]

    private let ioQueue = DispatchQueue(label: "AgentSessions.SessionArchiveManager.io", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {
        // Eagerly warm cache for UI.
        ioQueue.async { [weak self] in
            self?.reloadCache()
        }
        startPeriodicSync()
    }

    func key(source: SessionSource, id: String) -> String { "\(source.rawValue):\(id)" }

    func info(source: SessionSource, id: String) -> SessionArchiveInfo? {
        infoByKey[key(source: source, id: id)]
    }

    func pin(session: Session) {
        ioQueue.async { [weak self] in
            guard let self else { return }
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
            for id in pinned {
                guard var info = loadInfoIfExists(source: source, id: id) else { continue }
                ensureArchiveExistsAndSync(info: &info, reason: reason)
            }
        }
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

    private func ensureArchiveExistsAndSync(info: inout SessionArchiveInfo, reason: String) {
        do {
            try ensureSynced(info: &info, reason: reason)
        } catch {
            info.status = .error
            info.lastError = error.localizedDescription
            try? writeInfo(info)
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
            }
            return
        }

        // Decide whether to sync.
        let existingManifest: SessionArchiveManifest? = {
            let url = manifestURL(source: info.source, id: info.sessionID)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SessionArchiveManifest.self, from: data)
        }()

        let snapshotBefore = try scanUpstreamSnapshot(at: upstreamURL, primaryRelativePath: info.primaryRelativePath)

        if let existingManifest, existingManifest == snapshotBefore, fm.fileExists(atPath: archivedPrimaryPath(info: info).path) {
            // No changes; maybe transition to final if quiet long enough.
            let now = Date()
            if info.lastUpstreamChangeAt == nil { info.lastUpstreamChangeAt = info.lastSyncAt ?? now }
            if shouldMarkFinal(lastChangeAt: info.lastUpstreamChangeAt) {
                info.status = .final
            } else {
                info.status = .syncing
            }
            try writeInfo(info)
            return
        }

        info.status = .staging
        try writeInfo(info)

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

                info = committedInfo
                // Mark final if quiet long enough.
                if shouldMarkFinal(lastChangeAt: info.lastUpstreamChangeAt) {
                    info.status = .final
                    try writeInfo(info)
                }
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

        info = committedInfo
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
            let backupURL = try fm.replaceItemAt(final, withItemAt: stagingSessionRoot, backupItemName: ".backup-\(UUID().uuidString)", options: [])
            if let backupURL {
                try? fm.removeItem(at: backupURL)
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
        try? fm.removeItem(at: root)
    }
}
