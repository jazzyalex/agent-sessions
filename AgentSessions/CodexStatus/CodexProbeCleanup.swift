import Foundation

/// Safety-checked deletion of Codex probe sessions from ~/.codex/sessions.
enum CodexProbeCleanup {
    static let didRunCleanupNotification = Notification.Name("CodexProbeCleanupDidRun")
    private enum Keys { static let cleanupMode = "CodexProbeCleanupMode" }
    enum CleanupMode: String { case none, auto }
    enum ResultStatus { case success(Int), disabled(String), notFound(String), unsafe(String), ioError(String) }

    static func cleanupMode() -> CleanupMode {
        let raw = UserDefaults.standard.string(forKey: Keys.cleanupMode) ?? CleanupMode.none.rawValue
        return CleanupMode(rawValue: raw) ?? .none
    }
    static func setCleanupMode(_ mode: CleanupMode) { UserDefaults.standard.set(mode.rawValue, forKey: Keys.cleanupMode) }

    @discardableResult
    static func cleanupNowIfAuto() -> ResultStatus {
        let res: ResultStatus
        if cleanupMode() == .auto {
            res = cleanupNowUserInitiated()
        } else {
            res = .disabled("Cleanup mode is not auto")
        }
        post(res, mode: "auto")
        return res
    }

    static func cleanupNowUserInitiated() -> ResultStatus {
        let root = sessionsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            let r: ResultStatus = .notFound("Sessions directory not found"); post(r, mode: "manual"); return r
        }
        // Scan recent days to keep things fast
        let candidates = findCandidateFiles(root: root, daysBack: 7, limit: 64)
        var deletions: [URL] = []
        for url in candidates {
            if isProbeFile(url: url) { deletions.append(url) }
        }
        guard !deletions.isEmpty else { let r: ResultStatus = .notFound("No probe sessions found"); post(r, mode: "manual"); return r }
        var deleted = 0
        for url in deletions {
            do { try FileManager.default.removeItem(at: url); deleted += 1 } catch { let r: ResultStatus = .ioError(error.localizedDescription); post(r, mode: "manual"); return r }
        }
        let r: ResultStatus = .success(deleted); post(r, mode: "manual"); return r
    }

    // MARK: - Helpers

    private static func sessionsRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    private static func findCandidateFiles(root: URL, daysBack: Int, limit: Int) -> [URL] {
        var urls: [URL] = []
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let fm = FileManager.default
        for offset in 0...daysBack {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let folder = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                    for u in items where u.lastPathComponent.hasPrefix("rollout-") && u.pathExtension.lowercased() == "jsonl" {
                        urls.append(u)
                    }
                }
            }
            if urls.count >= limit { break }
        }
        return urls
    }

    private static func isProbeFile(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        // Read just the head; we only need the first user line and optional cwd
        let data = try? fh.read(upToCount: 256 * 1024) ?? Data()
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        var sawMarker = false
        var sawProbeWD = false
        let probeWD = CodexProbeConfig.probeWorkingDirectory()
        for raw in lines.prefix(400) {
            guard let jsonData = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            // cwd/project heuristic
            if !sawProbeWD {
                if let cwd = obj["cwd"] as? String, normalize(cwd) == normalize(probeWD) { sawProbeWD = true }
                else if let project = obj["project"] as? String, normalize(project) == normalize(probeWD) { sawProbeWD = true }
            }
            // first user message marker
            if !sawMarker, isUserEvent(obj) {
                if let message = extractText(obj), message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(CodexProbeConfig.markerPrefix) {
                    sawMarker = true
                } else {
                    // First user without marker → not a probe
                    return false
                }
            }
            if sawMarker && sawProbeWD { return true }
        }
        return sawMarker || sawProbeWD
    }

    private static func isUserEvent(_ obj: [String: Any]) -> Bool {
        if let type = (obj["type"] as? String)?.lowercased() {
            if ["user", "user_input", "input", "prompt", "chat_input"].contains(type) { return true }
        }
        if let role = (obj["role"] as? String)?.lowercased(), role == "user" { return true }
        if let sender = (obj["sender"] as? String)?.lowercased(), sender == "user" { return true }
        return false
    }

    private static func extractText(_ obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            if let s = message["content"] as? String { return s }
            if let s = message["text"] as? String { return s }
        }
        if let s = obj["content"] as? String { return s }
        if let s = obj["text"] as? String { return s }
        return nil
    }

    private static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.replacingOccurrences(of: "//", with: "/")
    }

    private static func post(_ status: ResultStatus, mode: String) {
        var info: [String: Any] = ["mode": mode]
        switch status {
        case .success(let n): info["status"] = "success"; info["deleted"] = n
        case .disabled: info["status"] = "disabled"
        case .notFound(let s): info["status"] = "not_found"; info["message"] = s
        case .unsafe(let s): info["status"] = "unsafe"; info["message"] = s
        case .ioError(let s): info["status"] = "io_error"; info["message"] = s
        }
        NotificationCenter.default.post(name: didRunCleanupNotification, object: nil, userInfo: info)
    }
}
