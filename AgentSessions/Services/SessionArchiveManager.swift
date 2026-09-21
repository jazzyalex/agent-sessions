import Foundation
import CryptoKit
import SQLite3
import Darwin

#if DEBUG
enum SessionArchiveManagerTestHooks {
    static var applicationSupportDirectoryProvider: (() -> URL?)?
    /// Deterministic race seam immediately before an archive attempt opens its
    /// source files. Tests must reset it in defer.
    static var preCopyHook: (() -> Void)?
    /// Deterministic seam after ACP authority is checked and before the source
    /// manifest is captured. Tests must reset it in defer.
    static var preSnapshotHook: (() -> Void)?
    /// Deterministic churn seam at the post-copy/pre-resnapshot boundary of
    /// the archive retry loop. Invoked synchronously after each attempt's
    /// copy, before the stability re-snapshot, so a test can mutate upstream
    /// on every attempt and prove fail-closed behavior. Nil in production.
    /// Tests must reset it in defer.
    static var postCopyHook: (() -> Void)?
    /// Deterministic seam after the post-copy source manifest is captured and
    /// before a stable attempt can commit. Tests must reset it in defer.
    static var postSnapshotHook: (() -> Void)?
    /// Test-only failure injection for the recovery rename path. Returning
    /// false simulates a filesystem rename failure.
    static var recoveryRenameHook: (() -> Bool)?
    /// Test-only failure injection for removal of an incomplete final archive.
    static var recoveryRemoveFinalHook: (() -> Bool)?
    /// Test-only failure injection for the directory durability barrier used
    /// while restoring a recovery copy.
    static var recoverySyncHook: (() -> Bool)?
    /// Test-only failure injection for directory enumeration. A failed scan
    /// must never be interpreted as an empty transaction set.
    static var directoryEnumerationHook: (() -> Bool)?
    /// Test-only seam before a generic upstream directory enumeration. A
    /// failed enumeration must leave the committed archive untouched.
    static var upstreamEnumerationHook: (() -> Bool)?
    /// Test-only seam after the final pre-commit authority check and before
    /// the first archive rename. A root change here must be detected by the
    /// post-rename check and roll the committed tree back.
    static var beforeCommitRenameHook: (() -> Void)?
    /// Test-only seam after the caller's staged-tree validation and before the
    /// commit transaction opens it. Tests use this to mutate the staged tree
    /// and prove commit-time validation is bound to the bytes being renamed.
    static var afterStagedValidationHook: ((URL) -> Void)?
    /// Test-only seam after a replacement has been installed and before its
    /// descriptor-bound validation. Tests use this to force an invalid
    /// installed result and exercise identity-safe rollback.
    static var afterReplacementInstalledHook: (() -> Void)?
    /// Test-only seam after an invalid or unavailable result is observed and
    /// before cleanup or rollback. Tests use this to replace the pathname and
    /// prove the cleanup remains fail-closed.
    static var beforeInvalidArchiveCleanupHook: (() -> Void)?
    /// Test-only seam after an installed archive validates and before any
    /// recovery copy can be discarded. Tests use this to replace the final
    /// pathname and prove cleanup or rollback is bound to the validated
    /// directory.
    static var beforeBackupCleanupHook: (() -> Void)?
    /// Test-only seam after an archive entry identity is checked and before
    /// it is moved to a private quarantine name. Tests use this to exercise
    /// the final pathname race at the destructive syscall boundary.
    static var beforeArchiveEntryQuarantineHook: (() -> Void)?
    /// Test-only seam after the source archive directory is opened but before
    /// its cross-process mutation lock is acquired. Tests use this to replace
    /// a stale archive observation while a sync is waiting for the lock.
    static var beforeArchiveMutationLockHook: (() -> Void)?
}
#endif

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
    var surface: SessionSurface?

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

extension SessionArchiveInfo {
    private static let cursorACPPrefix = "cursor-acp:"

    static func isCursorACPIdentity(_ id: String) -> Bool {
        guard id.hasPrefix(cursorACPPrefix),
              UUID(uuidString: String(id.dropFirst(cursorACPPrefix.count))) != nil else {
            return false
        }
        return true
    }

    /// ACP archive provenance is derived from the immutable namespaced ID as
    /// well as the metadata fields. A mutable meta.json must never be able to
    /// turn a directory archive back into a generic path archive.
    var isCursorACPArchive: Bool {
        source == .cursor &&
            Self.isCursorACPIdentity(sessionID) &&
            surface == .acp &&
            upstreamIsDirectory &&
            primaryRelativePath == "store.db"
    }
}

struct SessionArchiveManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var relativePath: String
        var sizeBytes: Int64
        var mtimeSeconds: TimeInterval
        var mtimeNanoseconds: Int64? = nil
        var sha256: String?
        /// Device/inode identity captured for provider-filtered snapshots.
        /// Optional keeps older manifests decodable.
        var fileIdentity: String? = nil
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

    private enum ArchiveRootError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            "Application Support directory unavailable"
        }
    }

    // Fail-closed errors for provider-filtered manifests. A nil filter result
    // or an entry that escapes/is not a regular file throws before any copy,
    // so no partial archive is ever committed.
    private enum ArchiveManifestError: LocalizedError {
        case providerManifestUnavailable(source: String, id: String)
        case filteredEntryInvalid(path: String)
        case upstreamUnstable(source: String, id: String)
        case invalidACPSnapshot(id: String)
        case unavailableACPSnapshot(id: String)
        case archiveValidationUnavailable(id: String)
        case archiveSnapshotInvalid(id: String)
        case archiveSnapshotUnavailable(id: String)
        case authorityChanged(id: String)
        case authorityUnavailable(id: String)
        case recoveryUnavailable(id: String)

        var errorDescription: String? {
            switch self {
            case .providerManifestUnavailable(let source, let id):
                return "Archive manifest unavailable for \(source):\(id)"
            case .filteredEntryInvalid(let path):
                return "Archive entry invalid: \(path)"
            case .upstreamUnstable(let source, let id):
                return "Session was updating continuously; no stable snapshot for \(source):\(id), archive not updated"
            case .invalidACPSnapshot(let id):
                return "ACP archive snapshot failed semantic validation for \(id)"
            case .unavailableACPSnapshot(let id):
                return "ACP archive snapshot could not be validated because storage was unavailable for \(id)"
            case .archiveValidationUnavailable(let id):
                return "Existing archive could not be validated because storage was unavailable for \(id)"
            case .archiveSnapshotInvalid(let id):
                return "Archive snapshot failed exact validation for \(id)"
            case .archiveSnapshotUnavailable(let id):
                return "Archive snapshot could not be validated because storage was unavailable for \(id)"
            case .authorityChanged(let id):
                return "ACP source authority changed while syncing \(id); archive not updated"
            case .authorityUnavailable(let id):
                return "ACP source authority became unavailable while syncing \(id); archive not updated"
            case .recoveryUnavailable(let id):
                return "Archive recovery copies remain for \(id); archive not updated"
            }
        }
    }

    private enum ArchivedSnapshotValidation {
        case valid
        case invalid
        case unavailable
    }

    private enum ArchiveRecoveryOutcome {
        case resolved
        case unavailable
        case failed
    }

    private enum ArchiveFileReadResult {
        case data(Data)
        case missing
        case invalid
        case unavailable
    }

    private enum ArchiveFileDescriptorResult {
        case opened(Int32)
        case missing
        case invalid
        case unavailable
    }

    private enum ArchiveSnapshotCopyFailure: Error {
        case invalid
        case unavailable
    }

    private enum ArchiveDirectoryValidationFailure: Error {
        case invalid
        case unavailable
    }

    private enum ArchiveDataFileNamesResult {
        case entries([String])
        case invalid
        case unavailable
    }

    private struct CursorACPAuthorityToken: Equatable {
        let rootPath: String
        let sessionPath: String
        let logicalStat: SessionFileStat
    }

    private enum CurrentCursorACPResolution {
        case found(Session, CursorACPAuthorityToken)
        case absent
        case unavailable
    }

    private enum CursorACPAuthorityCheck {
        case current
        case changed
        case unavailable
    }

    private enum AuthoritativeArchiveSession {
        case live(Session, CursorACPAuthorityToken?)
        /// A complete archive projection with no currently authorized live
        /// source. This may be retained, but it must never be fed back into
        /// the normal live-sync path through its recorded upstream pathname.
        case archiveOnly(Session)
    }

    // Pinning is a user action; keep the queue responsive.
    private let ioQueue = DispatchQueue(label: "AgentSessions.SessionArchiveManager.io", qos: .userInitiated)
    private var inFlightKeys: Set<String> = []
    private var missingResolutionLogged: Set<String> = []
    private var didLogArchivesRoot: Bool = false
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let archiveMutationLockName = ".archive-mutation.lock"

    private init() {
        // Eagerly warm cache for UI and do a single startup sync pass.
        ioQueue.async { [weak self] in
            self?.reloadCache()
            self?.cleanupOrphanedTempDirs()
            self?.syncPinnedSessions(reason: "startup")
            self?.reloadCache()
        }
    }

    func key(source: SessionSource, id: String) -> String { "\(source.rawValue):\(id)" }

    func info(source: SessionSource, id: String) -> SessionArchiveInfo? {
        infoByKey[key(source: source, id: id)]
    }

    func archiveFolderURL(source: SessionSource, id: String) -> URL? {
        guard let root = sessionRoot(source: source, id: id) else { return nil }
        // This action is user-initiated; prefer creating the folder so Finder can reveal it.
        do {
            let descriptor = try openArchiveSessionDirectory(source: source, id: id, create: true)
            Darwin.close(descriptor)
            return root
        } catch {
            return nil
        }
    }

    func archivesRootURL() -> URL {
        archivesRoot() ?? fallbackArchivesRootURL()
    }

    /// Provider-neutral archive unit for a session: the filesystem root to snapshot
    /// and the primary file to parse back. Single-file sources snapshot the file
    /// itself; a source declaring `archive.archiveUnit` (Cline's manifest+messages
    /// pair) snapshots the session directory so the companion survives.
    static func archiveUnit(for session: Session) -> (root: URL, isDirectory: Bool, primaryRelativePath: String) {
        let primaryURL = URL(fileURLWithPath: session.filePath)
        if let unit = SessionSourceRegistry.descriptor(for: session.source).archive?.archiveUnit?(primaryURL) {
            return (unit.root, unit.isDirectory, unit.primaryRelativePath)
        }
        if session.source == .cursor && SessionArchiveInfo.isCursorACPIdentity(session.id) {
            // A known ACP identity must never degrade to a generic single-file
            // archive when its live-store admission check fails. The caller
            // still has to resolve the UUID under the current root; this shape
            // only keeps any failed attempt in the ACP directory contract.
            return (primaryURL.deletingLastPathComponent(), true, "store.db")
        }
        return (primaryURL, isDirectoryStatic(path: session.filePath), primaryURL.lastPathComponent)
    }

    private static func isDirectoryStatic(path: String) -> Bool {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private static func archivePlaceholder(for session: Session) -> SessionArchiveInfo {
        let unit = archiveUnit(for: session)
        return SessionArchiveInfo(
            sessionID: session.id,
            source: session.source,
            surface: session.surface,
            upstreamPath: unit.root.path,
            upstreamIsDirectory: unit.isDirectory,
            primaryRelativePath: unit.primaryRelativePath,
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
    }

    private func authoritativeArchiveSession(_ session: Session) -> AuthoritativeArchiveSession? {
        guard session.source == .cursor,
              SessionArchiveInfo.isCursorACPIdentity(session.id) else {
            return .live(session, nil)
        }
        switch resolveCurrentCursorACPSession(sessionID: session.id) {
        case .found(let current, let token):
            return .live(current, token)
        case .absent, .unavailable:
            // A row hydrated from an already committed archive is safe to
            // retain when the live root is gone, but it is archive-only. Do
            // not return it as if its recorded upstream path were authorized;
            // a first pin with no complete archive remains fail-closed below.
            guard let info = loadInfoIfExists(source: session.source, id: session.id),
                  info.isCursorACPArchive,
                  isArchivedPrimary(session: session),
                  hasCompleteArchivedSnapshot(info: info) else {
                return nil
            }
            return .archiveOnly(session)
        }
    }

    func pin(session: Session) {
        // A source that declines archiving (`archive == nil`, SPEC §4) has nothing
        // per-session to copy out, so there is nothing to pin. This gate is not
        // cosmetic: for a shared-database source every session reports the same
        // `filePath`, so without it `ensureSynced` copies the entire store once per
        // starred session — gigabytes for devin — and re-copies it whenever the live
        // CLI moves the file's stat. Starring itself is unaffected; `toggleFavorite`
        // records it via `favorites.toggle` before this call.
        guard SessionSourceRegistry.descriptor(for: session.source).archive != nil else { return }

        let k = key(source: session.source, id: session.id)
        // ACP pinning resolves the UUID under the current configured root on
        // the IO queue before publishing a UI placeholder. The placeholder is
        // deliberately not written to archive metadata before the token-bearing
        // sync starts; an authority outage must leave disk state untouched.
        // Legacy sources retain the immediate UI update because their session
        // path is already the archive authority carried by the row.
        let isCursorACP = session.source == .cursor && SessionArchiveInfo.isCursorACPIdentity(session.id)
        if !isCursorACP {
            let placeholder = Self.archivePlaceholder(for: session)
            DispatchQueue.main.async { [weak self] in
                self?.infoByKey[k] = placeholder
            }
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.inFlightKeys.contains(k) { return }
            self.inFlightKeys.insert(k)
            defer { self.inFlightKeys.remove(k) }

            guard let authority = self.authoritativeArchiveSession(session) else {
                self.log("pin rejected source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_unavailable")
                return
            }
            guard case .live(let authoritativeSession, _) = authority else {
                self.log("pin retained archive source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_absent")
                return
            }
            if isCursorACP {
                let placeholder = Self.archivePlaceholder(for: authoritativeSession)
                DispatchQueue.main.async { [weak self] in
                    self?.infoByKey[k] = placeholder
                }
            }

            self.logArchivesRootIfNeeded()
            self.log("pin requested source=\(authoritativeSession.source.rawValue) id=\(authoritativeSession.id) path=\(authoritativeSession.filePath)")
            if !isCursorACP {
                self.writePinPlaceholder(session: authoritativeSession, key: k)
            }
            self.ensureArchiveExistsAndSync(session: authoritativeSession, reason: "pin")
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

#if DEBUG
    /// Synchronous seam for archive contract tests. Production pin/sync remains queued.
    func syncSessionForTesting(_ session: Session) {
        // Tests intentionally use isolated fixture roots that are not the
        // user's configured Cursor root. The production pin path still goes
        // through authoritativeArchiveSession before this worker is reached.
        ensureArchiveExistsAndSyncUnvalidated(session, reason: "test")
    }

    func pinSessionForTesting(_ session: Session) {
        guard let authority = authoritativeArchiveSession(session) else { return }
        switch authority {
        case .live(let authoritativeSession, let authorityToken):
            let isCursorACP = authoritativeSession.source == .cursor &&
                SessionArchiveInfo.isCursorACPIdentity(authoritativeSession.id)
            if !isCursorACP {
                writePinPlaceholder(session: authoritativeSession,
                                    key: key(source: authoritativeSession.source,
                                             id: authoritativeSession.id))
            }
            ensureArchiveExistsAndSyncUnvalidated(authoritativeSession,
                                                  reason: "test-pin",
                                                  authorityToken: authorityToken)
        case .archiveOnly:
            // Match the production pin path: an archive-only fallback has no
            // currently authorized live source, so re-pinning it must retain
            // the committed projection without attempting a path-based sync.
            return
        }
    }

    func syncPinnedSessionsForTesting() {
        syncPinnedSessions(reason: "test")
    }

    func archiveInfoForTesting(source: SessionSource, id: String) -> SessionArchiveInfo? {
        loadInfoIfExists(source: source, id: id)
    }

    func deleteArchiveForTesting(source: SessionSource, id: String) {
        deleteArchive(source: source, id: id)
    }

    func recoverOrphanedArchivesForTesting() {
        cleanupOrphanedTempDirs()
    }
#endif

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
            guard hasCompleteArchivedSnapshot(info: info),
                  let archiveURL = archivedPrimaryPath(info: info) else { continue }
            if info.isCursorACPArchive {
                guard CursorACPStoreReader.isACPStore(archiveURL) else { continue }
            }
            let archivePath = archiveURL.path
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
                lightweightCommands: info.estimatedCommands,
                originator: info.surface == .acp ? "cursor-agent" : nil,
                originSource: info.surface == .acp ? "acp-persisted" : nil,
                surface: info.surface
            )
            out.append(placeholder)
        }

        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Paths

    private func resolveApplicationSupportDirectoryURL() -> URL? {
#if DEBUG
        if let provider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider {
            return provider()
        }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private func fallbackArchivesRootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
    }

    private func archivesRoot() -> URL? {
        guard let appSupport = resolveApplicationSupportDirectoryURL() else { return nil }
        // `/var` is a system alias for `/private/var` on macOS. Normalize only
        // this trusted base before descriptor traversal; never resolve the
        // managed archive/session path after appending its components.
        let standardizedBase = appSupport.standardizedFileURL
        let basePath = standardizedBase.path
        let trustedBasePath: String
        if basePath == "/var" {
            trustedBasePath = "/private/var"
        } else if basePath.hasPrefix("/var/") {
            trustedBasePath = "/private" + basePath
        } else {
            trustedBasePath = basePath
        }
        let trustedBase = URL(fileURLWithPath: trustedBasePath, isDirectory: true)
        return trustedBase.appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
    }

    private func sourceRoot(_ source: SessionSource) -> URL? {
        archivesRoot()?.appendingPathComponent(source.rawValue, isDirectory: true)
    }

    private func sessionRoot(source: SessionSource, id: String) -> URL? {
        sourceRoot(source)?.appendingPathComponent(id, isDirectory: true)
    }

    private func metaURL(source: SessionSource, id: String) -> URL? {
        sessionRoot(source: source, id: id)?.appendingPathComponent("meta.json", isDirectory: false)
    }

    private func manifestURL(source: SessionSource, id: String) -> URL? {
        sessionRoot(source: source, id: id)?.appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func dataRootURL(source: SessionSource, id: String) -> URL? {
        sessionRoot(source: source, id: id)?.appendingPathComponent("data", isDirectory: true)
    }

    private func archivedPrimaryPath(info: SessionArchiveInfo) -> URL? {
        guard isValidArchiveInfo(info, source: info.source, id: info.sessionID),
              let dataRoot = dataRootURL(source: info.source, id: info.sessionID) else { return nil }
        let candidate = dataRoot.appendingPathComponent(info.primaryRelativePath, isDirectory: false)
        let root = dataRoot.standardizedFileURL
        let standardized = candidate.standardizedFileURL
        guard standardized.path.hasPrefix(root.path + "/"),
              candidate.resolvingSymlinksInPath().standardizedFileURL == standardized,
              hasNoSymlinkComponents(candidate, rootPath: root.path) else { return nil }
        return candidate
    }

    private func isSafeArchiveRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func isValidArchiveInfo(_ info: SessionArchiveInfo,
                                    source: SessionSource,
                                    id: String) -> Bool {
        guard info.source == source,
              info.sessionID == id,
              isSafeArchiveRelativePath(info.primaryRelativePath) else { return false }
        if source == .cursor, SessionArchiveInfo.isCursorACPIdentity(id) {
            return info.isCursorACPArchive
        }
        if source == .cursor, info.surface == .acp {
            // ACP surface is reserved for the namespaced ACP identity.
            return false
        }
        if source == .cursor,
           info.upstreamIsDirectory,
           info.primaryRelativePath == "store.db" {
            // The only Cursor directory archive is the ACP unit. Do not let
            // metadata downgrade its provenance and regain generic path trust.
            return false
        }
        return true
    }

    /// A path may use physical-file search freshness only when it is the
    /// recorded copied primary for this saved session. A failed live artifact
    /// resolution alone is never proof that a file belongs to our archive.
    func isArchivedPrimary(session: Session) -> Bool {
        guard let info = loadInfoIfExists(source: session.source, id: session.id),
              let archived = archivedPrimaryPath(info: info) else { return false }
        return archived.standardizedFileURL == URL(fileURLWithPath: session.filePath).standardizedFileURL
    }

    // MARK: - Cache

    private func reloadCache() {
        let fm = FileManager.default
        guard let root = archivesRoot() else {
            DispatchQueue.main.async { self.infoByKey = [:] }
            return
        }
        do {
            let descriptor = try openDirectoryDescriptor(at: root, create: true)
            Darwin.close(descriptor)
        } catch {
            DispatchQueue.main.async { self.infoByKey = [:] }
            return
        }

        var map: [String: SessionArchiveInfo] = [:]
        for source in SessionSource.allCases {
            guard let src = sourceRoot(source) else { continue }
            guard let dirs = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for dir in dirs {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let id = dir.lastPathComponent
                guard let info = loadInfoIfExists(source: source, id: id) else { continue }
                map[key(source: source, id: id)] = info
            }
        }

        DispatchQueue.main.async { self.infoByKey = map }
    }

    private func loadInfoIfExists(source: SessionSource, id: String) -> SessionArchiveInfo? {
        guard let data = readArchiveFile(source: source, id: id, name: "meta.json"),
              let info = try? JSONDecoder().decode(SessionArchiveInfo.self, from: data),
              isValidArchiveInfo(info, source: source, id: id) else { return nil }
        return info
    }

    private func writeInfo(_ info: SessionArchiveInfo) throws {
        let data = try JSONEncoder().encode(info)
        let descriptor = try openArchiveSessionDirectory(source: info.source,
                                                          id: info.sessionID,
                                                          create: true)
        defer { Darwin.close(descriptor) }
        try writeAtomically(data, in: descriptor, name: "meta.json")
    }

    private func writeManifest(_ manifest: SessionArchiveManifest, source: SessionSource, id: String) throws {
        let data = try JSONEncoder().encode(manifest)
        let descriptor = try openArchiveSessionDirectory(source: source, id: id, create: true)
        defer { Darwin.close(descriptor) }
        try writeAtomically(data, in: descriptor, name: "manifest.json")
    }

    // MARK: - Sync

    private func syncPinnedSessions(reason: String) {
        let pinsEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Archives.starPinsSessions) as? Bool ?? true
        guard pinsEnabled else { return }
        let store = StarredSessionsStore()
        for source in SessionSource.allCases {
            // The `pin` gate alone is not enough. Starring writes the id to
            // `StarredSessionsStore` before `pin` is ever called, so this loop would
            // find it here with no archive info and take the backfill branch below,
            // copying the upstream anyway one launch later. Skip the whole source.
            guard SessionSourceRegistry.descriptor(for: source).archive != nil else { continue }
            let pinned = store.pinnedIDs(for: source)
            guard !pinned.isEmpty else { continue }
            var fallbackURLs: [String: URL]? = nil
            for id in pinned {
                if var info = loadInfoIfExists(source: source, id: id) {
                    if source == .deepseekHarness {
                        // Existing DSH Saved metadata may point at v2 while the
                        // immutable live directory has advanced to v3. Periodic
                        // sync must rediscover the current primary; otherwise the
                        // filtered snapshot permanently excludes successors.
                        if fallbackURLs == nil {
                            fallbackURLs = resolveBackfillURLsFromFilesystem(source: source)
                        }
                        if let url = fallbackURLs?[id],
                           let session = DeepSeekHarnessSessionParser.parseFile(at: url),
                           session.id == id,
                           Self.dshGeneration(of: session.filePath) >= Self.dshGeneration(
                            of: info.primaryRelativePath
                           ) {
                            ensureArchiveExistsAndSync(session: session, reason: reason)
                        } else if !FileManager.default.fileExists(atPath: info.upstreamPath) {
                            // A removed upstream can be marked missing. An
                            // existing but unreadable/partial directory is not
                            // authority to resnapshot or downgrade a healthy copy.
                            ensureArchiveExistsAndSync(info: &info, reason: reason)
                        }
                    } else if source == .cursor, SessionArchiveInfo.isCursorACPIdentity(id) {
                        guard info.isCursorACPArchive else { continue }
                        // ACP metadata is not a durable authority for its live
                        // source path. Re-resolve the namespaced UUID under the
                        // currently configured root before every periodic sync.
                        // Only an unavailable root preserves the committed
                        // archive. An authoritative absence must update the
                        // upstream-missing state without consulting the stale
                        // path stored in the archive metadata.
                        switch resolveCurrentCursorACPSession(sessionID: id) {
                        case .found(let session, _):
                            ensureArchiveExistsAndSync(session: session, reason: reason)
                        case .absent:
                            markCurrentCursorACPUpstreamMissing(info: &info, reason: reason)
                        case .unavailable:
                            break
                        }
                    } else {
                        ensureArchiveExistsAndSync(info: &info, reason: reason)
                    }
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

    /// `sessionID -> upstream file URL` for one source, used when IndexDB cannot resolve a
    /// pinned session's path.
    ///
    /// The twelve-arm switch this replaces now lives as `archive.backfillURLs` on each
    /// source's descriptor, sweep for sweep. `UserDefaults.standard` is passed explicitly
    /// because the descriptor closures take their defaults as a parameter (the switch read
    /// the singleton inline). A source that declines archiving (`archive == nil`, SPEC §4)
    /// resolves nothing, so pin backfill for it falls through to the "unresolved" log exactly
    /// as an unhandled source would have.
    private func resolveBackfillURLsFromFilesystem(source: SessionSource) -> [String: URL] {
        SessionSourceRegistry.descriptor(for: source).archive?.backfillURLs(.standard) ?? [:]
    }

    private func resolveCurrentCursorACPSession(sessionID: String) -> CurrentCursorACPResolution {
        let prefix = "cursor-acp:"
        guard sessionID.hasPrefix(prefix),
              let requestedUUID = UUID(uuidString: String(sessionID.dropFirst(prefix.count))) else { return .unavailable }
        let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let discovery = CursorSessionDiscovery(customRoot: customRoot?.isEmpty == false ? customRoot : nil)
        guard let urls = discovery.discoverACPSessionDBs() else { return .unavailable }
        guard let url = urls.first(where: {
            UUID(uuidString: $0.deletingLastPathComponent().lastPathComponent)?.uuidString.lowercased()
                == requestedUUID.uuidString.lowercased()
        }) else { return .absent }
        // A current-root ACP store that exists but cannot be decoded is
        // unavailable authority, not a valid minimal backfill row. Keeping the
        // minimal row here would let periodic sync overwrite a healthy archive
        // with an unreadable live store.
        guard let parsed = CursorACPStoreReader.parseWithAuthority(at: url),
              parsed.session.id == sessionID else {
            return .unavailable
        }
        let rootPath = CursorBackendDetector.normalizedSystemAliasPath(
            discovery.acpSessionsRoot().standardizedFileURL.path
        )
        let sessionPath = CursorBackendDetector.normalizedSystemAliasPath(
            url.standardizedFileURL.path
        )
        return .found(parsed.session,
                     CursorACPAuthorityToken(rootPath: rootPath,
                                             sessionPath: sessionPath,
                                             logicalStat: parsed.logicalStat))
    }

    private func authorityCheck(_ token: CursorACPAuthorityToken?,
                                sessionID: String) -> CursorACPAuthorityCheck {
        guard let token else { return .current }
        switch resolveCurrentCursorACPSession(sessionID: sessionID) {
        case .found(_, let current):
            return current == token ? .current : .changed
        case .absent:
            return .changed
        case .unavailable:
            return .unavailable
        }
    }

    private func requireCurrentAuthority(_ token: CursorACPAuthorityToken?,
                                         sessionID: String) throws {
        switch authorityCheck(token, sessionID: sessionID) {
        case .current:
            return
        case .changed:
            throw ArchiveManifestError.authorityChanged(id: sessionID)
        case .unavailable:
            throw ArchiveManifestError.authorityUnavailable(id: sessionID)
        }
    }

    private func authorityError(for check: CursorACPAuthorityCheck,
                                sessionID: String) -> ArchiveManifestError {
        switch check {
        case .current:
            preconditionFailure("current authority has no failure")
        case .changed:
            return .authorityChanged(id: sessionID)
        case .unavailable:
            return .authorityUnavailable(id: sessionID)
        }
    }

    /// The current-root check alone is vulnerable to a same-path directory ABA:
    /// a different valid ACP directory can be copied and then the original can
    /// be restored before the final check. Bind each archive manifest attempt to
    /// the companion identities captured by authority resolution as well.
    private func authoritySnapshotMatches(_ snapshot: SessionArchiveManifest,
                                          token: CursorACPAuthorityToken?) -> Bool {
        guard let token else { return true }
        let orderedNames = ["meta.json", "store.db", "store.db-wal"]
        let fingerprint = orderedNames.enumerated().map { index, name in
            guard let entry = snapshot.entries.first(where: { $0.relativePath == name }),
                  let fileIdentity = entry.fileIdentity,
                  let mtimeNanoseconds = entry.mtimeNanoseconds else {
                return "\(index)=missing"
            }
            return "\(index)=\(fileIdentity):\(entry.sizeBytes):\(Int64(entry.mtimeSeconds)):\(mtimeNanoseconds)"
        }.joined(separator: "|")
        return token.logicalStat.fingerprint == fingerprint
    }

    private func markCurrentCursorACPUpstreamMissing(info: inout SessionArchiveInfo, reason: String) {
        let originalInfo = info
        var updatedInfo: SessionArchiveInfo?
        do {
            try withArchiveMutationLock(source: info.source) {
                // The caller's `info` was read before the lock. Re-resolve
                // authority and reload the archive after acquiring it; a
                // different process may have deleted or replaced this entry
                // while the caller was waiting. Never let that stale
                // observation recreate a user-deleted archive.
                guard case .absent = resolveCurrentCursorACPSession(sessionID: info.sessionID),
                      var currentInfo = loadInfoIfExists(source: info.source,
                                                         id: info.sessionID) else {
                    return
                }
                currentInfo.upstreamMissing = true
                if hasCompleteArchivedSnapshot(info: currentInfo) {
                    currentInfo.status = .final
                    currentInfo.lastError = nil
                } else {
                    currentInfo.status = .error
                    currentInfo.lastError = "Archived snapshot is incomplete; preserving it without publishing a fallback"
                }
                try writeInfo(currentInfo)
                updatedInfo = currentInfo
            }
        } catch {
            info = originalInfo
            log("sync deferred source=\(info.source.rawValue) id=\(info.sessionID) reason=archive_lock_unavailable error=\(error.localizedDescription)")
            return
        }
        guard let updatedInfo else {
            info = originalInfo
            log("sync deferred source=\(info.source.rawValue) id=\(info.sessionID) reason=archive_changed_while_waiting")
            return
        }
        info = updatedInfo
        reloadCache()
        log("sync upstream absent source=\(info.source.rawValue) id=\(info.sessionID) reason=\(reason)")
    }

    private func isCurrentCursorACPStore(_ url: URL, sessionID: String) -> Bool {
        let prefix = "cursor-acp:"
        guard sessionID.hasPrefix(prefix),
              let requestedUUID = UUID(uuidString: String(sessionID.dropFirst(prefix.count))),
              url.lastPathComponent == "store.db" else { return false }

        let customRoot = UserDefaults.standard.string(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let discovery = CursorSessionDiscovery(customRoot: customRoot?.isEmpty == false ? customRoot : nil)
        let root = discovery.acpSessionsRoot()
        let sessionDirectory = url.deletingLastPathComponent()
        guard UUID(uuidString: sessionDirectory.lastPathComponent)?.uuidString.lowercased()
                == requestedUUID.uuidString.lowercased() else { return false }
        guard discovery.isConfiguredRootCanonical() else { return false }
        let standardizedRoot = root.standardizedFileURL
        let expected = standardizedRoot
            .appendingPathComponent(sessionDirectory.lastPathComponent, isDirectory: true)
            .appendingPathComponent("store.db", isDirectory: false)
            .standardizedFileURL
        guard url.standardizedFileURL == expected else { return false }
        return CursorACPStoreReader.isACPStore(url)
    }

    private static func dshGeneration(of path: String) -> Int {
        DeepSeekHarnessDiscovery.parseGenerationFilename(URL(fileURLWithPath: path).lastPathComponent)?
            .generation ?? Int.max
    }

    private func wouldDowngradeDSHArchive(_ session: Session) -> Bool {
        guard session.source == .deepseekHarness,
              let existing = loadInfoIfExists(source: session.source, id: session.id) else { return false }
        let primary = Self.archiveUnit(for: session).primaryRelativePath
        return Self.dshGeneration(of: primary) < Self.dshGeneration(of: existing.primaryRelativePath)
    }

    /// Best-effort session for a `(sessionID, upstreamURL)` pair the filesystem sweep found.
    ///
    /// Each source's `archive.sessionForBackfill` carries its old arm verbatim, including the
    /// four parsers that take a `forcedID` and codex's deliberate metadata-free minimal
    /// session. The `minimalSession` fallback is unchanged too — it just lives on
    /// `SessionArchiveBackfill` now (one copy, formerly a private twin here).
    ///
    /// The `?? minimalSession` fallback no longer reaches a source that declines archiving:
    /// `syncPinnedSessions` skips those per source before any backfill arm runs, and `pin`
    /// returns early. It stays because a source *with* an `ArchiveCapability` whose
    /// `sessionForBackfill` returns nil still needs a session to pin.
    private func resolveSessionForBackfill(source: SessionSource, sessionID: String, upstreamURL: URL) -> Session? {
        SessionSourceRegistry.descriptor(for: source).archive?.sessionForBackfill(sessionID, upstreamURL)
            ?? SessionArchiveBackfill.minimalSession(source: source, id: sessionID, url: upstreamURL)
    }

    private func ensureArchiveExistsAndSync(session: Session, reason: String) {
        guard let authority = authoritativeArchiveSession(session) else {
            log("sync rejected source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_unavailable")
            return
        }
        guard case .live(let authoritativeSession, let authorityToken) = authority else {
            log("sync retained archive source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_absent")
            return
        }
        ensureArchiveExistsAndSyncUnvalidated(authoritativeSession,
                                               reason: reason,
                                               authorityToken: authorityToken)
    }

    private func ensureArchiveExistsAndSyncUnvalidated(_ session: Session,
                                                       reason: String,
                                                       authorityToken: CursorACPAuthorityToken? = nil) {
        // A saved successor remains authoritative even if the live source later
        // exposes only an older generation (including through a re-star).
        guard !wouldDowngradeDSHArchive(session) else { return }
        let unit = Self.archiveUnit(for: session)
        var info = SessionArchiveInfo(
            sessionID: session.id,
            source: session.source,
            surface: session.surface,
            upstreamPath: unit.root.path,
            upstreamIsDirectory: unit.isDirectory,
            primaryRelativePath: unit.primaryRelativePath,
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

        // If archive already exists, keep its identity and sync history, but let a
        // directory-artifact source advance its selected primary generation. DSH
        // publishes immutable successors (v2 -> v3) under the same session root;
        // retaining the old primary here would permanently pin the archive to v2.
        if var existing = loadInfoIfExists(source: session.source, id: session.id) {
            let isCursorArchiveFallback = session.source == .cursor &&
                SessionArchiveInfo.isCursorACPIdentity(session.id) &&
                isArchivedPrimary(session: session)
            let isCurrentACPDirectoryUnit = session.source == .cursor &&
                SessionArchiveInfo.isCursorACPIdentity(session.id) &&
                info.upstreamIsDirectory &&
                info.primaryRelativePath == "store.db"
            if (session.source == .deepseekHarness || isCurrentACPDirectoryUnit) &&
               !isCursorArchiveFallback {
                existing.upstreamPath = info.upstreamPath
                existing.upstreamIsDirectory = info.upstreamIsDirectory
                existing.primaryRelativePath = info.primaryRelativePath
            }
            existing.surface = info.surface
            existing.startTime = info.startTime
            existing.endTime = info.endTime
            existing.model = info.model
            existing.cwd = info.cwd
            existing.title = info.title
            existing.estimatedEventCount = info.estimatedEventCount
            existing.estimatedCommands = info.estimatedCommands
            info = existing
        }

        ensureArchiveExistsAndSync(info: &info,
                                   reason: reason,
                                   authorityToken: authorityToken)
    }

    private func writePinPlaceholder(session: Session, key: String) {
        guard let authority = authoritativeArchiveSession(session) else {
            log("pin placeholder rejected source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_unavailable")
            return
        }
        guard case .live(let session, _) = authority else {
            log("pin placeholder retained archive source=\(session.source.rawValue) id=\(session.id) reason=current_acp_authority_absent")
            return
        }
        guard !wouldDowngradeDSHArchive(session) else { return }
        var info = Self.archivePlaceholder(for: session)

        if var existing = loadInfoIfExists(source: session.source, id: session.id) {
            // A pinned fallback points at the copied primary inside its own
            // archive. Keep the recorded live directory as the sync source;
            // treating that archive primary as a new single-file upstream would
            // replace the ACP directory archive and drop meta.json.
            let sessionPath = URL(fileURLWithPath: session.filePath).standardizedFileURL
            let existingArchivePath = archivedPrimaryPath(info: existing)?.standardizedFileURL
            if existingArchivePath != sessionPath {
                existing.upstreamPath = info.upstreamPath
                existing.upstreamIsDirectory = info.upstreamIsDirectory
                existing.primaryRelativePath = info.primaryRelativePath
            }
            existing.status = .staging
            existing.lastError = nil

            existing.surface = info.surface
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
            try withArchiveMutationLock(source: session.source) {
                try writeInfo(info)
            }
            log("pin placeholder written source=\(session.source.rawValue) id=\(session.id)")
            if let metaURL = metaURL(source: session.source, id: session.id) {
                log("pin meta path=\(metaURL.path)")
                let metaExists = FileManager.default.fileExists(atPath: metaURL.path)
                log("pin meta exists=\(metaExists) source=\(session.source.rawValue) id=\(session.id)")
            }
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
        guard let appSupport = resolveApplicationSupportDirectoryURL() else { return nil }
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
        if source == .cursor, sessionID.hasPrefix("cursor-acp:") {
            guard isCurrentCursorACPStore(URL(fileURLWithPath: path), sessionID: sessionID) else {
                return nil
            }
        }
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
        let isACP = source == .cursor && CursorACPStoreReader.isACPStore(URL(fileURLWithPath: path))

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
            lightweightCommands: commands,
            originator: isACP ? "cursor-agent" : nil,
            originSource: isACP ? "acp-persisted" : nil,
            surface: isACP ? .acp : nil
        )
    }

    private func ensureArchiveExistsAndSync(info: inout SessionArchiveInfo,
                                            reason: String,
                                            authorityToken: CursorACPAuthorityToken? = nil) {
        let originalInfo = info
        do {
            // Keep rollback metadata handling under the same cross-process
            // lock as commit/recovery. Otherwise a late failure can validate
            // one directory and then write stale metadata into a replacement
            // installed by another AgentSessions process.
            try withArchiveMutationLock(source: info.source) {
                let originalPersistedInfo = loadInfoIfExists(source: info.source,
                                                             id: info.sessionID)
                let originalArchiveIdentity = archiveEntryIdentity(source: info.source,
                                                                    id: info.sessionID)
                do {
                    log("sync start source=\(info.source.rawValue) id=\(info.sessionID) reason=\(reason)")
                    try ensureSynced(info: &info,
                                     reason: reason,
                                     authorityToken: authorityToken,
                                     persistCanonicalStagingMetadata: originalArchiveIdentity != nil)
                    log("sync done source=\(info.source.rawValue) id=\(info.sessionID) status=\(info.status.rawValue)")
                } catch {
                    let stillOwnsOriginalArchive = originalArchiveIdentity != nil &&
                        archiveEntryIdentity(source: info.source, id: info.sessionID) == originalArchiveIdentity
                    if let archiveError = error as? ArchiveManifestError,
                       case .authorityUnavailable = archiveError {
                        // A late operational outage is not an archive error
                        // and must not leave a staging placeholder or mutate a
                        // directory that appeared after this transaction began.
                        // In particular, never delete by the stale observation
                        // that no archive existed at the start.
                        info = originalInfo
                        if let originalPersistedInfo, stillOwnsOriginalArchive {
                            try? writeInfo(originalPersistedInfo)
                        }
                        reloadCache()
                        log("sync deferred source=\(info.source.rawValue) id=\(info.sessionID) reason=authority_unavailable")
                        return
                    }

                    info.status = .error
                    info.lastError = error.localizedDescription
                    // Error metadata is useful only when the final pathname
                    // is still the directory this transaction observed. A
                    // replacement must remain byte-for-byte untouched.
                    if stillOwnsOriginalArchive {
                        try? writeInfo(info)
                    }
                    reloadCache()
                    log("sync error source=\(info.source.rawValue) id=\(info.sessionID) error=\(error.localizedDescription)")
                }
            }
        } catch {
            // Lock acquisition failure is itself indeterminate. Do not write
            // or delete through an unprotected pathname; retain the caller's
            // in-memory state and retry during a later sync.
            info = originalInfo
            log("sync deferred source=\(info.source.rawValue) id=\(info.sessionID) reason=archive_lock_unavailable error=\(error.localizedDescription)")
        }
    }

    private func ensureSynced(info: inout SessionArchiveInfo,
                              reason: String,
                              authorityToken: CursorACPAuthorityToken? = nil,
                              persistCanonicalStagingMetadata: Bool = true) throws {
        let fm = FileManager.default
        let upstreamURL: URL
        let upstreamExists: Bool
        if let authorityToken,
           info.source == .cursor,
           SessionArchiveInfo.isCursorACPIdentity(info.sessionID) {
            // `fileExists` cannot distinguish a removed ACP store from a
            // temporarily inaccessible root. Re-resolve through the typed
            // authority path while the caller's token is still in scope.
            switch resolveCurrentCursorACPSession(sessionID: info.sessionID) {
            case .found(let current, let currentToken):
                guard currentToken == authorityToken else {
                    throw ArchiveManifestError.authorityChanged(id: info.sessionID)
                }
                upstreamURL = Self.archiveUnit(for: current).root
                upstreamExists = true
            case .absent:
                upstreamURL = URL(fileURLWithPath: info.upstreamPath)
                upstreamExists = false
            case .unavailable:
                // Preserve the committed metadata and archive exactly as-is.
                // In particular, an unavailable root must never become
                // `upstreamMissing = true`.
                log("sync upstream authority unavailable source=\(info.source.rawValue) id=\(info.sessionID) reason=\(reason)")
                return
            }
        } else {
            upstreamURL = URL(fileURLWithPath: info.upstreamPath)
            upstreamExists = fm.fileExists(atPath: upstreamURL.path)
        }
        info.lastUpstreamSeenAt = upstreamExists ? Date() : info.lastUpstreamSeenAt
        info.upstreamMissing = !upstreamExists

        let sourceDescriptor = try openArchiveSourceDirectory(source: info.source, create: true)
        Darwin.close(sourceDescriptor)

        guard upstreamExists else {
            // Upstream missing: only a complete committed snapshot can become a
            // final fallback. A directory alone is not proof that its manifest
            // companions survived.
            if archiveSessionDirectoryExists(source: info.source, id: info.sessionID) {
                if hasCompleteArchivedSnapshot(info: info) {
                    info.status = .final
                    info.lastError = nil
                } else {
                    info.status = .error
                    info.lastError = "Archived snapshot is incomplete; preserving it without publishing a fallback"
                }
                try writeInfo(info)
                reloadCache()
            }
            log("sync upstream missing source=\(info.source.rawValue) id=\(info.sessionID) path=\(info.upstreamPath)")
            return
        }

        // A failed read of the committed archive is not evidence that it is
        // safe to replace. Establish the current final state before creating
        // staging bytes; an operationally unavailable final must remain the
        // authority until the filesystem can be read again.
        switch finalArchiveValidation(source: info.source, id: info.sessionID) {
        case .valid, .invalid:
            break
        case .unavailable:
            throw ArchiveManifestError.archiveValidationUnavailable(id: info.sessionID)
        }

        // Decide whether to sync.
        let existingManifest: SessionArchiveManifest? = {
            guard let data = readArchiveFile(source: info.source,
                                             id: info.sessionID,
                                             name: "manifest.json") else { return nil }
            return try? JSONDecoder().decode(SessionArchiveManifest.self, from: data)
        }()

        // A provider-filtered set is re-resolved for every snapshot. This is
        // important for live stores whose companion files can appear during a
        // copy (for example, SQLite creating a WAL). A seam that returns nil
        // throws below and commits nothing (fail closed).
        let usesProviderManifest = info.upstreamIsDirectory &&
            SessionSourceRegistry.descriptor(for: info.source).archive?.manifestEntries != nil

        func takeSnapshot() throws -> SessionArchiveManifest {
            if info.upstreamIsDirectory,
               let entries = try resolveProviderEntries(source: info.source,
                                                        upstream: upstreamURL,
                                                        primaryRelativePath: info.primaryRelativePath,
                                                        sessionID: info.sessionID) {
                return try snapshotFilteredManifest(at: upstreamURL,
                                                    entries: entries,
                                                    primaryRelativePath: info.primaryRelativePath)
            }
            return try scanUpstreamSnapshot(at: upstreamURL, primaryRelativePath: info.primaryRelativePath)
        }

        func stagedSizeBytes(dataRoot: URL, manifest: SessionArchiveManifest) throws -> Int64 {
            // The staging dir holds exactly the copied manifest entries, so the
            // filtered path sums those staged files (same set, no re-scan).
            if usesProviderManifest {
                return try filteredStagedSizeBytes(dataRoot: dataRoot, manifest: manifest)
            }
            return try computeArchiveSizeBytes(dataRoot: dataRoot)
        }

        try requireCurrentAuthority(authorityToken, sessionID: info.sessionID)
#if DEBUG
        SessionArchiveManagerTestHooks.preSnapshotHook?()
#endif
        let snapshotBefore = try takeSnapshot()
        guard authoritySnapshotMatches(snapshotBefore, token: authorityToken) else {
            throw ArchiveManifestError.authorityChanged(id: info.sessionID)
        }

        func validateStagedSnapshot(at stagingSessionRoot: URL,
                                    info: SessionArchiveInfo,
                                    manifest: SessionArchiveManifest) throws {
            let sessionDescriptor = try openDirectoryDescriptor(at: stagingSessionRoot,
                                                                 create: false)
            defer { Darwin.close(sessionDescriptor) }
            let dataDescriptor = try openDirectoryChild(sessionDescriptor,
                                                        name: "data",
                                                        create: false)
            defer { Darwin.close(dataDescriptor) }

            switch validateBoundArchiveTree(info: info,
                                            manifest: manifest,
                                            sessionDescriptor: sessionDescriptor,
                                            dataDescriptor: dataDescriptor) {
            case .valid:
                return
            case .invalid:
                if info.isCursorACPArchive {
                    throw ArchiveManifestError.invalidACPSnapshot(id: info.sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotInvalid(id: info.sessionID)
            case .unavailable:
                if info.isCursorACPArchive {
                    throw ArchiveManifestError.unavailableACPSnapshot(id: info.sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotUnavailable(id: info.sessionID)
            }
        }

        // Only surface the "Saving…" staging state when we actually need to copy.
        // Otherwise periodic sync checks can cause UI flicker even when nothing changes.
        let archiveIsComplete: Bool = {
            guard let existingManifest else { return false }
            return hasCompleteArchivedSnapshot(info: info, manifest: existingManifest)
        }()
        let isNoop = (existingManifest != nil && existingManifest == snapshotBefore && archiveIsComplete)
        if !isNoop {
            info.status = .staging
            // A first sync has no committed archive to update yet. Keeping
            // this state in memory avoids creating a canonical metadata-only
            // directory that an early copy/authority failure could strand.
            if persistCanonicalStagingMetadata {
                try writeInfo(info)
                reloadCache()
            }
        }

        if isNoop {
            // No changes; maybe transition to final if quiet long enough.
            try requireCurrentAuthority(authorityToken, sessionID: info.sessionID)
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
            defer { removeArchiveStagingDirectory(source: info.source, staging: staging) }

            let stagingSessionRoot = staging.appendingPathComponent(info.sessionID, isDirectory: true)
            let stagingDataRoot = try prepareStagingDataRoot(at: stagingSessionRoot)
            log("sync staging created path=\(stagingSessionRoot.path) exists=\(fm.fileExists(atPath: stagingSessionRoot.path))")

#if DEBUG
            SessionArchiveManagerTestHooks.preCopyHook?()
#endif
            try copySnapshot(snapshot, from: upstreamURL, upstreamIsDirectory: info.upstreamIsDirectory, to: stagingDataRoot)
#if DEBUG
            SessionArchiveManagerTestHooks.postCopyHook?()
#endif
            // Re-resolve filtered entries so companion appearance/removal is
            // part of the stability comparison; legacy nil-seam paths still
            // re-enumerate exactly as before.
            let snapshotAfter = try takeSnapshot()
#if DEBUG
            SessionArchiveManagerTestHooks.postSnapshotHook?()
#endif

            if snapshotAfter == snapshot {
                // Stable enough to commit.
                guard authoritySnapshotMatches(snapshot, token: authorityToken) else {
                    throw ArchiveManifestError.authorityChanged(id: info.sessionID)
                }
                var committedInfo = info
                committedInfo.status = .syncing
                committedInfo.lastSyncAt = Date()
                committedInfo.lastUpstreamSeenAt = Date()
                committedInfo.lastError = nil
                committedInfo.upstreamMissing = false
                committedInfo.lastUpstreamChangeAt = committedInfo.lastSyncAt
                committedInfo.archiveSizeBytes = try stagedSizeBytes(dataRoot: stagingDataRoot, manifest: snapshot)

                try writeStagedArchiveFiles(at: stagingSessionRoot,
                                            info: committedInfo,
                                            manifest: snapshot)

                try validateStagedSnapshot(at: stagingSessionRoot,
                                           info: committedInfo,
                                           manifest: snapshot)
#if DEBUG
                SessionArchiveManagerTestHooks.afterStagedValidationHook?(stagingSessionRoot)
#endif
                try requireCurrentAuthority(authorityToken, sessionID: info.sessionID)
                try commitStaging(stagingSessionRoot,
                                  source: info.source,
                                  sessionID: info.sessionID,
                                  expectedInfo: committedInfo,
                                  expectedManifest: snapshot,
                                  authorityToken: authorityToken)
                if let final = sessionRoot(source: info.source, id: info.sessionID) {
                    log("sync commit final=\(final.path) exists=\(fm.fileExists(atPath: final.path))")
                }
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

        // A source requiring stable snapshots fails closed after the retry
        // budget: no unchecked fifth copy/commit, so an existing healthy
        // archive is never replaced by a torn read. The throw propagates
        // through the existing archive error/status handling (status .error,
        // lastError surfaced, staged data discarded).
        if info.upstreamIsDirectory,
           SessionSourceRegistry.descriptor(for: info.source).archive?.requiresStableSnapshot == true {
            throw ArchiveManifestError.upstreamUnstable(source: info.source.rawValue, id: info.sessionID)
        }

        // If upstream is churning, commit a best-effort snapshot and keep syncing.
        let staging = try makeStagingDir(source: info.source, sessionID: info.sessionID)
        defer { removeArchiveStagingDirectory(source: info.source, staging: staging) }
        let stagingSessionRoot = staging.appendingPathComponent(info.sessionID, isDirectory: true)
        let stagingDataRoot = try prepareStagingDataRoot(at: stagingSessionRoot)
        try copySnapshot(snapshot, from: upstreamURL, upstreamIsDirectory: info.upstreamIsDirectory, to: stagingDataRoot)

        var committedInfo = info
        committedInfo.status = .syncing
        committedInfo.lastSyncAt = Date()
        committedInfo.lastUpstreamSeenAt = Date()
        committedInfo.upstreamMissing = false
        committedInfo.lastUpstreamChangeAt = committedInfo.lastSyncAt
        committedInfo.archiveSizeBytes = try stagedSizeBytes(dataRoot: stagingDataRoot, manifest: snapshot)
        committedInfo.lastError = "Session was updating continuously; archived a best-effort snapshot (reason=\(reason))"

        try writeStagedArchiveFiles(at: stagingSessionRoot,
                                    info: committedInfo,
                                    manifest: snapshot)
        try validateStagedSnapshot(at: stagingSessionRoot,
                                   info: committedInfo,
                                   manifest: snapshot)
#if DEBUG
        SessionArchiveManagerTestHooks.afterStagedValidationHook?(stagingSessionRoot)
#endif
        try requireCurrentAuthority(authorityToken, sessionID: info.sessionID)
        try commitStaging(stagingSessionRoot,
                          source: info.source,
                          sessionID: info.sessionID,
                          expectedInfo: committedInfo,
                          expectedManifest: snapshot,
                          authorityToken: authorityToken)
        if let final = sessionRoot(source: info.source, id: info.sessionID) {
            log("sync commit final=\(final.path) exists=\(fm.fileExists(atPath: final.path))")
        }
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
#if DEBUG
            guard SessionArchiveManagerTestHooks.upstreamEnumerationHook?() ?? true else {
                throw ArchiveManifestError.filteredEntryInvalid(path: primaryRelativePath)
            }
#endif
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: upstream,
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles],
                                                 errorHandler: { _, error in
                                                     enumerationError = error
                                                     return false
                                                 }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let rootComponents = upstream.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            var entries: [SessionArchiveManifest.Entry] = []
            while let url = enumerator.nextObject() as? URL {
                let rv = try url.resourceValues(forKeys: Set(keys))
                guard rv.isRegularFile == true else { continue }
                let fileComponents = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard fileComponents.starts(with: rootComponents),
                      fileComponents.count > rootComponents.count else { continue }
                let rel = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
                let size = Int64(rv.fileSize ?? 0)
                let mtime = (rv.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
                entries.append(.init(relativePath: rel,
                                     sizeBytes: size,
                                     mtimeSeconds: mtime,
                                     sha256: try hashFileNoFollow(at: url)))
            }
            if let enumerationError { throw enumerationError }
            entries.sort { $0.relativePath < $1.relativePath }
            guard entries.contains(where: { $0.relativePath == primaryRelativePath }) else {
                throw ArchiveManifestError.filteredEntryInvalid(path: primaryRelativePath)
            }
            return SessionArchiveManifest(entries: entries)
        } else {
            let rv = try upstream.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(rv.fileSize ?? 0)
            let mtime = (rv.contentModificationDate ?? Date.distantPast).timeIntervalSince1970
            return SessionArchiveManifest(entries: [
                .init(relativePath: primaryRelativePath,
                      sizeBytes: size,
                      mtimeSeconds: mtime,
                      sha256: try hashFileNoFollow(at: upstream))
            ])
        }
    }

    // Safety boundary for provider-filtered directory archives: nil means no
    // seam (legacy scan). A seam result is used verbatim as the manifest set;
    // a nil seam result throws so nothing is committed.
    private func resolveProviderEntries(source: SessionSource, upstream: URL, primaryRelativePath: String, sessionID: String) throws -> [String]? {
        guard let filter = SessionSourceRegistry.descriptor(for: source).archive?.manifestEntries else { return nil }
        guard let entries = filter(upstream, primaryRelativePath) else {
            throw ArchiveManifestError.providerManifestUnavailable(source: source.rawValue, id: sessionID)
        }
        return entries
    }

    // Stats exactly the provider-filtered set: no directory enumeration, no
    // widening. Rejects path escapes and non-regular files even if a provider
    // filter is buggy, and requires the primary to be present. Sorted output
    // keeps manifests deterministic.
    private func snapshotFilteredManifest(at upstream: URL, entries: [String], primaryRelativePath: String) throws -> SessionArchiveManifest {
        guard entries.contains(primaryRelativePath) else {
            throw ArchiveManifestError.filteredEntryInvalid(path: primaryRelativePath)
        }
        var out: [SessionArchiveManifest.Entry] = []
        for rel in entries {
            guard !rel.isEmpty, !rel.contains("/"), rel != ".", rel != ".." else {
                throw ArchiveManifestError.filteredEntryInvalid(path: rel)
            }
            let url = upstream.appendingPathComponent(rel, isDirectory: false)
            let fileStat = try fileStatNoFollow(at: url)
            guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
                throw ArchiveManifestError.filteredEntryInvalid(path: rel)
            }
            let size = Int64(fileStat.st_size)
            let mtime = TimeInterval(fileStat.st_mtimespec.tv_sec)
            let identity = fileIdentity(fileStat)
            let digest = try hashFileNoFollow(at: url)
            out.append(.init(relativePath: rel,
                             sizeBytes: size,
                             mtimeSeconds: mtime,
                             mtimeNanoseconds: Int64(fileStat.st_mtimespec.tv_nsec),
                             sha256: digest,
                             fileIdentity: identity))
        }
        out.sort { $0.relativePath < $1.relativePath }
        return SessionArchiveManifest(entries: out)
    }

    // Sums exactly the staged manifest entries (same filtered set as the
    // snapshot and copy); the staging dir holds only those files.
    private func filteredStagedSizeBytes(dataRoot: URL, manifest: SessionArchiveManifest) throws -> Int64 {
        var total: Int64 = 0
        for e in manifest.entries {
            guard !e.relativePath.isEmpty, !e.relativePath.contains("/"), e.relativePath != ".", e.relativePath != ".." else {
                throw ArchiveManifestError.filteredEntryInvalid(path: e.relativePath)
            }
            let url = dataRoot.appendingPathComponent(e.relativePath, isDirectory: false)
            let rv = try url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(rv.fileSize ?? 0)
        }
        return total
    }

    private func validateArchivedManifestEntry(_ entry: SessionArchiveManifest.Entry,
                                               dataDescriptor: Int32) -> ArchivedSnapshotValidation {
        guard isSafeArchiveRelativePath(entry.relativePath),
              entry.sizeBytes >= 0,
              let expectedHash = entry.sha256,
              !expectedHash.isEmpty else {
            // A legacy hashless entry cannot be trusted as authority for
            // destroying recovery state. New manifests record full hashes.
            return entry.sha256 == nil ? .unavailable : .invalid
        }
        switch openArchiveFileDescriptor(entry.relativePath, under: dataDescriptor) {
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        case .opened(let descriptor):
            defer { Darwin.close(descriptor) }

            var fileStat = stat()
            guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG,
                  Int64(fileStat.st_size) == entry.sizeBytes else { return .invalid }

            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var hasher = SHA256()
            do {
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            } catch {
                return .unavailable
            }
            let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return actualHash == expectedHash ? .valid : .invalid
        }
    }

    private func validateArchivedSnapshot(info: SessionArchiveInfo,
                                          manifest: SessionArchiveManifest? = nil) -> ArchivedSnapshotValidation {
        guard isValidArchiveInfo(info, source: info.source, id: info.sessionID),
              let dataRoot = dataRootURL(source: info.source, id: info.sessionID) else {
            return .invalid
        }

        let loadedManifest: SessionArchiveManifest
        if let manifest {
            loadedManifest = manifest
        } else {
            switch readArchiveFileForValidation(source: info.source,
                                                id: info.sessionID,
                                                name: "manifest.json") {
            case .data(let manifestData):
                guard let decoded = try? JSONDecoder().decode(SessionArchiveManifest.self,
                                                               from: manifestData) else {
                    return .invalid
                }
                loadedManifest = decoded
            case .missing, .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }

        guard loadedManifest.entries.contains(where: { $0.relativePath == info.primaryRelativePath }) else {
            return .invalid
        }
        let dataDescriptor: Int32
        do {
            dataDescriptor = try openDirectoryDescriptor(at: dataRoot, create: false)
        } catch {
            switch classifyArchiveValidationFailure(error) {
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            case .valid:
                return .unavailable
            }
        }
        defer { Darwin.close(dataDescriptor) }
        for entry in loadedManifest.entries {
            switch validateArchivedManifestEntry(entry, dataDescriptor: dataDescriptor) {
            case .valid:
                continue
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }

        if info.isCursorACPArchive {
            let primary = dataRoot.appendingPathComponent(info.primaryRelativePath, isDirectory: false)
            switch CursorACPStoreReader.validateArchivedSnapshot(at: primary,
                                                                  expectedSessionID: info.sessionID) {
            case .valid:
                return .valid
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }
        return .valid
    }

    /// Validates one already-bound archive tree. Every decision here is made
    /// through the supplied descriptors; no canonical archive pathname is
    /// reopened after the caller binds the session directory.
    private func validateBoundArchiveTree(info: SessionArchiveInfo,
                                          manifest: SessionArchiveManifest,
                                          sessionDescriptor: Int32,
                                          dataDescriptor: Int32) -> ArchivedSnapshotValidation {
        guard isValidArchiveInfo(info, source: info.source, id: info.sessionID),
              !manifest.entries.isEmpty,
              manifest.entries.count == Set(manifest.entries.map(\.relativePath)).count,
              manifest.entries.contains(where: { $0.relativePath == info.primaryRelativePath }) else {
            return .invalid
        }

        let expectedRootEntries = Set(["meta.json", "manifest.json", "data"])
        let rootEntries: [String]
        do {
            rootEntries = try directoryEntryNames(in: sessionDescriptor)
        } catch {
            return .unavailable
        }
        guard Set(rootEntries) == expectedRootEntries else { return .invalid }

        let savedInfo: SessionArchiveInfo
        switch readArchiveFileForValidation(in: sessionDescriptor, name: "meta.json") {
        case .data(let data):
            guard let decoded = try? JSONDecoder().decode(SessionArchiveInfo.self, from: data) else {
                return .invalid
            }
            savedInfo = decoded
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
        guard savedInfo == info else { return .invalid }

        switch readArchiveFileForValidation(in: sessionDescriptor, name: "manifest.json") {
        case .data(let data):
            guard let decoded = try? JSONDecoder().decode(SessionArchiveManifest.self, from: data),
                  decoded == manifest else {
                return .invalid
            }
        case .missing, .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        if info.isCursorACPArchive {
            let allowed = Set(["store.db", "meta.json", "store.db-wal"])
            guard Set(manifest.entries.map(\.relativePath)).isSubset(of: allowed) else {
                return .invalid
            }
        }

        switch archiveDataFileNames(in: dataDescriptor) {
        case .entries(let names):
            guard Set(names) == Set(manifest.entries.map(\.relativePath)) else {
                return .invalid
            }
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }

        for entry in manifest.entries {
            switch validateArchivedManifestEntry(entry, dataDescriptor: dataDescriptor) {
            case .valid:
                continue
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        }

        guard info.isCursorACPArchive else { return .valid }

#if DEBUG
        if CursorACPStoreReader.archiveValidationUnavailableHook?() == true {
            return .unavailable
        }
#endif

        let fm = FileManager.default
        let validationRoot = fm.temporaryDirectory
            .appendingPathComponent("AgentSessions-ACP-Archive-Validation-\(UUID().uuidString)",
                                    isDirectory: true)
        let validationDataRoot = validationRoot.appendingPathComponent("data", isDirectory: true)
        defer { try? fm.removeItem(at: validationRoot) }

        do {
            try fm.createDirectory(at: validationDataRoot, withIntermediateDirectories: true)
            for entry in manifest.entries {
                let destination = validationDataRoot.appendingPathComponent(entry.relativePath,
                                                                              isDirectory: false)
                try copyVerifiedArchiveFileForValidation(fromDirectory: dataDescriptor,
                                                         relativePath: entry.relativePath,
                                                         to: destination,
                                                         expected: entry)
            }

#if DEBUG
            if CursorACPStoreReader.archiveParseOperationalFailureHook?() == true {
                return .unavailable
            }
#endif

            let validationPrimary = validationDataRoot.appendingPathComponent(
                info.primaryRelativePath,
                isDirectory: false
            )
            switch CursorACPStoreReader.validateTrustedSnapshot(at: validationPrimary,
                                                                expectedSessionID: info.sessionID) {
            case .valid(let parsed) where parsed.id == info.sessionID:
                return .valid
            case .valid, .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        } catch let failure as ArchiveSnapshotCopyFailure {
            switch failure {
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// Validation is only useful for destructive cleanup when the directory
    /// entry that was validated can be identified again. Keep that identity
    /// beside the result so callers can fail closed before deleting a backup.
    private func validateBoundArchiveTreeWithIdentity(
        info: SessionArchiveInfo,
        manifest: SessionArchiveManifest,
        sessionDescriptor: Int32,
        dataDescriptor: Int32
    ) -> (validation: ArchivedSnapshotValidation, identity: String?) {
        // The descriptor is the object that was actually inspected. Preserve
        // its identity for every result, not only `.valid`: an invalid tree
        // must not later authorize pathname cleanup of a replacement tree.
        guard let identity = directoryIdentity(sessionDescriptor) else {
            return (.unavailable, nil)
        }
        let validation = validateBoundArchiveTree(info: info,
                                                  manifest: manifest,
                                                  sessionDescriptor: sessionDescriptor,
                                                  dataDescriptor: dataDescriptor)
        return (validation, identity)
    }

    private func archiveDataFileNames(in dataDescriptor: Int32) -> ArchiveDataFileNamesResult {
        func walk(_ descriptor: Int32, prefix: String) throws -> [String] {
            var files: [String] = []
            for name in try directoryEntryNames(in: descriptor) {
                guard isSafeArchiveComponent(name) else {
                    throw ArchiveDirectoryValidationFailure.invalid
                }
                let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var entryStat = stat()
                guard name.withCString({
                    Darwin.fstatat(descriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
                }) == 0 else {
                    throw ArchiveDirectoryValidationFailure.unavailable
                }

                switch entryStat.st_mode & S_IFMT {
                case S_IFREG:
                    files.append(relativePath)
                case S_IFDIR:
                    let childDescriptor: Int32
                    do {
                        childDescriptor = try openDirectoryChild(descriptor,
                                                                  name: name,
                                                                  create: false)
                    } catch {
                        switch classifyArchiveReadFailure(error) {
                        case .missing, .invalid:
                            throw ArchiveDirectoryValidationFailure.invalid
                        case .data, .unavailable:
                            throw ArchiveDirectoryValidationFailure.unavailable
                        }
                    }
                    defer { Darwin.close(childDescriptor) }
                    let nested = try walk(childDescriptor, prefix: relativePath)
                    guard !nested.isEmpty else {
                        throw ArchiveDirectoryValidationFailure.invalid
                    }
                    files.append(contentsOf: nested)
                default:
                    throw ArchiveDirectoryValidationFailure.invalid
                }
            }
            return files
        }

        do {
            return .entries(try walk(dataDescriptor, prefix: ""))
        } catch let failure as ArchiveDirectoryValidationFailure {
            switch failure {
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private func copyVerifiedArchiveFileForValidation(fromDirectory dataDescriptor: Int32,
                                                      relativePath: String,
                                                      to destination: URL,
                                                      expected: SessionArchiveManifest.Entry) throws {
        guard isSafeArchiveRelativePath(relativePath),
              expected.relativePath == relativePath,
              expected.sizeBytes >= 0,
              let expectedHash = expected.sha256,
              !expectedHash.isEmpty else {
            throw ArchiveSnapshotCopyFailure.invalid
        }

        let sourceDescriptor: Int32
        switch openArchiveFileDescriptor(relativePath, under: dataDescriptor) {
        case .opened(let descriptor):
            sourceDescriptor = descriptor
        case .missing, .invalid:
            throw ArchiveSnapshotCopyFailure.invalid
        case .unavailable:
            throw ArchiveSnapshotCopyFailure.unavailable
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStat) == 0 else {
            throw ArchiveSnapshotCopyFailure.unavailable
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG,
              Int64(sourceStat.st_size) == expected.sizeBytes else {
            throw ArchiveSnapshotCopyFailure.invalid
        }

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            throw ArchiveSnapshotCopyFailure.unavailable
        }

        let destinationDescriptor = Darwin.open(destination.path,
                                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                                                0o600)
        guard destinationDescriptor >= 0 else {
            throw ArchiveSnapshotCopyFailure.unavailable
        }
        var keepDestination = false
        defer {
            Darwin.close(destinationDescriptor)
            if !keepDestination { try? FileManager.default.removeItem(at: destination) }
        }

        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: false)
        var copiedSize: Int64 = 0
        var hasher = SHA256()
        do {
            while let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                copiedSize += Int64(chunk.count)
                hasher.update(data: chunk)
                try destinationHandle.write(contentsOf: chunk)
            }
        } catch {
            throw ArchiveSnapshotCopyFailure.unavailable
        }

        var finalSourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &finalSourceStat) == 0 else {
            throw ArchiveSnapshotCopyFailure.unavailable
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copiedSize == expected.sizeBytes,
              finalSourceStat.st_size == sourceStat.st_size,
              actualHash == expectedHash else {
            throw ArchiveSnapshotCopyFailure.invalid
        }
        keepDestination = true
    }

    private func hasCompleteArchivedSnapshot(info: SessionArchiveInfo,
                                             manifest: SessionArchiveManifest? = nil) -> Bool {
        if case .valid = validateArchivedSnapshot(info: info, manifest: manifest) {
            return true
        }
        return false
    }

    // Copies exactly the manifest entries. Directory archives copy each listed
    // relative path; filtered providers (DSH) supply a flat sibling set, so no
    // recursive walk ever runs for them.
    private func copySnapshot(_ manifest: SessionArchiveManifest, from upstream: URL, upstreamIsDirectory: Bool, to destDataRoot: URL) throws {
        let destinationRootDescriptor = try openDirectoryDescriptor(at: destDataRoot, create: true)
        defer { Darwin.close(destinationRootDescriptor) }

        if upstreamIsDirectory {
            for e in manifest.entries {
                let src = upstream.appendingPathComponent(e.relativePath, isDirectory: false)
                let components = e.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard let fileComponent = components.last,
                      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw ArchiveManifestError.filteredEntryInvalid(path: e.relativePath)
                }
                let parentPath = components.dropLast().joined(separator: "/")
                let parentDescriptor = try openRelativeDirectory(parentPath,
                                                                  under: destinationRootDescriptor,
                                                                  create: true)
                do {
                    try copyRegularFileNoFollow(from: src,
                                                toDirectory: parentDescriptor,
                                                fileName: String(fileComponent),
                                                expected: e)
                    try syncDescriptor(parentDescriptor, path: e.relativePath)
                } catch {
                    Darwin.close(parentDescriptor)
                    throw error
                }
                Darwin.close(parentDescriptor)
            }
        } else {
            guard let e = manifest.entries.first else { return }
            try copyRegularFileNoFollow(from: upstream,
                                        toDirectory: destinationRootDescriptor,
                                        fileName: e.relativePath,
                                        expected: e)
            try syncDescriptor(destinationRootDescriptor, path: e.relativePath)
        }
        try syncDescriptor(destinationRootDescriptor, path: destDataRoot.path)
    }

    private func copyRegularFileNoFollow(from source: URL,
                                         toDirectory destinationDirectory: Int32,
                                         fileName: String,
                                         expected: SessionArchiveManifest.Entry? = nil) throws {
        guard isSafeArchiveComponent(fileName) else {
            throw ArchiveManifestError.filteredEntryInvalid(path: fileName)
        }
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSFilePathErrorKey: source.path])
        }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStat = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStat) == 0,
              (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(EFTYPE),
                          userInfo: [NSFilePathErrorKey: source.path])
        }

        if let expected {
            guard sourceStat.st_size == off_t(expected.sizeBytes),
                  expected.fileIdentity == nil || expected.fileIdentity == fileIdentity(sourceStat) else {
                throw NSError(domain: NSPOSIXErrorDomain,
                              code: Int(EAGAIN),
                              userInfo: [NSFilePathErrorKey: source.path])
            }
        }

        let destinationDescriptor = fileName.withCString {
            Darwin.openat(destinationDirectory,
                          $0,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                          0o600)
        }
        guard destinationDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSFilePathErrorKey: fileName])
        }
        var removeDestination = true
        defer {
            Darwin.close(destinationDescriptor)
            if removeDestination {
                _ = fileName.withCString { Darwin.unlinkat(destinationDirectory, $0, 0) }
            }
        }

        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            try destinationHandle.write(contentsOf: chunk)
        }
        if let expectedHash = expected?.sha256 {
            let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualHash == expectedHash else {
                throw NSError(domain: NSPOSIXErrorDomain,
                              code: Int(EAGAIN),
                              userInfo: [NSFilePathErrorKey: source.path])
            }
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw posixError(path: fileName)
        }
        removeDestination = false
    }

    private func isSafeArchiveComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }

    private func posixError(path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path])
    }

    private func syncDescriptor(_ descriptor: Int32, path: String) throws {
#if DEBUG
        if SessionArchiveManagerTestHooks.recoverySyncHook?() == false {
            throw posixError(path: path)
        }
#endif
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(path: path)
        }
    }

    /// Opens an absolute directory path one component at a time. Every
    /// component is opened with O_NOFOLLOW, so a path substitution after the
    /// check cannot redirect later archive I/O through a symlink.
    private func openDirectoryDescriptor(at url: URL, create: Bool) throws -> Int32 {
        let path = try lexicallyNormalizedAbsolutePath(url)
        guard path.hasPrefix("/") else { throw posixError(path: path) }

        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { throw posixError(path: "/") }
        var currentDescriptor = rootDescriptor
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        for component in components {
            let nextDescriptor = try openDirectoryChild(currentDescriptor,
                                                        name: component,
                                                        create: create)
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private func lexicallyNormalizedAbsolutePath(_ url: URL) throws -> String {
        let rawPath = url.path
        guard rawPath.hasPrefix("/") else { throw posixError(path: rawPath) }

        var components: [String] = []
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { throw posixError(path: rawPath) }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func openDirectoryChild(_ parentDescriptor: Int32,
                                    name: String,
                                    create: Bool) throws -> Int32 {
        guard isSafeArchiveComponent(name) else { throw posixError(path: name) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        var descriptor = name.withCString { Darwin.openat(parentDescriptor, $0, flags) }
        if descriptor < 0, create, errno == ENOENT {
            let mkdirResult = name.withCString { Darwin.mkdirat(parentDescriptor, $0, 0o700) }
            guard mkdirResult == 0 || errno == EEXIST else { throw posixError(path: name) }
            descriptor = name.withCString { Darwin.openat(parentDescriptor, $0, flags) }
        }
        guard descriptor >= 0 else { throw posixError(path: name) }
        return descriptor
    }

    private func openRelativeDirectory(_ relativePath: String,
                                       under parentDescriptor: Int32,
                                       create: Bool) throws -> Int32 {
        var currentDescriptor = Darwin.dup(parentDescriptor)
        guard currentDescriptor >= 0 else { throw posixError(path: relativePath) }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        do {
            for component in components {
                let nextDescriptor = try openDirectoryChild(currentDescriptor,
                                                             name: component,
                                                             create: create)
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return currentDescriptor
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private func openArchiveSourceDirectory(source: SessionSource, create: Bool) throws -> Int32 {
        guard let root = sourceRoot(source) else {
            throw ArchiveRootError.applicationSupportUnavailable
        }
        return try openDirectoryDescriptor(at: root, create: create)
    }

    /// Archive transactions are shared state, not process-local cache state.
    /// Serialize mutations across AgentSessions processes before doing any
    /// pathname-based recovery work. The descriptor-bound checks below remain
    /// necessary defense in depth for an uncooperative writer or a test seam.
    private func withArchiveMutationLock<T>(source: SessionSource,
                                            _ body: () throws -> T) throws -> T {
        let sourceDescriptor = try openArchiveSourceDirectory(source: source, create: true)
        defer { Darwin.close(sourceDescriptor) }

        let lockDescriptor = Self.archiveMutationLockName.withCString {
            Darwin.openat(sourceDescriptor,
                          $0,
                          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                          0o600)
        }
        guard lockDescriptor >= 0 else {
            throw posixError(path: Self.archiveMutationLockName)
        }
        defer { Darwin.close(lockDescriptor) }

#if DEBUG
        SessionArchiveManagerTestHooks.beforeArchiveMutationLockHook?()
#endif
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw posixError(path: Self.archiveMutationLockName)
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try body()
    }

    private func openArchiveSessionDirectory(source: SessionSource,
                                             id: String,
                                             create: Bool) throws -> Int32 {
        guard isSafeArchiveComponent(source.rawValue), isSafeArchiveComponent(id) else {
            throw posixError(path: id)
        }
        let sourceDescriptor = try openArchiveSourceDirectory(source: source, create: create)
        defer { Darwin.close(sourceDescriptor) }
        return try openDirectoryChild(sourceDescriptor, name: id, create: create)
    }

    private func archiveSessionDirectoryExists(source: SessionSource, id: String) -> Bool {
        do {
            let descriptor = try openArchiveSessionDirectory(source: source, id: id, create: false)
            Darwin.close(descriptor)
            return true
        } catch {
            return false
        }
    }

    private func archiveEntryIdentity(source: SessionSource, id: String) -> String? {
        do {
            let sourceDescriptor = try openArchiveSourceDirectory(source: source, create: false)
            defer { Darwin.close(sourceDescriptor) }
            return entryIdentity(in: sourceDescriptor, name: id)
        } catch {
            return nil
        }
    }

    private func readArchiveFile(source: SessionSource, id: String, name: String) -> Data? {
        guard isSafeArchiveComponent(name) else { return nil }
        do {
            let descriptor = try openArchiveSessionDirectory(source: source, id: id, create: false)
            defer { Darwin.close(descriptor) }
            return readRegularFileNoFollow(in: descriptor, name: name)
        } catch {
            return nil
        }
    }

    private func readArchiveFileForValidation(source: SessionSource,
                                              id: String,
                                              name: String) -> ArchiveFileReadResult {
        guard isSafeArchiveComponent(name) else { return .invalid }
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try openArchiveSessionDirectory(source: source,
                                                                   id: id,
                                                                   create: false)
        } catch {
            return classifyArchiveReadFailure(error)
        }
        defer { Darwin.close(directoryDescriptor) }

        return readArchiveFileForValidation(in: directoryDescriptor, name: name)
    }

    private func readArchiveFileForValidation(in directoryDescriptor: Int32,
                                              name: String) -> ArchiveFileReadResult {
        guard isSafeArchiveComponent(name) else { return .invalid }

        let descriptor = name.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : (errno == ELOOP ? .invalid : .unavailable)
        }
        defer { Darwin.close(descriptor) }

        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else { return .unavailable }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return .invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            guard let data = try handle.readToEnd() else { return .unavailable }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    private func classifyArchiveReadFailure(_ error: Error) -> ArchiveFileReadResult {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return .unavailable }
        switch nsError.code {
        case Int(ENOENT):
            return .missing
        case Int(ELOOP), Int(ENOTDIR):
            return .invalid
        default:
            return .unavailable
        }
    }

    private func classifyArchiveValidationFailure(_ error: Error) -> ArchivedSnapshotValidation {
        switch classifyArchiveReadFailure(error) {
        case .missing, .invalid:
            return .invalid
        case .data, .unavailable:
            return .unavailable
        }
    }

    private func openArchiveFileDescriptor(_ relativePath: String,
                                           under rootDescriptor: Int32) -> ArchiveFileDescriptorResult {
        guard isSafeArchiveRelativePath(relativePath) else { return .invalid }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let fileComponent = components.last else { return .invalid }
        let parentPath = components.dropLast().joined(separator: "/")
        let parentDescriptor: Int32
        do {
            parentDescriptor = try openRelativeDirectory(parentPath,
                                                         under: rootDescriptor,
                                                         create: false)
        } catch {
            switch classifyArchiveReadFailure(error) {
            case .missing:
                return .missing
            case .invalid:
                return .invalid
            case .data, .unavailable:
                return .unavailable
            }
        }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = fileComponent.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT:
                return .missing
            case ELOOP, ENOTDIR:
                return .invalid
            default:
                return .unavailable
            }
        }

        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else {
            Darwin.close(descriptor)
            return .unavailable
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            return .invalid
        }
        return .opened(descriptor)
    }

    private func writeAtomically(_ data: Data, in directoryDescriptor: Int32, name: String) throws {
        guard isSafeArchiveComponent(name) else { throw posixError(path: name) }
        let temporaryName = ".\(name).tmp-\(UUID().uuidString)"
        let temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(directoryDescriptor,
                          $0,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                          0o600)
        }
        guard temporaryDescriptor >= 0 else { throw posixError(path: temporaryName) }

        var committed = false
        defer {
            Darwin.close(temporaryDescriptor)
            if !committed {
                _ = temporaryName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw posixError(path: temporaryName)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                Darwin.renameat(directoryDescriptor,
                                temporaryPointer,
                                directoryDescriptor,
                                namePointer)
            }
        }
        guard renameResult == 0 else { throw posixError(path: name) }
        committed = true
        try syncDescriptor(directoryDescriptor, path: name)
    }

    private func fileIdentity(_ fileStat: stat) -> String {
        "\(fileStat.st_dev):\(fileStat.st_ino)"
    }

    private func directoryIdentity(_ descriptor: Int32) -> String? {
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return fileIdentity(fileStat)
    }

    private func directoryIdentity(in parentDescriptor: Int32,
                                   name: String) -> String? {
        guard isSafeArchiveComponent(name) else { return nil }
        var entryStat = stat()
        guard name.withCString({
            Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        (entryStat.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return fileIdentity(entryStat)
    }

    private func fileStatNoFollow(at url: URL) throws -> stat {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { Darwin.close(descriptor) }
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0 else {
            throw posixError(path: url.path)
        }
        return fileStat
    }

    private func fileIdentityNoFollow(at url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { Darwin.close(descriptor) }
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(EFTYPE),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return fileIdentity(fileStat)
    }

    private func hashFileNoFollow(at url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { Darwin.close(descriptor) }
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(EFTYPE),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readRegularFileNoFollow(at url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return readRegularFileNoFollow(descriptor: descriptor, path: url.path)
    }

    private func readRegularFileNoFollow(in directoryDescriptor: Int32, name: String) -> Data? {
        guard isSafeArchiveComponent(name) else { return nil }
        let descriptor = name.withCString { Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return readRegularFileNoFollow(descriptor: descriptor, path: name)
    }

    private func readRegularFileNoFollow(descriptor: Int32, path: String) -> Data? {
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try? handle.readToEnd()
    }

    private func hasNoSymlinkComponents(_ url: URL, rootPath: String) -> Bool {
        let fm = FileManager.default
        var current = url
        while current.path.hasPrefix(rootPath + "/") || current.path == rootPath {
            guard let attrs = try? fm.attributesOfItem(atPath: current.path),
                  let type = attrs[.type] as? FileAttributeType,
                  type != .typeSymbolicLink else { return false }
            if current.path == rootPath { break }
            current = current.deletingLastPathComponent()
        }
        return true
    }

    private func removeArchiveEntry(in parentDescriptor: Int32, name: String) throws {
        guard isSafeArchiveComponent(name) else { throw posixError(path: name) }
        var entryStat = stat()
        let statResult = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw posixError(path: name) }

        guard (entryStat.st_mode & S_IFMT) == S_IFDIR else {
            let result = name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
            guard result == 0 else { throw posixError(path: name) }
            return
        }

        let directoryDescriptor = try openDirectoryChild(parentDescriptor, name: name, create: false)
        defer { Darwin.close(directoryDescriptor) }
        let duplicateDescriptor = Darwin.dup(directoryDescriptor)
        guard duplicateDescriptor >= 0,
              let directoryStream = Darwin.fdopendir(duplicateDescriptor) else {
            if duplicateDescriptor >= 0 { Darwin.close(duplicateDescriptor) }
            throw posixError(path: name)
        }
        defer { Darwin.closedir(directoryStream) }

        while let entry = Darwin.readdir(directoryStream) {
            let childName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard childName != ".", childName != ".." else { continue }
            try removeArchiveEntry(in: directoryDescriptor, name: childName)
        }

        let result = name.withCString { Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
        guard result == 0 else { throw posixError(path: name) }
    }

    private func commitStaging(_ stagingSessionRoot: URL,
                               source: SessionSource,
                               sessionID: String,
                               expectedInfo: SessionArchiveInfo,
                               expectedManifest: SessionArchiveManifest,
                               authorityToken: CursorACPAuthorityToken?) throws {
        guard let sourceRootURL = sourceRoot(source),
              isSafeArchiveComponent(sessionID) else {
            throw ArchiveRootError.applicationSupportUnavailable
        }
        let sourceDescriptor = try openDirectoryDescriptor(at: sourceRootURL, create: false)
        defer { Darwin.close(sourceDescriptor) }

        let stagingName = stagingSessionRoot.lastPathComponent
        guard isSafeArchiveComponent(stagingName) else {
            throw posixError(path: stagingName)
        }
        let stagingParentDescriptor = try openDirectoryDescriptor(
            at: stagingSessionRoot.deletingLastPathComponent(),
            create: false
        )
        defer { Darwin.close(stagingParentDescriptor) }
        let stagingDescriptor = try openDirectoryChild(stagingParentDescriptor,
                                                        name: stagingName,
                                                        create: false)
        defer { Darwin.close(stagingDescriptor) }
        let stagingDataDescriptor = try openDirectoryChild(stagingDescriptor,
                                                            name: "data",
                                                            create: false)
        defer { Darwin.close(stagingDataDescriptor) }

        func validateStagingTree() throws {
            switch validateBoundArchiveTree(info: expectedInfo,
                                            manifest: expectedManifest,
                                            sessionDescriptor: stagingDescriptor,
                                            dataDescriptor: stagingDataDescriptor) {
            case .valid:
                return
            case .invalid:
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.invalidACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotInvalid(id: sessionID)
            case .unavailable:
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.unavailableACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotUnavailable(id: sessionID)
            }
        }

        // Bind and validate the exact staging directory that will be renamed.
        // The caller validates before entering this transaction too; this late
        // descriptor-bound pass closes the mutation window between those checks.
        try validateStagingTree()

        // Revalidate immediately before touching the committed archive. The
        // caller's earlier check protects snapshot construction; this check
        // closes the long staging/validation window before the rename
        // transaction begins.
        try requireCurrentAuthority(authorityToken, sessionID: sessionID)
        try reconcileExistingBackups(source: source,
                                     sourceDescriptor: sourceDescriptor,
                                     sessionID: sessionID)
        try requireCurrentAuthority(authorityToken, sessionID: sessionID)

#if DEBUG
        SessionArchiveManagerTestHooks.beforeCommitRenameHook?()
#endif

        // A test seam and any concurrent writer can change staging after the
        // earlier admission check. Revalidate immediately before the first
        // rename so no unchecked tree can become the committed final.
        try validateStagingTree()

        var finalStat = stat()
        let finalExists = sessionID.withCString {
            Darwin.fstatat(sourceDescriptor, $0, &finalStat, AT_SYMLINK_NOFOLLOW) == 0
        }

        func validateInstalledTree() -> (validation: ArchivedSnapshotValidation,
                                          identity: String?) {
            let installedDescriptor: Int32
            do {
                installedDescriptor = try openDirectoryChild(sourceDescriptor,
                                                              name: sessionID,
                                                              create: false)
            } catch {
                switch classifyArchiveReadFailure(error) {
                case .missing, .invalid:
                    return (.invalid, nil)
                case .data, .unavailable:
                    return (.unavailable, nil)
                }
            }
            defer { Darwin.close(installedDescriptor) }
            guard let installedIdentity = directoryIdentity(installedDescriptor) else {
                return (.unavailable, nil)
            }

            let installedDataDescriptor: Int32
            do {
                installedDataDescriptor = try openDirectoryChild(installedDescriptor,
                                                                  name: "data",
                                                                  create: false)
            } catch {
                switch classifyArchiveReadFailure(error) {
                case .missing, .invalid:
                    return (.invalid, installedIdentity)
                case .data, .unavailable:
                    return (.unavailable, installedIdentity)
                }
            }
            defer { Darwin.close(installedDataDescriptor) }
            return validateBoundArchiveTreeWithIdentity(
                info: expectedInfo,
                manifest: expectedManifest,
                sessionDescriptor: installedDescriptor,
                dataDescriptor: installedDataDescriptor
            )
        }

        if finalExists {
            let backupName = ".backup-\(sessionID)-\(UUID().uuidString)"
            let expectedFinalIdentity = fileIdentity(finalStat)

            guard directoryIdentity(in: sourceDescriptor, name: sessionID) == expectedFinalIdentity else {
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }

            func restoreBackup(expectedFinalIdentity: String?) throws {
                guard try removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                             name: sessionID,
                                                             expectedIdentity: expectedFinalIdentity) else {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                try renameArchiveEntryExclusively(in: sourceDescriptor,
                                                  from: backupName,
                                                  to: sessionID)
                try syncDescriptor(sourceDescriptor, path: sessionID)
            }

            try renameArchiveEntryExclusively(in: sourceDescriptor,
                                              from: sessionID,
                                              to: backupName)

            // The old final is now the recovery copy. Make that directory
            // entry durable before exposing the replacement.
            try syncDescriptor(sourceDescriptor, path: backupName)
            guard let backupIdentity = directoryIdentity(in: sourceDescriptor,
                                                         name: backupName) else {
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }

            var replacementInstalled = false
            do {
                try renameArchiveEntryExclusively(from: stagingParentDescriptor,
                                                  source: stagingName,
                                                  to: sourceDescriptor,
                                                  destination: sessionID)

                replacementInstalled = true
                // The rename removes the staging entry from its parent and
                // creates the final entry in the managed source directory.
                try syncDescriptor(stagingParentDescriptor, path: stagingName)
                try syncDescriptor(sourceDescriptor, path: sessionID)
#if DEBUG
                SessionArchiveManagerTestHooks.afterReplacementInstalledHook?()
#endif
            } catch {
                if replacementInstalled {
                    let installedIdentity = directoryIdentity(in: sourceDescriptor,
                                                              name: sessionID)
                    if let installedIdentity {
                        try? removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                               name: sessionID,
                                                               expectedIdentity: installedIdentity)
                    }
                }
                try? renameArchiveEntryExclusively(in: sourceDescriptor,
                                                   from: backupName,
                                                   to: sessionID)
                try? syncDescriptor(sourceDescriptor, path: sessionID)
                throw error
            }

            let installedValidation = validateInstalledTree()
            switch installedValidation.validation {
            case .valid:
                break
            case .invalid:
#if DEBUG
                SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
#endif
                do {
                    try restoreBackup(expectedFinalIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.invalidACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotInvalid(id: sessionID)
            case .unavailable:
#if DEBUG
                SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
#endif
                do {
                    try restoreBackup(expectedFinalIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.unavailableACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotUnavailable(id: sessionID)
            }

            guard let installedIdentity = installedValidation.identity else {
                do {
                    try restoreBackup(expectedFinalIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }

            // If the configured live root changed while the replacement was
            // being installed, restore the old committed archive before any
            // backup cleanup. This keeps the new archive from becoming the
            // authority for a root that no longer owns its source snapshot.
            let authorityResult = authorityCheck(authorityToken, sessionID: sessionID)
            guard case .current = authorityResult else {
                do {
                    try restoreBackup(expectedFinalIdentity: installedIdentity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw authorityError(for: authorityResult, sessionID: sessionID)
            }

#if DEBUG
            SessionArchiveManagerTestHooks.beforeBackupCleanupHook?()
#endif
            guard directoryIdentity(in: sourceDescriptor, name: sessionID) == installedIdentity else {
                do {
                    try restoreBackup(expectedFinalIdentity: installedIdentity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }

            // The new final is already durable. Backup cleanup is deliberately
            // non-transactional: if removal fails, leave the recovery copy for
            // startup reconciliation rather than rolling back the new archive
            // or risking data loss.
            do {
                guard try removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                             name: backupName,
                                                             expectedIdentity: backupIdentity) else {
                    throw posixError(path: backupName)
                }
                // Best effort after removal. The pre-removal barrier above is
                // what makes it safe to discard the old copy.
                try? syncDescriptor(sourceDescriptor, path: backupName)
            } catch {
                // cleanupOrphanedTempDirs() will remove a backup only after it
                // validates the final or restores the backup when final is bad.
            }
        } else {
            try renameArchiveEntryExclusively(from: stagingParentDescriptor,
                                              source: stagingName,
                                              to: sourceDescriptor,
                                              destination: sessionID)
            try syncDescriptor(stagingParentDescriptor, path: stagingName)
            try syncDescriptor(sourceDescriptor, path: sessionID)
#if DEBUG
            SessionArchiveManagerTestHooks.afterReplacementInstalledHook?()
#endif

            func removeInstalledFinal(expectedIdentity: String?) throws {
                guard try removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                             name: sessionID,
                                                             expectedIdentity: expectedIdentity) else {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
            }

            let installedValidation = validateInstalledTree()
            switch installedValidation.validation {
            case .valid:
                break
            case .invalid:
#if DEBUG
                SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
#endif
                do {
                    try removeInstalledFinal(expectedIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.invalidACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotInvalid(id: sessionID)
            case .unavailable:
#if DEBUG
                SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
#endif
                do {
                    try removeInstalledFinal(expectedIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                if expectedInfo.isCursorACPArchive {
                    throw ArchiveManifestError.unavailableACPSnapshot(id: sessionID)
                }
                throw ArchiveManifestError.archiveSnapshotUnavailable(id: sessionID)
            }

            guard let installedIdentity = installedValidation.identity else {
                do {
                    try removeInstalledFinal(expectedIdentity: installedValidation.identity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }

            let authorityResult = authorityCheck(authorityToken, sessionID: sessionID)
            guard case .current = authorityResult else {
                do {
                    try removeInstalledFinal(expectedIdentity: installedIdentity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw authorityError(for: authorityResult, sessionID: sessionID)
            }

            guard directoryIdentity(in: sourceDescriptor, name: sessionID) == installedIdentity else {
                do {
                    try removeInstalledFinal(expectedIdentity: installedIdentity)
                } catch {
                    throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
                }
                throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
            }
        }
    }

    private func makeStagingDir(source: SessionSource, sessionID: String) throws -> URL {
        guard let parent = sourceRoot(source) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let staging = parent.appendingPathComponent(".staging-\(sessionID)-\(UUID().uuidString)", isDirectory: true)
        let parentDescriptor = try openArchiveSourceDirectory(source: source, create: true)
        defer { Darwin.close(parentDescriptor) }
        let stagingDescriptor = try openDirectoryChild(parentDescriptor,
                                                        name: staging.lastPathComponent,
                                                        create: true)
        Darwin.close(stagingDescriptor)
        return staging
    }

    private func removeArchiveStagingDirectory(source: SessionSource, staging: URL) {
        let name = staging.lastPathComponent
        guard name.hasPrefix(".staging-") else { return }
        do {
            let sourceDescriptor = try openArchiveSourceDirectory(source: source, create: false)
            defer { Darwin.close(sourceDescriptor) }
            try removeArchiveEntryIfPresent(in: sourceDescriptor, name: name)
        } catch {
            // Cleanup is best effort, but it stays descriptor-bound so a
            // substituted archive parent cannot redirect the removal.
        }
    }

    private struct ArchiveRecoveryCandidate {
        let name: String
        let identity: String
        let syncDate: Date
        let mtime: Date
    }

    private func sessionID(fromTransactionName name: String, prefix: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let body = String(name.dropFirst(prefix.count))
        let suffixLength = 37 // '-' plus a UUID
        guard body.count > suffixLength else { return nil }
        let suffixStart = body.index(body.endIndex, offsetBy: -suffixLength)
        guard body[suffixStart] == "-" else { return nil }
        let uuid = String(body[body.index(after: suffixStart)...])
        guard UUID(uuidString: uuid) != nil else { return nil }
        let id = String(body[..<suffixStart])
        return isSafeArchiveComponent(id) ? id : nil
    }

    private func directoryEntryNames(in directoryDescriptor: Int32) throws -> [String] {
#if DEBUG
        if SessionArchiveManagerTestHooks.directoryEnumerationHook?() == false {
            throw posixError(path: "directory")
        }
#endif
        // `dup` shares the directory stream offset with the source descriptor;
        // a second enumeration would then start at EOF. Open `.` relative to
        // the already-bound directory instead so each scan has its own offset.
        let duplicateDescriptor = ".".withCString {
            Darwin.openat(directoryDescriptor,
                          $0,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard duplicateDescriptor >= 0 else {
            throw posixError(path: "directory")
        }
        guard let directoryStream = Darwin.fdopendir(duplicateDescriptor) else {
            Darwin.close(duplicateDescriptor)
            throw posixError(path: "directory")
        }
        defer { Darwin.closedir(directoryStream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directoryStream) else {
                guard errno == 0 else { throw posixError(path: "directory") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    private func transactionNames(in sourceDescriptor: Int32,
                                  sessionID: String,
                                  prefix: String) throws -> [String] {
        let transactionPrefix = "\(prefix)\(sessionID)-"
        return try directoryEntryNames(in: sourceDescriptor).filter {
            guard $0.hasPrefix(transactionPrefix) else { return false }
            return UUID(uuidString: String($0.dropFirst(transactionPrefix.count))) != nil
        }
    }

    private func recoveryCandidate(sourceDescriptor: Int32,
                                   name: String) -> ArchiveRecoveryCandidate? {
        var entryStat = stat()
        guard name.withCString({
            Darwin.fstatat(sourceDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        (entryStat.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        let mtime = Date(timeIntervalSince1970: TimeInterval(entryStat.st_mtimespec.tv_sec)
                         + TimeInterval(entryStat.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard let descriptor = try? openDirectoryChild(sourceDescriptor,
                                                       name: name,
                                                       create: false) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard let identity = directoryIdentity(descriptor) else { return nil }
        let syncDate = readRegularFileNoFollow(in: descriptor, name: "meta.json")
            .flatMap { try? JSONDecoder().decode(SessionArchiveInfo.self, from: $0) }
            .flatMap { $0.lastSyncAt ?? $0.pinnedAt } ?? .distantPast
        return ArchiveRecoveryCandidate(name: name,
                                        identity: identity,
                                        syncDate: syncDate,
                                        mtime: mtime)
    }

    private func finalArchiveValidation(source: SessionSource,
                                        id: String) -> ArchivedSnapshotValidation {
        let sourceDescriptor: Int32
        do {
            sourceDescriptor = try openArchiveSourceDirectory(source: source, create: false)
        } catch {
            return classifyArchiveValidationFailure(error)
        }
        defer { Darwin.close(sourceDescriptor) }
        return finalArchiveValidationWithIdentity(sourceDescriptor: sourceDescriptor,
                                                  source: source,
                                                  id: id).validation
    }

    /// Recovery passes the already-open source descriptor here. The session
    /// directory, metadata, manifest, and data tree all remain bound to that
    /// directory even if another tree is later installed at the same pathname.
    private func finalArchiveValidation(sourceDescriptor: Int32,
                                        source: SessionSource,
                                        id: String) -> ArchivedSnapshotValidation {
        return finalArchiveValidationWithIdentity(sourceDescriptor: sourceDescriptor,
                                                  source: source,
                                                  id: id).validation
    }

    private func finalArchiveValidationWithIdentity(
        sourceDescriptor: Int32,
        source: SessionSource,
        id: String
    ) -> (validation: ArchivedSnapshotValidation, identity: String?) {
        guard isSafeArchiveComponent(id) else { return (.invalid, nil) }
        let sessionDescriptor: Int32
        do {
            sessionDescriptor = try openDirectoryChild(sourceDescriptor,
                                                        name: id,
                                                        create: false)
        } catch {
            return (classifyArchiveValidationFailure(error), nil)
        }
        defer { Darwin.close(sessionDescriptor) }
        guard let sessionIdentity = directoryIdentity(sessionDescriptor) else {
            return (.unavailable, nil)
        }

        let info: SessionArchiveInfo
        switch readArchiveFileForValidation(in: sessionDescriptor, name: "meta.json") {
        case .missing, .invalid:
            return (.invalid, sessionIdentity)
        case .unavailable:
            return (.unavailable, sessionIdentity)
        case .data(let data):
            guard let decoded = try? JSONDecoder().decode(SessionArchiveInfo.self, from: data),
                  isValidArchiveInfo(decoded, source: source, id: id) else {
                return (.invalid, sessionIdentity)
            }
            info = decoded
        }

        let manifest: SessionArchiveManifest
        switch readArchiveFileForValidation(in: sessionDescriptor, name: "manifest.json") {
        case .missing, .invalid:
            return (.invalid, sessionIdentity)
        case .unavailable:
            return (.unavailable, sessionIdentity)
        case .data(let data):
            guard let decoded = try? JSONDecoder().decode(SessionArchiveManifest.self, from: data) else {
                return (.invalid, sessionIdentity)
            }
            manifest = decoded
        }

        let dataDescriptor: Int32
        do {
            dataDescriptor = try openDirectoryChild(sessionDescriptor,
                                                     name: "data",
                                                     create: false)
        } catch {
            return (classifyArchiveValidationFailure(error), sessionIdentity)
        }
        defer { Darwin.close(dataDescriptor) }
        return validateBoundArchiveTreeWithIdentity(
            info: info,
            manifest: manifest,
            sessionDescriptor: sessionDescriptor,
            dataDescriptor: dataDescriptor
        )
    }

    /// Reconcile all backups for one session as a single recovery set. The
    /// newest semantically valid copy wins; directory enumeration order is
    /// never used as a recovery policy.
    private func recoverArchiveBackups(source: SessionSource,
                                       sourceDescriptor: Int32,
                                       sessionID: String,
                                       names: [String]) -> ArchiveRecoveryOutcome {
        let candidates = names.compactMap {
            recoveryCandidate(sourceDescriptor: sourceDescriptor, name: $0)
        }.sorted {
            if $0.syncDate != $1.syncDate { return $0.syncDate > $1.syncDate }
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.name > $1.name
        }
        guard !candidates.isEmpty else { return .failed }

        let existingFinalValidation = finalArchiveValidationWithIdentity(
            sourceDescriptor: sourceDescriptor,
            source: source,
            id: sessionID
        )
        switch existingFinalValidation.validation {
        case .valid:
            guard let finalIdentity = existingFinalValidation.identity else {
                return .unavailable
            }
#if DEBUG
            SessionArchiveManagerTestHooks.beforeBackupCleanupHook?()
#endif
            do {
                for candidate in candidates {
                    guard directoryIdentity(in: sourceDescriptor, name: sessionID) == finalIdentity else {
                        return .unavailable
                    }
                    guard try removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                                 name: candidate.name,
                                                                 expectedIdentity: candidate.identity) else {
                        throw posixError(path: candidate.name)
                    }
                }
                try syncDescriptor(sourceDescriptor, path: sessionID)
                return .resolved
            } catch {
                // A valid final remains intact. Preserve any recovery copy
                // that could not be removed or durably acknowledged.
                return .unavailable
            }
        case .unavailable:
            // A transient validation outage is not proof that the final is
            // corrupt. Preserve the final and every recovery copy.
            return .unavailable
        case .invalid:
            break
        }

        // A partially installed replacement must not shadow a recovery copy.
        // Run the race seam even when validation observed no final: a newly
        // appearing pathname must be preserved rather than treated as the
        // invalid object that was inspected.
#if DEBUG
        guard SessionArchiveManagerTestHooks.recoveryRemoveFinalHook?() ?? true else {
            return .failed
        }
        SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
#endif
        do {
            guard try removeArchiveEntryIfStillExpected(
                in: sourceDescriptor,
                name: sessionID,
                expectedIdentity: existingFinalValidation.identity
            ) else {
                return .failed
            }
        } catch {
            // Do not consume any backup if the broken final cannot be
            // removed. The next startup can retry recovery with every
            // candidate still intact.
            return .failed
        }

        func rollBackRestoredCandidate(_ candidate: ArchiveRecoveryCandidate,
                                       expectedFinalIdentity: String?) -> ArchiveRecoveryOutcome {
            guard let expectedFinalIdentity,
                  directoryIdentity(in: sourceDescriptor, name: sessionID) == expectedFinalIdentity else {
                return .unavailable
            }
            // If the rollback rename itself cannot be completed, keep the
            // restored final in place. It is safer to retain an available
            // candidate than to report recovery failure with neither name
            // occupied.
            do {
                try renameArchiveEntryExclusively(in: sourceDescriptor,
                                                  from: sessionID,
                                                  to: candidate.name)
            } catch {
                return .unavailable
            }
            do {
                try syncDescriptor(sourceDescriptor, path: candidate.name)
                return .unavailable
            } catch {
                // The backup name is present again, but its durability barrier
                // failed. Restore the final name so the usable snapshot stays
                // available; leave the recovery set otherwise untouched.
                do {
                    try renameArchiveEntryExclusively(in: sourceDescriptor,
                                                      from: candidate.name,
                                                      to: sessionID)
                } catch {
                    return .failed
                }
                try? syncDescriptor(sourceDescriptor, path: sessionID)
                return .unavailable
            }
        }

        for candidate in candidates {
#if DEBUG
            guard SessionArchiveManagerTestHooks.recoveryRenameHook?() ?? true else {
                continue
            }
#endif
            do {
                try renameArchiveEntryExclusively(in: sourceDescriptor,
                                                  from: candidate.name,
                                                  to: sessionID)
            } catch {
                continue
            }
            let restoredIdentity = directoryIdentity(in: sourceDescriptor, name: sessionID)

            // The restored final must be durable before any other recovery
            // copy can be discarded.
            do {
                try syncDescriptor(sourceDescriptor, path: sessionID)
            } catch {
                return rollBackRestoredCandidate(candidate,
                                                 expectedFinalIdentity: restoredIdentity)
            }

            let restoredFinalValidation = finalArchiveValidationWithIdentity(
                sourceDescriptor: sourceDescriptor,
                source: source,
                id: sessionID
            )
            switch restoredFinalValidation.validation {
            case .valid:
                guard let finalIdentity = restoredFinalValidation.identity else {
                    return rollBackRestoredCandidate(candidate,
                                                     expectedFinalIdentity: restoredIdentity)
                }
#if DEBUG
                SessionArchiveManagerTestHooks.beforeBackupCleanupHook?()
#endif
                do {
                    for other in candidates where other.name != candidate.name {
                        guard directoryIdentity(in: sourceDescriptor, name: sessionID) == finalIdentity else {
                            return .unavailable
                        }
                        guard try removeArchiveEntryIfStillExpected(in: sourceDescriptor,
                                                                     name: other.name,
                                                                     expectedIdentity: other.identity) else {
                            throw posixError(path: other.name)
                        }
                    }
                    try syncDescriptor(sourceDescriptor, path: sessionID)
                } catch {
                    // The restored final is durable; preserve any copy that
                    // was not removed so a later startup can retry cleanup.
                    return .unavailable
                }
                return .resolved
            case .unavailable:
                // Do not consume an otherwise healthy recovery set because a
                // temporary validation dependency is unavailable.
                return rollBackRestoredCandidate(
                    candidate,
                    expectedFinalIdentity: restoredFinalValidation.identity ?? restoredIdentity
                )
            case .invalid:
                break
            }

            // Candidate was not a complete archive. Remove it before trying
            // the next candidate so it cannot shadow the next restore.
            do {
                #if DEBUG
                SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook?()
                #endif
                guard try removeArchiveEntryIfStillExpected(
                    in: sourceDescriptor,
                    name: sessionID,
                    expectedIdentity: restoredFinalValidation.identity ?? restoredIdentity
                ) else {
                    return .failed
                }
                try syncDescriptor(sourceDescriptor, path: sessionID)
            } catch {
                // The invalid candidate is still occupying the final name.
                // Preserve every untouched backup rather than allowing the
                // cleanup below to erase the only good recovery copy.
                return .failed
            }
        }

        // No candidate was publishable, or every restore attempt failed. Keep
        // the recovery set intact and let reconcileExistingBackups propagate a
        // fail-closed error. A later startup can retry after the filesystem
        // failure is gone.
        return .failed
    }

    private func reconcileExistingBackups(source: SessionSource,
                                          sourceDescriptor: Int32,
                                          sessionID: String) throws {
        let backups = try transactionNames(in: sourceDescriptor,
                                           sessionID: sessionID,
                                           prefix: ".backup-")
        guard !backups.isEmpty else { return }
        let outcome = recoverArchiveBackups(source: source,
                                            sourceDescriptor: sourceDescriptor,
                                            sessionID: sessionID,
                                            names: backups)
        guard case .resolved = outcome else {
            throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
        }
        let remaining = try transactionNames(in: sourceDescriptor,
                                             sessionID: sessionID,
                                             prefix: ".backup-")
        guard remaining.isEmpty else {
            throw ArchiveManifestError.recoveryUnavailable(id: sessionID)
        }
    }

    private func prepareStagingDataRoot(at stagingSessionRoot: URL) throws -> URL {
        let sessionDescriptor = try openDirectoryDescriptor(at: stagingSessionRoot, create: true)
        defer { Darwin.close(sessionDescriptor) }
        let dataDescriptor = try openDirectoryChild(sessionDescriptor, name: "data", create: true)
        Darwin.close(dataDescriptor)
        return stagingSessionRoot.appendingPathComponent("data", isDirectory: true)
    }

    private func writeStagedArchiveFiles(at stagingSessionRoot: URL,
                                         info: SessionArchiveInfo,
                                         manifest: SessionArchiveManifest) throws {
        let sessionDescriptor = try openDirectoryDescriptor(at: stagingSessionRoot, create: false)
        defer { Darwin.close(sessionDescriptor) }
        let data = try JSONEncoder().encode(info)
        try writeAtomically(data, in: sessionDescriptor, name: "meta.json")
        let manifestData = try JSONEncoder().encode(manifest)
        try writeAtomically(manifestData, in: sessionDescriptor, name: "manifest.json")
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
        guard let root = sessionRoot(source: source, id: id) else { return }
        log("delete archive source=\(source.rawValue) id=\(id) path=\(root.path)")
        do {
            try withArchiveMutationLock(source: source) {
                let sourceDescriptor = try openArchiveSourceDirectory(source: source, create: false)
                defer { Darwin.close(sourceDescriptor) }
                // Enumerate the full recovery set before touching the final. A
                // failed scan must not be mistaken for an empty set, or startup
                // recovery could later resurrect a supposedly deleted archive.
                let transactionCopies = try transactionNames(in: sourceDescriptor,
                                                             sessionID: id,
                                                             prefix: ".backup-")
                    + transactionNames(in: sourceDescriptor,
                                       sessionID: id,
                                       prefix: ".staging-")
                for name in transactionCopies {
                    try removeArchiveEntryIfPresent(in: sourceDescriptor, name: name)
                }
                try syncDescriptor(sourceDescriptor, path: id)

                let remainingTransactions = try transactionNames(in: sourceDescriptor,
                                                                  sessionID: id,
                                                                  prefix: ".backup-")
                    + transactionNames(in: sourceDescriptor,
                                       sessionID: id,
                                       prefix: ".staging-")
                guard remainingTransactions.isEmpty else {
                    throw NSError(domain: "SessionArchiveManager",
                                  code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Could not remove archive transaction entries: \(remainingTransactions.joined(separator: ", "))"])
                }
                try removeArchiveEntryIfPresent(in: sourceDescriptor, name: id)
                try syncDescriptor(sourceDescriptor, path: id)
            }
        } catch {
            log("delete archive rejected source=\(source.rawValue) id=\(id) error=\(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        guard let root = archivesRoot() else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let rootDescriptor = try openDirectoryDescriptor(at: root, create: true)
            defer { Darwin.close(rootDescriptor) }
            try rotateArchiveLogIfNeeded(in: rootDescriptor)
            let logDescriptor = "archive.log".withCString {
                Darwin.openat(rootDescriptor,
                              $0,
                              O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
                              0o600)
            }
            guard logDescriptor >= 0 else { return }
            defer { Darwin.close(logDescriptor) }
            var logStat = stat()
            guard Darwin.fstat(logDescriptor, &logStat) == 0,
                  (logStat.st_mode & S_IFMT) == S_IFREG else { return }
            let handle = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            guard Darwin.fsync(logDescriptor) == 0 else { return }
        } catch {
            // Logging must never turn a successful archive operation into a
            // failure, but it must also never fall back to pathname I/O.
        }
    }

    private func rotateArchiveLogIfNeeded(in directoryDescriptor: Int32) throws {
        var logStat = stat()
        let logStatResult = "archive.log".withCString {
            Darwin.fstatat(directoryDescriptor, $0, &logStat, AT_SYMLINK_NOFOLLOW)
        }
        guard logStatResult == 0 else {
            guard errno == ENOENT else { throw posixError(path: "archive.log") }
            return
        }
        guard (logStat.st_mode & S_IFMT) == S_IFREG else {
            throw posixError(path: "archive.log")
        }
        if Int64(logStat.st_size) < LogRotation.maxBytes { return }

        // Remove the oldest backup first (best-effort).
        if LogRotation.backupsToKeep >= 1 {
            try removeArchiveEntryIfPresent(in: directoryDescriptor,
                                            name: "archive.log.\(LogRotation.backupsToKeep)")
        }

        // Shift backups down: .(n-1) -> .n
        if LogRotation.backupsToKeep >= 2 {
            for i in stride(from: LogRotation.backupsToKeep - 1, through: 1, by: -1) {
                try renameArchiveEntryIfPresent(in: directoryDescriptor,
                                                from: "archive.log.\(i)",
                                                to: "archive.log.\(i + 1)")
            }
        }

        // Move current log to .1
        try removeArchiveEntryIfPresent(in: directoryDescriptor, name: "archive.log.1")
        try renameArchiveEntry(in: directoryDescriptor, from: "archive.log", to: "archive.log.1")
    }

    private func removeArchiveEntryIfPresent(in parentDescriptor: Int32, name: String) throws {
        guard isSafeArchiveComponent(name) else { throw posixError(path: name) }
        guard let expectedIdentity = entryIdentity(in: parentDescriptor, name: name) else {
            var entryStat = stat()
            let result = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
            }
            guard result != 0, errno == ENOENT else {
                throw posixError(path: name)
            }
            return
        }
        guard try removeArchiveEntryIfStillExpected(in: parentDescriptor,
                                                     name: name,
                                                     expectedIdentity: expectedIdentity) else {
            throw posixError(path: name)
        }
    }

    private func entryIdentity(in parentDescriptor: Int32, name: String) -> String? {
        guard isSafeArchiveComponent(name) else { return nil }
        var entryStat = stat()
        guard name.withCString({
            Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            return nil
        }
        return fileIdentity(entryStat)
    }

    /// Remove an entry only when it is still the object a prior operation
    /// observed. The entry is first moved with an exclusive rename to a
    /// transaction-unique quarantine name. That atomic move binds the object
    /// being removed even if the original pathname is replaced immediately
    /// after the identity check; a mismatch is restored exclusively or left
    /// quarantined, never recursively deleted.
    private func removeArchiveEntryIfStillExpected(in parentDescriptor: Int32,
                                                   name: String,
                                                   expectedIdentity: String?) throws -> Bool {
        guard isSafeArchiveComponent(name) else { throw posixError(path: name) }
        guard let expectedIdentity else {
            var entryStat = stat()
            let result = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
            }
            guard result != 0 else { return false }
            guard errno == ENOENT else { throw posixError(path: name) }
            return true
        }

        guard entryIdentity(in: parentDescriptor, name: name) == expectedIdentity else {
            return false
        }
#if DEBUG
        SessionArchiveManagerTestHooks.beforeArchiveEntryQuarantineHook?()
#endif

        let quarantineName = ".quarantine-\(UUID().uuidString)"
        let moved = name.withCString { sourcePointer in
            quarantineName.withCString { quarantinePointer in
                Darwin.renameatx_np(parentDescriptor,
                                    sourcePointer,
                                    parentDescriptor,
                                    quarantinePointer,
                                    UInt32(RENAME_EXCL))
            }
        }
        guard moved == 0 else {
            guard errno == ENOENT || errno == EEXIST else {
                throw posixError(path: name)
            }
            return false
        }

        // The object at the quarantine name is the one the atomic rename
        // moved. If the precondition was defeated by a pathname replacement,
        // do not delete it. Restore only when the original name is still
        // absent; an exclusive restore cannot overwrite a newer replacement.
        guard entryIdentity(in: parentDescriptor, name: quarantineName) == expectedIdentity else {
            _ = quarantineName.withCString { quarantinePointer in
                name.withCString { namePointer in
                    Darwin.renameatx_np(parentDescriptor,
                                        quarantinePointer,
                                        parentDescriptor,
                                        namePointer,
                                        UInt32(RENAME_EXCL))
                }
            }
            return false
        }

        try removeArchiveEntry(in: parentDescriptor, name: quarantineName)
        return true
    }

    private func renameArchiveEntry(in parentDescriptor: Int32,
                                    from: String,
                                    to: String) throws {
        guard isSafeArchiveComponent(from), isSafeArchiveComponent(to) else {
            throw posixError(path: from)
        }
        var sourceStat = stat()
        let sourceResult = from.withCString {
            Darwin.fstatat(parentDescriptor, $0, &sourceStat, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceResult == 0 else {
            throw posixError(path: from)
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw posixError(path: from)
        }
        try removeArchiveEntryIfPresent(in: parentDescriptor, name: to)
        let result = from.withCString { fromPointer in
            to.withCString { toPointer in
                Darwin.renameat(parentDescriptor, fromPointer,
                                parentDescriptor, toPointer)
            }
        }
        guard result == 0 else { throw posixError(path: from) }
    }

    private func renameArchiveEntryExclusively(in parentDescriptor: Int32,
                                               from: String,
                                               to: String) throws {
        try renameArchiveEntryExclusively(from: parentDescriptor,
                                          source: from,
                                          to: parentDescriptor,
                                          destination: to)
    }

    private func renameArchiveEntryExclusively(from sourceDescriptor: Int32,
                                               source: String,
                                               to destinationDescriptor: Int32,
                                               destination: String) throws {
        guard isSafeArchiveComponent(source), isSafeArchiveComponent(destination) else {
            throw posixError(path: source)
        }
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameatx_np(sourceDescriptor,
                                    sourcePointer,
                                    destinationDescriptor,
                                    destinationPointer,
                                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw posixError(path: destination) }
    }

    private func renameArchiveEntryIfPresent(in parentDescriptor: Int32,
                                             from: String,
                                             to: String) throws {
        var sourceStat = stat()
        let result = from.withCString {
            Darwin.fstatat(parentDescriptor, $0, &sourceStat, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            guard errno == ENOENT else { throw posixError(path: from) }
            return
        }
        try renameArchiveEntry(in: parentDescriptor, from: from, to: to)
    }

    private func cleanupOrphanedTempDirs() {
        guard let root = archivesRoot() else { return }
        let cutoff = Date().addingTimeInterval(-TempCleanup.minAgeSeconds)

        let rootDescriptor: Int32
        do {
            rootDescriptor = try openDirectoryDescriptor(at: root, create: true)
        } catch {
            return
        }
        defer { Darwin.close(rootDescriptor) }

        for source in SessionSource.allCases {
            do {
                try withArchiveMutationLock(source: source) {
                    let sourceDescriptor = try openDirectoryChild(rootDescriptor,
                                                                  name: source.rawValue,
                                                                  create: false)
                    defer { Darwin.close(sourceDescriptor) }

                    let names: [String]
                    do {
                        names = try directoryEntryNames(in: sourceDescriptor)
                    } catch {
                        // A failed scan is not an empty recovery set. Leave every
                        // transaction copy untouched and retry on a later startup.
                        return
                    }
                    var backupsBySession: [String: [String]] = [:]
                    for name in names {
                        guard let id = sessionID(fromTransactionName: name, prefix: ".backup-") else {
                            continue
                        }
                        backupsBySession[id, default: []].append(name)
                    }
                    for id in backupsBySession.keys.sorted() {
                        _ = recoverArchiveBackups(source: source,
                                                   sourceDescriptor: sourceDescriptor,
                                                   sessionID: id,
                                                   names: backupsBySession[id] ?? [])
                    }

                    for name in names where name.hasPrefix(".staging-") {
                        var entryStat = stat()
                        let statResult = name.withCString {
                            Darwin.fstatat(sourceDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
                        }
                        guard statResult == 0 else { continue }
                        let mtime = Date(timeIntervalSince1970: TimeInterval(entryStat.st_mtimespec.tv_sec)
                                         + TimeInterval(entryStat.st_mtimespec.tv_nsec) / 1_000_000_000)
                        guard mtime < cutoff else { continue }
                        try? removeArchiveEntryIfPresent(in: sourceDescriptor, name: name)
                    }
                }
            } catch {
                continue
            }
        }
    }

    private func logArchivesRootIfNeeded() {
        guard !didLogArchivesRoot else { return }
        guard let root = archivesRoot() else { return }
        didLogArchivesRoot = true
        log("archivesRoot=\(root.path)")
    }
}
