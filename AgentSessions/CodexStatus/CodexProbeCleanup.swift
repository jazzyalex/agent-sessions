import Foundation

/// Safety-checked deletion of Codex probe sessions from ~/.codex/sessions.
enum CodexProbeCleanup {
    static let didRunCleanupNotification = Notification.Name("CodexProbeCleanupDidRun")
    private static let probeDirectoryKeys: Set<String> = ["cwd", "project", "working_directory", "workingdirectory", "probe_wd"]
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
        if !FeatureFlags.allowCodexProbeDeletion {
            let status = ResultStatus.disabled("Policy: deletion disabled")
            post(status, mode: "auto")
            return status
        }
        guard cleanupMode() == .auto else {
            let status = ResultStatus.disabled("Cleanup mode is not auto")
            post(status, mode: "auto")
            return status
        }
        let result = performCleanupCore()
        post(result.status, mode: "auto", extra: result.extra)
        return result.status
    }

    static func cleanupNowUserInitiated() -> ResultStatus {
        if !FeatureFlags.allowCodexProbeDeletion {
            let status = ResultStatus.disabled("Policy: deletion disabled")
            post(status, mode: "manual")
            return status
        }
        let result = performCleanupCore()
        post(result.status, mode: "manual", extra: result.extra)
        return result.status
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
                    for u in items where u.pathExtension.lowercased() == "jsonl" {
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
        let probeWD = CodexProbeConfig.probeWorkingDirectory()
        let normalizedProbeWD = normalize(probeWD)
        for raw in lines.prefix(400) {
            guard let jsonData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            if containsProbeWorkingDirectory(in: obj, normalizedProbeWD: normalizedProbeWD) {
                return true
            }
        }
        return false
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

    private static func containsProbeWorkingDirectory(in object: [String: Any], normalizedProbeWD: String, depth: Int = 0) -> Bool {
        if depth > 4 { return false }
        for (key, value) in object {
            let loweredKey = key.lowercased()
            if let candidate = value as? String,
               probeDirectoryKeys.contains(loweredKey),
               normalize(candidate) == normalizedProbeWD {
                return true
            }
            if let nested = value as? [String: Any], containsProbeWorkingDirectory(in: nested, normalizedProbeWD: normalizedProbeWD, depth: depth + 1) {
                return true
            }
            if let nestedArray = value as? [[String: Any]] {
                for element in nestedArray where containsProbeWorkingDirectory(in: element, normalizedProbeWD: normalizedProbeWD, depth: depth + 1) {
                    return true
                }
            } else if let heteroArray = value as? [Any] {
                for element in heteroArray {
                    guard let nested = element as? [String: Any] else { continue }
                    if containsProbeWorkingDirectory(in: nested, normalizedProbeWD: normalizedProbeWD, depth: depth + 1) {
                        return true
                    }
                }
            }
        }
        return false
    }

    

    private static func post(_ status: ResultStatus, mode: String) {
        post(status, mode: mode, extra: [:])
    }

    private static func post(_ status: ResultStatus, mode: String, extra: [String: any Sendable]) {
        var info: [String: any Sendable] = ["mode": mode]
        switch status {
        case .success(let n): info["status"] = "success"; info["deleted"] = n
        case .disabled: info["status"] = "disabled"
        case .notFound(let s): info["status"] = "not_found"; info["message"] = s
        case .unsafe(let s): info["status"] = "unsafe"; info["message"] = s
        case .ioError(let s): info["status"] = "io_error"; info["message"] = s
        }
        // Merge in any extras (e.g., skipped, oldest_ts)
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
}

// MARK: - Shared cleanup core used by auto and manual
private extension CodexProbeCleanup {
    struct CleanupAggregate { let status: ResultStatus; let extra: [String: any Sendable] }

    static func performCleanupCore() -> CleanupAggregate {
        let root = sessionsRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return CleanupAggregate(status: .notFound("Sessions directory not found"), extra: [:])
        }
        let candidates = findCandidateFiles(root: root, daysBack: 30, limit: 512)
        var toDelete: [URL] = []
        var oldest: Date? = nil
        for url in candidates where isProbeFile(url: url) {
            toDelete.append(url)
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mt = rv?.contentModificationDate {
                if let o = oldest { oldest = min(o, mt) } else { oldest = mt }
            }
        }
        guard !toDelete.isEmpty else {
            return CleanupAggregate(status: .notFound("No Codex probe sessions found"), extra: [:])
        }
        var deleted = 0
        for url in toDelete {
            do { try FileManager.default.removeItem(at: url); deleted += 1 }
            catch { return CleanupAggregate(status: .ioError(error.localizedDescription), extra: ["deleted": deleted]) }
        }
        var extra: [String: any Sendable] = ["deleted": deleted]
        if let ts = oldest?.timeIntervalSince1970 { extra["oldest_ts"] = ts }
        return CleanupAggregate(status: .success(deleted), extra: extra)
    }
}
