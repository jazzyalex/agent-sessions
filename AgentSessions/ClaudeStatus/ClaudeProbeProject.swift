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
        var status: ResultStatus
        defer { postCleanupStatus(status, mode: "auto") }
        guard cleanupMode() != .none else {
            status = .disabled("Cleanup mode is disabled"); return status
        }
        guard let projectID = discoverProbeProjectId() else {
            status = .notFound("No probe project found; run a probe first"); return status
        }
        let root = claudeProjectsRoot().appendingPathComponent(projectID)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            status = .notFound("Probe project directory is missing"); return status
        }
        guard validateProjectContents(projectDir: root) else {
            status = .unsafe("Probe project contains non-probe sessions; deletion skipped"); return status
        }
        do {
            try FileManager.default.removeItem(at: root)
            status = .success
        } catch {
            status = .ioError("Failed to delete probe project: \(error.localizedDescription)")
        }
        return status
    }

    /// Convenience: run cleanup only when mode is .auto (used after each probe).
    @discardableResult
    static func cleanupNowIfAuto() -> ResultStatus {
        guard cleanupMode() == .auto else {
            return .disabled("Cleanup mode is not auto")
        }
        return cleanupIfSafe()
    }

    /// Manual cleanup independent of mode; still performs safety checks.
    static func cleanupNowUserInitiated() -> ResultStatus {
        var status: ResultStatus
        defer { postCleanupStatus(status, mode: "manual") }
        guard let projectID = discoverProbeProjectId() else {
            status = .notFound("No probe project found; run a probe first"); return status
        }
        let root = claudeProjectsRoot().appendingPathComponent(projectID)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            status = .notFound("Probe project directory is missing"); return status
        }
        guard validateProjectContents(projectDir: root) else {
            status = .unsafe("Probe project contains non-probe sessions; deletion skipped"); return status
        }
        do {
            try FileManager.default.removeItem(at: root)
            status = .success
        } catch {
            status = .ioError("Failed to delete probe project: \(error.localizedDescription)")
        }
        return status
    }

    private static func postCleanupStatus(_ status: ResultStatus, mode: String) {
        let info: [String: Any] = [
            "mode": mode,
            "status": status.kind,
            "message": status.message ?? ""
        ]
        NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: info)
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
        // Enumerate JSONL/NDJSON files and ensure the first user message for each session starts with the probe marker.
        guard let enumerator = FileManager.default.enumerator(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        // Track first-user check per sessionId
        var firstUserChecked = Set<String>()
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext != "jsonl" && ext != "ndjson" { continue }
            guard let reader = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in reader.split(whereSeparator: { $0.isNewline }) {
                guard let data = String(line).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let sid = (obj["sessionId"] as? String) ?? "?"
                if firstUserChecked.contains(sid) { continue }
                // Identify first user message for this session
                if isUserEvent(obj), let txt = extractText(obj), txt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(ClaudeProbeConfig.markerPrefix) {
                    firstUserChecked.insert(sid)
                } else if isUserEvent(obj) {
                    // First user message does not have the marker → unsafe
                    return false
                }
            }
        }
        // If we never saw any user messages at all, fail closed to be safe
        return !firstUserChecked.isEmpty
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
