import Foundation

/// Discovery, validation, and deletion for the dedicated Claude project that stores
/// Agent Sessions' usage probe chats.
enum ClaudeProbeProject {
    static let didRunCleanupNotification = Notification.Name("ClaudeProbeCleanupDidRun")
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
        var status: ResultStatus = .notFound("Cleanup not run")
        var extras: [String: Any] = [:]
        defer { postCleanupStatus(status, mode: "auto", extra: extras) }

        guard cleanupMode() != .none else {
            status = .disabled("Cleanup mode is disabled"); return status
        }
        guard let root = probeProjectDirectory() else {
            status = .notFound("No probe project found; run a probe first"); return status
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            status = .notFound("Probe project directory is missing"); return status
        }
        guard validateProjectContents(projectDir: root) else {
            status = .unsafe("Probe project contains non-probe sessions; deletion skipped"); return status
        }
        let deletedCount = countProbeSessionFiles(in: root)
        do {
            try FileManager.default.removeItem(at: root)
            status = .success
        } catch {
            status = .ioError("Failed to delete probe project: \(error.localizedDescription)")
        }
        if deletedCount > 0 { extras["deleted"] = deletedCount }
        return status
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

    /// Shared cleanup used by both manual and auto flows. Tries whole-project delete when
    /// validation passes, otherwise falls back to per-file deletion of validated probe files.
    private static func performCleanup(mode: String) -> ResultStatus {
        var status: ResultStatus
        var extras: [String: Any] = [:]

        if let root = probeProjectDirectory() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                if validateProjectContents(projectDir: root) {
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

    private static func postCleanupStatus(_ status: ResultStatus, mode: String, extra: [String: Any] = [:]) {
        var info: [String: Any] = [
            "mode": mode,
            "status": status.kind,
            "message": status.message ?? ""
        ]
        for (k, v) in extra { info[k] = v }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: info)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: info)
            }
        }
    }

    // MARK: - Discovery

    /// Returns a cached or freshly-discovered Claude project id matching the Probe WD.
    static func discoverProbeProjectId() -> String? {
        if let cached = UserDefaults.standard.string(forKey: Keys.cachedProjectID), !cached.isEmpty {
            let candidate = claudeProjectsRoot().appendingPathComponent(cached)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return cached
            }
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
        let root = probeProjectDirectory() ?? claudeProjectsRoot()
        var results: [ProbeFileMeta] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return results }
        for case let url as URL in e {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            let meta = analyzeFile(url: url)
            results.append(meta)
        }
        return results
    }

    private static func analyzeFile(url: URL) -> ProbeFileMeta {
        let stats = inspectProbeFile(url: url, expectedWD: normalizePath(ClaudeProbeConfig.probeWorkingDirectory()))
        let projectID = discoverProbeProjectId()
        let probeDirPrefix = projectID.map { (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects/\($0)") + "/" }
        let inProbeProject = probeDirPrefix.map { url.path.hasPrefix($0) } ?? false

        let sawProbeWD = stats?.sawProbeWD ?? false
        let safe = stats?.isSafeTinyProbe ?? false
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
        if let override = ProcessInfo.processInfo.environment["AS_TEST_CLAUDE_PROJECTS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = NSHomeDirectory() as NSString
        return URL(fileURLWithPath: home.appendingPathComponent(".claude/projects"))
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
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
