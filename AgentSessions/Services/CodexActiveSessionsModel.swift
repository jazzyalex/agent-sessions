import Foundation
import SwiftUI
import Darwin

struct CodexActivePresence: Codable, Equatable, Sendable {
    struct Terminal: Codable, Equatable, Sendable {
        var termProgram: String?
        var itermSessionId: String?
        var revealUrl: String?
    }

    var schemaVersion: Int?
    var publisher: String?
    var kind: String?

    /// Codex's internal session id (preferred join key).
    var sessionId: String?

    /// Absolute JSONL log path for the session (best-effort join key).
    var sessionLogPath: String?

    /// Best-effort workspace root (cwd / project root).
    var workspaceRoot: String?

    var pid: Int?
    var tty: String?
    var startedAt: Date?
    var lastSeenAt: Date?
    var terminal: Terminal?

    // Local-only metadata (not part of the on-disk schema).
    var sourceFilePath: String? = nil

    var itermSessionGuid: String? {
        CodexActiveSessionsModel.itermSessionGuid(from: terminal?.itermSessionId)
    }

    var revealURL: URL? {
        if let guid = itermSessionGuid, !guid.isEmpty {
            // iTerm2 session `id` (AppleScript) is the GUID. `ITERM_SESSION_ID` is often `w0t0p0:<GUID>`.
            return URL(string: "iterm2:///reveal?sessionid=\(guid)")
        }
        if let raw = terminal?.revealUrl, let url = URL(string: raw) { return url }
        return nil
    }

    func isStale(now: Date, ttl: TimeInterval) -> Bool {
        guard let lastSeenAt else { return true }
        return now.timeIntervalSince(lastSeenAt) > ttl
    }
}

@MainActor
final class CodexActiveSessionsModel: ObservableObject {
    static let defaultPollInterval: TimeInterval = 2
    static let defaultStaleTTL: TimeInterval = 10
    nonisolated private static let processProbeTimeout: TimeInterval = 0.75
    nonisolated private static let processProbeMinInterval: TimeInterval = 6

    @Published private(set) var presences: [CodexActivePresence] = []
    @Published private(set) var lastRefreshAt: Date? = nil

    @AppStorage(PreferencesKey.Cockpit.codexActiveSessionsEnabled)
    private var enabled: Bool = true {
        didSet {
            if enabled { startPollingIfNeeded() }
            else { stopPolling(clear: true) }
        }
    }

    @AppStorage(PreferencesKey.Cockpit.codexActiveRegistryRootOverride)
    private var registryRootOverride: String = "" {
        didSet { refreshSoon() }
    }

    private var pollTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil

    private var bySessionID: [String: CodexActivePresence] = [:]
    private var byLogPath: [String: CodexActivePresence] = [:]
    private var cachedProcessPresences: [CodexActivePresence] = []
    private var lastProcessProbeAt: Date? = nil

    init() {
        // Avoid background activity under `xcodebuild test`.
        guard !AppRuntime.isRunningTests else { return }
        startPollingIfNeeded()
    }

    deinit {
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    func isActive(_ session: Session) -> Bool {
        presence(for: session) != nil
    }

    func presence(for session: Session) -> CodexActivePresence? {
        guard session.source == .codex else { return nil }

        let filePath = Self.normalizePath(session.filePath)
        if let p = byLogPath[filePath] { return p }

        if let id = session.codexInternalSessionID, let p = bySessionID[id] { return p }
        if let id = session.codexFilenameUUID, let p = bySessionID[id] { return p }
        return nil
    }

    func revealURL(for session: Session) -> URL? {
        presence(for: session)?.revealURL
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard enabled else { return }
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.defaultPollInterval * 1_000_000_000))
            }
        }
    }

    private func stopPolling(clear: Bool) {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if clear {
            presences = []
            bySessionID = [:]
            byLogPath = [:]
            cachedProcessPresences = []
            lastProcessProbeAt = nil
        }
    }

    private func refreshSoon() {
        // Coalesce rapid preference edits.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.refreshOnce()
        }
    }

    private func refreshOnce() async {
        guard enabled else { return }

        let now = Date()
        let ttl = Self.defaultStaleTTL
        let rootPaths = registryRoots().map(\.path)
        let sessionsRoots = codexSessionsRoots().map(\.path)
        let shouldProbeProcesses: Bool = {
            guard let last = lastProcessProbeAt else { return true }
            return now.timeIntervalSince(last) >= Self.processProbeMinInterval
        }()
        let cachedProbeSnapshot = cachedProcessPresences

        let probeResult: (loaded: [CodexActivePresence], didProbe: Bool) = await Task.detached(priority: .utility) {
            var out: [CodexActivePresence] = []
            let decoder = Self.makeDecoder()
            for path in rootPaths {
                out.append(contentsOf: Self.loadPresences(from: URL(fileURLWithPath: path), decoder: decoder, now: now, ttl: ttl))
            }
            let needsProbe = shouldProbeProcesses || out.isEmpty
            if needsProbe {
                // Periodic fallback probe keeps mixed registry/non-registry environments complete.
                out.append(contentsOf: Self.discoverPresencesFromRunningCodexProcesses(
                    now: now,
                    sessionsRoots: sessionsRoots,
                    timeout: Self.processProbeTimeout
                ))
                return (out, true)
            } else {
                // Reuse recent probe findings between probe intervals.
                out.append(contentsOf: cachedProbeSnapshot.filter { !$0.isStale(now: now, ttl: ttl) })
                return (out, false)
            }
        }.value
        let loaded = probeResult.loaded

        if probeResult.didProbe {
            let latestProbe = loaded.filter { $0.sourceFilePath == nil }
            cachedProcessPresences = latestProbe
            lastProcessProbeAt = now
        } else {
            cachedProcessPresences = cachedProcessPresences.filter { !$0.isStale(now: now, ttl: ttl) }
        }

        // Deduplicate and merge: keep freshest lastSeenAt, but preserve metadata from any source.
        var sessionMap: [String: CodexActivePresence] = [:]
        var logMap: [String: CodexActivePresence] = [:]
        for p in loaded {
            if let id = p.sessionId, !id.isEmpty {
                sessionMap[id] = Self.merge(sessionMap[id], p)
            }
            if let log = p.sessionLogPath, !log.isEmpty {
                let norm = Self.normalizePath(log)
                logMap[norm] = Self.merge(logMap[norm], p)
            }
        }

        // Use log-path map + session-id map for lookup, but keep a stable list for UI.
        var ui: [CodexActivePresence] = Array(logMap.values)
        for p in sessionMap.values {
            if let log = p.sessionLogPath, !log.isEmpty, logMap[Self.normalizePath(log)] != nil { continue }
            ui.append(p)
        }
        presences = ui.sorted(by: { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) })
        bySessionID = sessionMap
        byLogPath = logMap
        lastRefreshAt = now
    }

    // MARK: - Registry Root Discovery

    private func registryRoots() -> [URL] {
        var candidates: [URL] = []

        if let override = Self.parsePath(registryRootOverride) {
            candidates.append(override)
        }

        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("active"))
        }

        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL.deletingLastPathComponent().appendingPathComponent("active"))
        }

        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/active"))

        // Dedup by normalized path.
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    private func codexSessionsRoots() -> [URL] {
        var candidates: [URL] = []

        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL)
        }

        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("sessions"))
        }

        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))

        // Dedup by normalized path.
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    // MARK: - Loading

    nonisolated static func loadPresences(from root: URL,
                                          decoder: JSONDecoder,
                                          now: Date,
                                          ttl: TimeInterval) -> [CodexActivePresence] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var out: [CodexActivePresence] = []
        for url in items where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var p = try? decoder.decode(CodexActivePresence.self, from: data) else { continue }
            p.sourceFilePath = url.path
            if p.isStale(now: now, ttl: ttl) { continue }
            out.append(p)
        }
        return out
    }

    // MARK: - Helpers

    private static func merge(_ existing: CodexActivePresence?, _ incoming: CodexActivePresence) -> CodexActivePresence {
        guard let existing else { return incoming }

        let ta = existing.lastSeenAt ?? .distantPast
        let tb = incoming.lastSeenAt ?? .distantPast
        let winner = tb >= ta ? incoming : existing
        let loser = tb >= ta ? existing : incoming

        var merged = winner

        func prefer(_ a: String?, _ b: String?) -> String? {
            if let a, !a.isEmpty { return a }
            if let b, !b.isEmpty { return b }
            return nil
        }

        merged.publisher = prefer(merged.publisher, loser.publisher)
        merged.kind = prefer(merged.kind, loser.kind)
        merged.sessionId = prefer(merged.sessionId, loser.sessionId)
        merged.sessionLogPath = prefer(merged.sessionLogPath, loser.sessionLogPath)
        merged.workspaceRoot = prefer(merged.workspaceRoot, loser.workspaceRoot)
        merged.pid = merged.pid ?? loser.pid
        merged.tty = prefer(merged.tty, loser.tty)
        merged.startedAt = merged.startedAt ?? loser.startedAt
        merged.lastSeenAt = max(ta, tb)
        merged.sourceFilePath = prefer(merged.sourceFilePath, loser.sourceFilePath)

        if merged.terminal == nil { merged.terminal = loser.terminal }
        if var t = merged.terminal {
            let other = loser.terminal
            t.termProgram = prefer(t.termProgram, other?.termProgram)
            t.itermSessionId = prefer(t.itermSessionId, other?.itermSessionId)
            t.revealUrl = prefer(t.revealUrl, other?.revealUrl)
            merged.terminal = t
        }

        return merged
    }

    private static func parsePath(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    nonisolated private static func normalizePath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let dt = LenientISO8601.parse(raw) { return dt }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 timestamp: \(raw)")
        }
        return d
    }

    // MARK: - iTerm2 Focus

    /// iTerm2's AppleScript session id is the GUID portion; env vars are often `w0t0p0:<GUID>`.
    nonisolated static func itermSessionGuid(from raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let idx = trimmed.lastIndex(of: ":") {
            let next = trimmed.index(after: idx)
            let tail = trimmed[next...].trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? nil : String(tail)
        }
        return trimmed
    }

    nonisolated static func canAttemptITerm2Focus(itermSessionId: String?, tty: String?, termProgram: String?) -> Bool {
        if let guid = itermSessionGuid(from: itermSessionId), !guid.isEmpty { return true }
        guard let tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return false }
        let term = (termProgram ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if term.contains("iterm") { return true }
        return false
    }

    /// Best-effort focus for iTerm2 sessions that works across windows/tabs (and usually Spaces).
    /// Returns `true` if iTerm2 reported the target session was selected.
    nonisolated static func tryFocusITerm2(itermSessionId: String?, tty: String?) -> Bool {
        let guid = itermSessionGuid(from: itermSessionId) ?? ""
        let ttyValue = (tty ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTTY = ttyValue.isEmpty ? "" : ttyValue

        guard !guid.isEmpty || !targetTTY.isEmpty else { return false }

        let scriptLines = [
            "on run argv",
            "set targetGuid to \"\"",
            "set targetTTY to \"\"",
            "if (count of argv) >= 1 then set targetGuid to item 1 of argv",
            "if (count of argv) >= 2 then set targetTTY to item 2 of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
            "tell application \"iTerm2\"",
            "activate",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "if ((targetGuid is not \"\" and sid is targetGuid) or (targetTTYBase is not \"\" and (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase))) then",
            "try",
            "select w",
            "end try",
            "try",
            "select t",
            "end try",
            "select s",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"not found\"",
            "end run"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = scriptLines.flatMap { ["-e", $0] } + [guid, targetTTY]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        guard process.terminationStatus == 0 else {
            return false
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out == "ok"
    }

    // MARK: - Live Process Discovery (Fallback)

    /// Best-effort: infer active sessions by scanning running `codex` processes and the JSONL file they have open.
    /// This is used when Codex CLI itself does not publish a stable active-session registry.
    nonisolated static func discoverPresencesFromRunningCodexProcesses(now: Date,
                                                                       sessionsRoots: [String],
                                                                       timeout: TimeInterval) -> [CodexActivePresence] {
        let lsofPath = "/usr/sbin/lsof"
        let psPath = "/bin/ps"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: lsofPath), fm.isExecutableFile(atPath: psPath) else { return [] }

        let roots = sessionsRoots.map(normalizePath)
        let user = NSUserName()

        // `lsof -F pftn` gives us PID + per-fd records including `cwd`, tty device, and open JSONL log path.
        guard let lsofOut = runCommand(
            executable: URL(fileURLWithPath: lsofPath),
            arguments: ["-w", "-a", "-c", "codex", "-u", user, "-nP", "-F", "pftn"],
            timeout: timeout
        ) else {
            return []
        }

        let lsofText = String(decoding: lsofOut, as: UTF8.self)
        var infos = parseLsofMachineOutput(lsofText, sessionsRoots: roots)
        if infos.isEmpty { return [] }

        // Enrich with iTerm session ids via `ps eww -p ...` (env vars).
        let pidCSV = infos.keys.sorted().map(String.init).joined(separator: ",")
        if let psOut = runCommand(
            executable: URL(fileURLWithPath: psPath),
            arguments: ["eww", "-p", pidCSV],
            timeout: timeout
        ) {
            let psText = String(decoding: psOut, as: UTF8.self)
            let env = parsePSEnvironmentOutput(psText)
            for (pid, meta) in env {
                if infos[pid] != nil {
                    infos[pid]?.termProgram = meta.termProgram
                    infos[pid]?.itermSessionId = meta.itermSessionId
                }
            }
        }

        var out: [CodexActivePresence] = []
        out.reserveCapacity(infos.count)
        for info in infos.values {
            guard let logPath = info.sessionLogPath else { continue }
            var p = CodexActivePresence()
            p.schemaVersion = 1
            p.publisher = "agent-sessions-process"
            p.kind = "interactive"
            p.sessionLogPath = logPath
            p.workspaceRoot = info.cwd
            p.pid = info.pid
            p.tty = info.tty
            p.startedAt = nil
            p.lastSeenAt = now
            var t = CodexActivePresence.Terminal()
            t.termProgram = info.termProgram
            t.itermSessionId = info.itermSessionId
            // Don't precompute revealUrl; CodexActivePresence will synthesize from itermSessionId.
            p.terminal = t
            out.append(p)
        }
        return out
    }

    // MARK: - Command Runner

    struct PSProcessEnvMeta: Equatable, Sendable {
        var termProgram: String?
        var itermSessionId: String?
    }

    struct LsofPIDInfo: Equatable, Sendable {
        var pid: Int
        var cwd: String?
        var tty: String?
        var sessionLogPath: String?
        var termProgram: String?
        var itermSessionId: String?
    }

    /// Run a local command with a small timeout. Returns stdout on success.
    nonisolated private static func runCommand(executable: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout in the background; `readDataToEndOfFile` blocks until the process closes stdout.
        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            // If SIGTERM doesn't work quickly, force-kill.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = group.wait(timeout: .now() + 0.25)
            return nil
        }

        // Allow non-zero exit codes; `lsof` can return 1 when no matches.
        return outData
    }

    // MARK: - Parsers (Testable)

    nonisolated static func parseLsofMachineOutput(_ text: String, sessionsRoots: [String]) -> [Int: LsofPIDInfo] {
        var infos: [Int: LsofPIDInfo] = [:]

        var currentPID: Int? = nil
        var currentFD: String? = nil
        var currentType: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = rawLine.dropFirst()

            switch tag {
            case "p":
                if let pid = Int(value) {
                    currentPID = pid
                    infos[pid, default: LsofPIDInfo(pid: pid)].pid = pid
                } else {
                    currentPID = nil
                }
                currentFD = nil
                currentType = nil

            case "f":
                currentFD = String(value)

            case "t":
                currentType = String(value)

            case "n":
                guard let pid = currentPID else { continue }
                let name = String(value)
                var info = infos[pid] ?? LsofPIDInfo(pid: pid)

                // `cwd` record
                if currentFD == "cwd", currentType == "DIR" {
                    info.cwd = name
                    infos[pid] = info
                    continue
                }

                // Heuristic: tty device appears as fd 0/1/2, type CHR, name /dev/ttys* or /dev/pts/*
                if info.tty == nil,
                   (currentFD == "0" || currentFD == "1" || currentFD == "2"),
                   currentType == "CHR" {
                    let ttyName: String = {
                        if name.hasPrefix("/dev/") { return name }
                        if name.hasPrefix("dev/") { return "/" + name }
                        return name
                    }()
                    if ttyName.hasPrefix("/dev/ttys") || ttyName.hasPrefix("/dev/pts/") {
                        info.tty = ttyName
                        infos[pid] = info
                        continue
                    }
                    infos[pid] = info
                    continue
                }

                // Session log path: prefer Codex rollout JSONL under configured sessions roots.
                if name.hasSuffix(".jsonl"),
                   (name as NSString).lastPathComponent.hasPrefix("rollout-"),
                   sessionsRoots.contains(where: { root in
                       let rp = root.hasSuffix("/") ? root : (root + "/")
                       return name.hasPrefix(rp)
                   }) {
                    // Prefer a writable fd if present (e.g., 26w).
                    let isWrite = (currentFD?.contains("w") ?? false)
                    if info.sessionLogPath == nil || isWrite {
                        info.sessionLogPath = name
                    }
                    infos[pid] = info
                }

            default:
                continue
            }
        }

        // Keep only entries that look like a live terminal session.
        return infos.filter { _, v in
            v.sessionLogPath != nil && v.tty != nil
        }
    }

    nonisolated static func parsePSEnvironmentOutput(_ text: String) -> [Int: PSProcessEnvMeta] {
        var out: [Int: PSProcessEnvMeta] = [:]
        for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            // Skip header
            if idx == 0, line.contains("PID") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, let pid = Int(first) else { continue }

            let raw = String(line)
            func extract(_ key: String) -> String? {
                guard let r = raw.range(of: key + "=") else { return nil }
                let after = raw[r.upperBound...]
                return after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            }

            let iterm = extract("ITERM_SESSION_ID") ?? extract("TERM_SESSION_ID")
            let termProgram = extract("TERM_PROGRAM")
            if iterm == nil && termProgram == nil { continue }
            out[pid] = PSProcessEnvMeta(termProgram: termProgram, itermSessionId: iterm)
        }
        return out
    }
}

private enum LenientISO8601 {
    private static let lock = NSLock()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = fractional.date(from: s) { return d }
        return plain.date(from: s)
    }
}
