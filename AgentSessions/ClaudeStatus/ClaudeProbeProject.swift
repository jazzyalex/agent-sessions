import Foundation

/// Discovery, validation, and deletion for the dedicated Claude project that stores
/// Agent Sessions' usage probe chats.
enum ClaudeProbeProject {
    static let didRunCleanupNotification = Notification.Name("ClaudeProbeCleanupDidRun")
    private static let probeMarkerFilename = ".agentsessions_probe_marker.json"
    private enum Keys {
        static let cleanupMode = "ClaudeProbeCleanupMode"      // "none" | "auto"
        static let cachedProjectID = "ClaudeProbeProjectId"    // optional cache
    }

    enum CleanupMode: String { case none, auto }

    enum ResultStatus {
        case success
        case disabled(String)
        case notFound(String)
        case unsafe(String)
        case ioError(String)
    }

    // Human-friendly mapping
    // Exposed via notification userInfo: status (kind) and message
    // Implemented as computed properties for convenience
    // Not public API.
    
    

    // MARK: - Public API

    static func cleanupMode() -> CleanupMode {
        let raw = UserDefaults.standard.string(forKey: Keys.cleanupMode) ?? CleanupMode.none.rawValue
        return CleanupMode(rawValue: raw) ?? .none
    }

    static func setCleanupMode(_ mode: CleanupMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.cleanupMode)
    }

    /// Performs a one-shot cleanup attempt if all safety checks pass.
    /// Returns a status describing the action taken or the reason for doing nothing.
    static func cleanupIfSafe() -> ResultStatus {
        guard cleanupMode() != .none else {
            return .disabled("Cleanup mode is disabled")
        }
        return performCleanup(mode: "auto")
    }

    /// Convenience: run cleanup only when mode is .auto (used after each probe).
    /// Uses the same safety + fallback logic as the manual button, but posts with mode "auto".
    @discardableResult
    static func cleanupNowIfAuto() -> ResultStatus {
        guard cleanupMode() == .auto else {
            return .disabled("Cleanup mode is not auto")
        }
        return performCleanup(mode: "auto")
    }

    /// Manual cleanup independent of mode; posts with mode "manual".
    static func cleanupNowUserInitiated() -> ResultStatus {
        return performCleanup(mode: "manual")
    }

    /// Records that a probe run completed so future cleanup can safely remove probe-only sessions.
    static func noteProbeRun() {
        guard let candidate = probeProjectDirectoryByNameHint() ?? probeProjectDirectory() else { return }
        writeProbeMarkerIfLikely(in: candidate)
    }

    /// Shared cleanup used by both manual and auto flows. Tries whole-project delete when
    /// validation passes, otherwise falls back to per-file deletion of validated probe files.
    private static func performCleanup(mode: String) -> ResultStatus {
        var status: ResultStatus
        var extras: [String: any Sendable] = [:]

        if let root = probeProjectDirectory() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                let evidence = inspectProjectFiles(projectDir: root)
                let hasMarker = probeMarkerExists(in: root)
                let hasProjectJson = projectJsonMatchesProbeWD(projectDir: root)
                let hasStrongSignal = hasMarker || hasProjectJson || evidence.sawProbeWD
                let hasUnsafe = evidence.unsafeFiles > 0
                if hasStrongSignal && !hasUnsafe {
                    let files = listProbeSessionFiles(in: root)
                    let deletedCount = files.count
                    if let oldest = files.map({ fileMTime($0) ?? Date.distantFuture }).min(), deletedCount > 0 {
                        extras["oldest_ts"] = oldest.timeIntervalSince1970
                    }
                    do { try FileManager.default.removeItem(at: root); status = .success }
                    catch { status = .ioError("Failed to delete probe project: \(error.localizedDescription)") }
                    extras["deleted"] = deletedCount
                    postCleanupStatus(status, mode: mode, extra: extras)
                    return status
                }
                // Unsafe to remove whole dir; fall through to per-file cleanup
            }
        }

        if let status = cleanupMarkedProjectsIfSafe(mode: mode) {
            return status
        }

        let metas = scanProbeFilesUnderProjectsRoot()
        let toDelete = metas.filter { $0.isProbe && $0.safe }
        let skipped = metas.filter { $0.isProbe && !$0.safe }.count
        var deleted = 0
        var oldest: Date? = nil
        for m in toDelete {
            do {
                try FileManager.default.removeItem(at: m.url)
                deleted += 1
                if let ts = m.mtime { oldest = minDate(oldest, ts) }
            } catch {
                status = .ioError("Failed to delete \(m.url.lastPathComponent): \(error.localizedDescription)")
                extras["deleted"] = deleted
                extras["skipped"] = skipped + max(0, toDelete.count - deleted)
                if let ts = oldest { extras["oldest_ts"] = ts.timeIntervalSince1970 }
                postCleanupStatus(status, mode: mode, extra: extras)
                return status
            }
        }

        if deleted > 0 {
            status = .success
            extras["deleted"] = deleted
            extras["skipped"] = skipped
            if let ts = oldest { extras["oldest_ts"] = ts.timeIntervalSince1970 }
        } else {
            status = .notFound("No probe sessions found")
        }
        postCleanupStatus(status, mode: mode, extra: extras)
        return status
    }

    private static func cleanupMarkedProjectsIfSafe(mode: String) -> ResultStatus? {
        var markerDirs = probeProjectDirectoriesByMarker()
        if markerDirs.isEmpty,
           let hinted = probeProjectDirectoryByNameHint(),
           probeMarkerExists(in: hinted) {
            markerDirs = [hinted]
        }
        guard !markerDirs.isEmpty else { return nil }

        var deleted = 0
        var skipped = 0
        var oldest: Date? = nil

        for dir in markerDirs {
            let evidence = inspectProjectFiles(projectDir: dir)
            if evidence.unsafeFiles > 0 {
                skipped += 1
                continue
            }
            let files = listProbeSessionFiles(in: dir)
            if let ts = files.map({ fileMTime($0) ?? Date.distantFuture }).min(), !files.isEmpty {
                oldest = minDate(oldest, ts)
            }
            do {
                try FileManager.default.removeItem(at: dir)
                deleted += 1
            } catch {
                let status: ResultStatus = .ioError("Failed to delete probe project: \(error.localizedDescription)")
                var extras: [String: any Sendable] = ["deleted": deleted, "skipped": skipped]
                if let ts = oldest { extras["oldest_ts"] = ts.timeIntervalSince1970 }
                postCleanupStatus(status, mode: mode, extra: extras)
                return status
            }
        }

        guard deleted > 0 else { return nil }
        var extras: [String: any Sendable] = ["deleted": deleted, "skipped": skipped]
        if let ts = oldest { extras["oldest_ts"] = ts.timeIntervalSince1970 }
        let status: ResultStatus = .success
        postCleanupStatus(status, mode: mode, extra: extras)
        return status
    }

    private static func postCleanupStatus(_ status: ResultStatus, mode: String, extra: [String: any Sendable] = [:]) {
        var info: [String: any Sendable] = [
            "mode": mode,
            "status": status.kind,
            "message": status.message ?? ""
        ]
        for (k, v) in extra { info[k] = v }
        let payload = info

        func userInfo(from payload: [String: any Sendable]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in payload {
                out[k] = v
            }
            return out
        }

        if Thread.isMainThread {
            NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: userInfo(from: payload))
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: userInfo(from: payload))
            }
        }
    }

    // MARK: - Discovery

    /// Returns a cached or freshly-discovered Claude project id matching the Probe WD.
    static func discoverProbeProjectId() -> String? {
        if let cached = UserDefaults.standard.string(forKey: Keys.cachedProjectID), !cached.isEmpty {
            let candidate = claudeProjectsRoot().appendingPathComponent(cached)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue,
               isVerifiedProbeProjectDir(candidate) {
                return cached
            }
        }
        if let marked = probeProjectDirectoryByMarker() {
            UserDefaults.standard.set(marked.lastPathComponent, forKey: Keys.cachedProjectID)
            return marked.lastPathComponent
        }
        if let hinted = probeProjectDirectoryByNameHint(),
           projectJsonMatchesProbeWD(projectDir: hinted) || probeMarkerExists(in: hinted) || validateProjectContents(projectDir: hinted) {
            UserDefaults.standard.set(hinted.lastPathComponent, forKey: Keys.cachedProjectID)
            return hinted.lastPathComponent
        }
        let projectsRoot = claudeProjectsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let expected = normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        guard let contents = try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for dir in contents {
            var isSub: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isSub), isSub.boolValue else { continue }
            let meta = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let root = extractRootPath(from: obj) {
                if normalizePath(root) == expected {
                    UserDefaults.standard.set(dir.lastPathComponent, forKey: Keys.cachedProjectID)
                    return dir.lastPathComponent
                }
            }
        }
        return nil
    }

    /// Best-effort resolution of the probe project directory.
    /// 1) Try cached/discovered id.
    /// 2) Fallback: scan subdirectories for sessions that match probe WD.
    private static func probeProjectDirectory() -> URL? {
        if let id = discoverProbeProjectId() {
            return claudeProjectsRoot().appendingPathComponent(id)
        }
        let root = claudeProjectsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        let expectedWD = normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        for dir in contents {
            var sub: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &sub), sub.boolValue else { continue }
            if dirLikelyMatchesProbeWD(dir: dir, expectedWD: expectedWD) && validateProjectContents(projectDir: dir) {
                // Cache id for faster future checks
                UserDefaults.standard.set(dir.lastPathComponent, forKey: Keys.cachedProjectID)
                return dir
            }
        }
        return nil
    }

    /// Quick check: does this directory contain JSONL files whose cwd/project equals our Probe WD?
    private static func dirLikelyMatchesProbeWD(dir: URL, expectedWD: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            seen += 1; if seen > 64 { break }
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? fh.read(upToCount: 128 * 1024); try? fh.close()
            guard let data, let text = String(data: data, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n").prefix(400) {
                guard let d = String(raw).data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let cwd = obj["cwd"] as? String, normalizePath(cwd) == expectedWD { return true }
                if let proj = obj["project"] as? String, normalizePath(proj) == expectedWD { return true }
            }
        }
        return false
    }

    private static func extractRootPath(from obj: [String: Any]) -> String? {
        // Try common keys where a root path might be recorded
        let keys = ["rootPath", "root", "cwd", "dir", "path", "workspaceRoot"]
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
        }
        // Sometimes nested under a field like { project: { rootPath: "..." } }
        for (_, v) in obj {
            if let dict = v as? [String: Any], let s = extractRootPath(from: dict) { return s }
        }
        return nil
    }

    // MARK: - Validation

    private static func validateProjectContents(projectDir: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        let expectedWD = normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        var inspectedFile = false
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            inspectedFile = true
            guard let stats = inspectProbeFile(url: url, expectedWD: expectedWD) else { return false }
            if !stats.isSafeTinyProbe { return false }
        }
        return inspectedFile
    }

    private enum FileScanOutcome {
        case empty
        case safe(ProbeFileStats)
        case unsafe
    }

    private struct ProjectEvidence {
        var totalFiles: Int = 0
        var emptyFiles: Int = 0
        var safeTinyFiles: Int = 0
        var unsafeFiles: Int = 0
        var sawProbeWD: Bool = false
    }

    private struct ProbeFileMeta { let url: URL; let isProbe: Bool; let safe: Bool; let mtime: Date? }

    private struct ProbeFileStats {
        var sawProbeWD: Bool = false
        var userCount: Int = 0
        var assistantCount: Int = 0
        var safeOtherCount: Int = 0   // e.g., system/local_command/summary events emitted by the probe itself
        var unsafeOtherCount: Int = 0 // any other event kinds we don't explicitly allow

        var totalEvents: Int { userCount + assistantCount + safeOtherCount + unsafeOtherCount }
        var isSafeTinyProbe: Bool {
            // Allow system/summary-only probe transcripts, but reject any unrecognized events.
            return sawProbeWD && unsafeOtherCount == 0 && totalEvents > 0 && totalEvents <= 5
        }
    }

    private static let userEventTypes: Set<String> = ["user", "user_input", "user-input", "input", "prompt", "chat_input", "chat-input", "human"]
    private static let assistantEventTypes: Set<String> = ["assistant", "response", "assistant_message", "assistant-message", "assistant_response", "assistant-response", "completion"]
    private static let safeProbeEventTypes: Set<String> = ["system", "local_command", "local-command", "summary", "meta", "metadata"]

    private static func inspectProbeFile(url: URL, expectedWD: String) -> ProbeFileStats? {
        let fh = try? FileHandle(forReadingFrom: url)
        let data = try? fh?.read(upToCount: 256 * 1024)
        try? fh?.close()
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        var stats = ProbeFileStats()
        for raw in text.split(separator: "\n").prefix(400) {
            guard let lineData = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if !stats.sawProbeWD {
                if let cwd = obj["cwd"] as? String, normalizePath(cwd) == expectedWD { stats.sawProbeWD = true }
                else if let proj = obj["project"] as? String, normalizePath(proj) == expectedWD { stats.sawProbeWD = true }
            }
            incrementEventCounts(obj, stats: &stats)
        }

        return stats.totalEvents > 0 ? stats : nil
    }

    private static func scanProbeFile(url: URL, expectedWD: String) -> FileScanOutcome {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .unsafe }
        defer { try? fh.close() }

        // `read(upToCount:)` can return nil at EOF; treat that as empty.
        // Actual read failures should remain unsafe to preserve deletion guardrails.
        let data: Data
        do {
            data = try fh.read(upToCount: 256 * 1024) ?? Data()
        } catch {
            return .unsafe
        }
        if data.isEmpty { return .empty }
        guard let text = String(data: data, encoding: .utf8) else { return .unsafe }

        var stats = ProbeFileStats()
        var parsedAny = false
        for raw in text.split(separator: "\n").prefix(400) {
            guard let lineData = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            parsedAny = true
            if !stats.sawProbeWD {
                if let cwd = obj["cwd"] as? String, normalizePath(cwd) == expectedWD { stats.sawProbeWD = true }
                else if let proj = obj["project"] as? String, normalizePath(proj) == expectedWD { stats.sawProbeWD = true }
            }
            incrementEventCounts(obj, stats: &stats)
        }

        if !parsedAny { return .unsafe }
        if stats.totalEvents == 0 { return .empty }
        return .safe(stats)
    }

    private static func inspectProjectFiles(projectDir: URL) -> ProjectEvidence {
        guard let enumerator = FileManager.default.enumerator(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return ProjectEvidence()
        }
        let expectedWD = normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        var evidence = ProjectEvidence()
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            evidence.totalFiles += 1
            switch scanProbeFile(url: url, expectedWD: expectedWD) {
            case .empty:
                evidence.emptyFiles += 1
            case .safe(let stats):
                if stats.sawProbeWD { evidence.sawProbeWD = true }
                if stats.isSafeTinyProbe {
                    evidence.safeTinyFiles += 1
                } else {
                    evidence.unsafeFiles += 1
                }
                if !stats.sawProbeWD { evidence.unsafeFiles += 1 }
            case .unsafe:
                evidence.unsafeFiles += 1
            }
        }
        return evidence
    }

    private static func incrementEventCounts(_ obj: [String: Any], stats: inout ProbeFileStats) {
        if let type = (obj["type"] as? String)?.lowercased() {
            if userEventTypes.contains(type) { stats.userCount += 1; return }
            if assistantEventTypes.contains(type) { stats.assistantCount += 1; return }
            if safeProbeEventTypes.contains(type) { stats.safeOtherCount += 1; return }
            stats.unsafeOtherCount += 1; return
        }
        if let role = (obj["role"] as? String)?.lowercased() {
            if role == "user" { stats.userCount += 1; return }
            if role == "assistant" { stats.assistantCount += 1; return }
            if safeProbeEventTypes.contains(role) { stats.safeOtherCount += 1; return }
            stats.unsafeOtherCount += 1; return
        }
        if let sender = (obj["sender"] as? String)?.lowercased() {
            if sender == "user" { stats.userCount += 1; return }
            if sender == "assistant" { stats.assistantCount += 1; return }
        }
        stats.unsafeOtherCount += 1
    }

    private static func scanProbeFilesUnderProjectsRoot() -> [ProbeFileMeta] {
        // Prefer scanning only inside the discovered probe project directory for extra safety
        let verifiedDir = probeProjectDirectoryVerified()
        let root = verifiedDir ?? claudeProjectsRoot()
        let verifiedPrefix = verifiedDir.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        var results: [ProbeFileMeta] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return results }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            let meta = analyzeFile(url: url, verifiedDirPrefix: verifiedPrefix)
            results.append(meta)
        }
        return results
    }

    private static func analyzeFile(url: URL, verifiedDirPrefix: String?) -> ProbeFileMeta {
        let stats = inspectProbeFile(url: url, expectedWD: normalizePath(ClaudeProbeConfig.probeWorkingDirectory()))
        let inProbeProject = verifiedDirPrefix.map { url.path.hasPrefix($0) } ?? false

        let sawProbeWD = stats?.sawProbeWD ?? false
        let safe = (stats?.isSafeTinyProbe ?? false)
        let isProbe = sawProbeWD || safe || inProbeProject
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return ProbeFileMeta(url: url, isProbe: isProbe, safe: safe, mtime: mtime)
    }

    private static func listProbeSessionFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in e { if ["jsonl","ndjson"].contains(url.pathExtension.lowercased()) { urls.append(url) } }
        return urls
    }

    private static func fileMTime(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func minDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a,b) { case (nil, nil): return nil; case (let x?, nil): return x; case (nil, let y?): return y; case (let x?, let y?): return min(x,y) }
    }

    private static func countProbeSessionFiles(in dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case let url as URL in e { if ["jsonl", "ndjson"].contains(url.pathExtension.lowercased()) { n += 1 } }
        return n
    }

    private static func isUserEvent(_ obj: [String: Any]) -> Bool {
        if let type = (obj["type"] as? String)?.lowercased() {
            if ["user", "user_input", "user-input", "input", "prompt", "chat_input", "chat-input", "human"].contains(type) { return true }
        }
        if let role = (obj["role"] as? String)?.lowercased(), role == "user" { return true }
        if let sender = (obj["sender"] as? String)?.lowercased(), sender == "user" { return true }
        return false
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            if let s = message["content"] as? String { return s }
            if let s = message["text"] as? String { return s }
            if let arr = message["content"] as? [[String: Any]] {
                let texts = arr.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
        }
        if let s = obj["content"] as? String { return s }
        if let s = obj["text"] as? String { return s }
        if let arr = obj["content"] as? [[String: Any]] {
            let texts = arr.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    // MARK: - Paths

    private static func claudeProjectsRoot() -> URL {
        // Test override support: AS_TEST_CLAUDE_PROJECTS_ROOT
        if let override = envValue("AS_TEST_CLAUDE_PROJECTS_ROOT"), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent(".claude/projects"))
    }

    private static func envValue(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    // MARK: - Probe project identification helpers

    private static func probeMarkerURL(in dir: URL) -> URL {
        dir.appendingPathComponent(probeMarkerFilename)
    }

    private static func probeMarkerExists(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: probeMarkerURL(in: dir).path)
    }

    private static func writeProbeMarker(in dir: URL) {
        let payload: [String: Any] = [
            "version": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "probeWorkingDir": normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: probeMarkerURL(in: dir), options: [.atomic])
    }

    private static func projectJsonMatchesProbeWD(projectDir: URL) -> Bool {
        let meta = projectDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: meta),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = extractRootPath(from: obj) else { return false }
        return normalizePath(root) == normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
    }

    private static func isVerifiedProbeProjectDir(_ dir: URL) -> Bool {
        if probeMarkerExists(in: dir) { return true }
        if projectJsonMatchesProbeWD(projectDir: dir) { return true }
        return validateProjectContents(projectDir: dir)
    }

    private static func probeProjectDirectoryVerified() -> URL? {
        guard let candidate = probeProjectDirectory() else { return nil }
        return isVerifiedProbeProjectDir(candidate) ? candidate : nil
    }

    private static func probeProjectNameHint() -> String? {
        let wd = normalizePath(ClaudeProbeConfig.probeWorkingDirectory())
        if wd.isEmpty { return nil }
        let trimmed = wd.hasPrefix("/") ? String(wd.dropFirst()) : wd
        let parts = trimmed.split(separator: "/").map { $0.replacingOccurrences(of: " ", with: "-") }
        guard !parts.isEmpty else { return nil }
        return "-" + parts.joined(separator: "-")
    }

    private static func probeProjectDirectoryByNameHint() -> URL? {
        guard let hint = probeProjectNameHint() else { return nil }
        let candidate = claudeProjectsRoot().appendingPathComponent(hint)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return nil
    }

    private static func probeProjectDirectoryByMarker() -> URL? {
        probeProjectDirectoriesByMarker().first
    }

    private static func probeProjectDirectoriesByMarker() -> [URL] {
        let root = claudeProjectsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var matches: [URL] = []
        for dir in contents {
            var sub: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &sub), sub.boolValue else { continue }
            if probeMarkerExists(in: dir) { matches.append(dir) }
        }
        return matches
    }

    private static func writeProbeMarkerIfLikely(in dir: URL) {
        guard !probeMarkerExists(in: dir) else { return }
        if projectJsonMatchesProbeWD(projectDir: dir) || validateProjectContents(projectDir: dir) {
            writeProbeMarker(in: dir)
            return
        }
        guard let hint = probeProjectNameHint(), dir.lastPathComponent == hint else { return }
        let recentThreshold = Date().addingTimeInterval(-600)
        let files = listProbeSessionFiles(in: dir)
        guard !files.isEmpty else { return }
        if let newest = files.map({ fileMTime($0) ?? Date.distantPast }).max(), newest >= recentThreshold {
            writeProbeMarker(in: dir)
        }
    }
}

private extension ClaudeProbeProject.ResultStatus {
    var kind: String {
        switch self {
        case .success: return "success"
        case .disabled: return "disabled"
        case .notFound: return "not_found"
        case .unsafe: return "unsafe"
        case .ioError: return "io_error"
        }
    }
    var message: String? {
        switch self {
        case .success: return nil
        case .disabled(let s): return s
        case .notFound(let s): return s
        case .unsafe(let s): return s
        case .ioError(let s): return s
        }
    }
}
