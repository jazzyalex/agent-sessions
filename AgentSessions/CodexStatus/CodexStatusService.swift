import Foundation
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

// ILLUSTRATIVE: Minimal model + service for Codex usage parsing with optional CLI /status probe.

// Snapshot of parsed values from Codex /status or banner
struct CodexUsageSnapshot: Equatable {
    var fiveHourPercent: Int = 0
    var fiveHourResetText: String = ""
    var weekPercent: Int = 0
    var weekResetText: String = ""
    var usageLine: String? = nil
    var accountLine: String? = nil
    var modelLine: String? = nil
    var eventTimestamp: Date? = nil
    // New: surfaced usage (latest turn or snapshot)
    var lastInputTokens: Int? = nil
    var lastCachedInputTokens: Int? = nil
    var lastOutputTokens: Int? = nil
    var lastReasoningOutputTokens: Int? = nil
    var lastTotalTokens: Int? = nil
}

@MainActor
final class CodexUsageModel: ObservableObject {
    static let shared = CodexUsageModel()

    @Published var fiveHourPercent: Int = 0
    @Published var fiveHourResetText: String = ""
    @Published var weekPercent: Int = 0
    @Published var weekResetText: String = ""
    @Published var usageLine: String? = nil
    @Published var accountLine: String? = nil
    @Published var modelLine: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var lastEventTimestamp: Date? = nil
    @Published var cliUnavailable: Bool = false
    // New: surfaced usage (latest turn)
    @Published var lastInputTokens: Int? = nil
    @Published var lastCachedInputTokens: Int? = nil
    @Published var lastOutputTokens: Int? = nil
    @Published var lastReasoningOutputTokens: Int? = nil
    @Published var lastTotalTokens: Int? = nil

    private var service: CodexStatusService?
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setVisible(_ visible: Bool) {
        // Back-compat shim: treat as strip visibility
        setStripVisible(visible)
    }

    func setStripVisible(_ visible: Bool) {
        stripVisible = visible
        propagateVisibility()
    }

    func setMenuVisible(_ visible: Bool) {
        menuVisible = visible
        propagateVisibility()
    }

    private func propagateVisibility() {
        let union = stripVisible || menuVisible
        Task.detached { [weak self] in
            await self?.service?.setVisible(union)
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                await svc.refreshNow()
                return
            }
            // On-demand one-shot refresh even when tracking is disabled
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            await svc.refreshNow()
        }
    }

    private func start() {
        let model = self
        let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                model.apply(snapshot)
            }
        }
        let availabilityHandler: @Sendable (Bool) -> Void = { unavailable in
            Task { @MainActor in
                model.cliUnavailable = unavailable
            }
        }
        let service = CodexStatusService(updateHandler: handler, availabilityHandler: availabilityHandler)
        self.service = service
        Task.detached {
            await service.start()
        }
    }

    private func stop() {
        Task.detached { [service] in
            await service?.stop()
        }
        service = nil
    }

    private func apply(_ s: CodexUsageSnapshot) {
        fiveHourPercent = clampPercent(s.fiveHourPercent)
        weekPercent = clampPercent(s.weekPercent)
        fiveHourResetText = s.fiveHourResetText
        weekResetText = s.weekResetText
        usageLine = s.usageLine
        accountLine = s.accountLine
        modelLine = s.modelLine
        lastUpdate = Date()
        lastEventTimestamp = s.eventTimestamp
        lastInputTokens = s.lastInputTokens
        lastCachedInputTokens = s.lastCachedInputTokens
        lastOutputTokens = s.lastOutputTokens
        lastReasoningOutputTokens = s.lastReasoningOutputTokens
        lastTotalTokens = s.lastTotalTokens
    }

    private func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }
}

// MARK: - Rate-limit models (log probe)

struct RateLimitWindowInfo {
    var usedPercent: Int?
    var resetAt: Date?
    var windowMinutes: Int?
}

struct RateLimitSummary {
    var fiveHour: RateLimitWindowInfo
    var weekly: RateLimitWindowInfo
    var eventTimestamp: Date?
    var stale: Bool
    var sourceFile: URL?
}

// MARK: - Service

actor CodexStatusService {
    private enum State { case idle, starting, running, stopping }

    // Regex helpers
    private let percentRegex = try! NSRegularExpression(pattern: "(\\d{1,3})\\s*%\\b", options: [.caseInsensitive])
    private let resetParenRegex = try! NSRegularExpression(pattern: #"\((?:reset|resets)\s+([^)]+)\)"#, options: [.caseInsensitive])
    private let resetLineRegex = try! NSRegularExpression(pattern: #"(?:reset|resets)\s*:?\s*(?:at:?\s*)?(.+)$"#, options: [.caseInsensitive])

    private nonisolated let updateHandler: @Sendable (CodexUsageSnapshot) -> Void
    private nonisolated let availabilityHandler: @Sendable (Bool) -> Void

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var state: State = .idle
    private var bufferOut = Data()
    private var bufferErr = Data()
    private var snapshot = CodexUsageSnapshot()
    private var lastFiveHourResetDate: Date?
    private var shouldRun: Bool = true
    private var visible: Bool = false
    private var backoffSeconds: UInt64 = 1
    private var refresherTask: Task<Void, Never>?
    private var lastStatusProbe: Date? = nil

    init(updateHandler: @escaping @Sendable (CodexUsageSnapshot) -> Void,
         availabilityHandler: @escaping @Sendable (Bool) -> Void) {
        self.updateHandler = updateHandler
        self.availabilityHandler = availabilityHandler
    }

    func start() async {
        shouldRun = true
        refresherTask?.cancel()
        refresherTask = Task { [weak self] in
            guard let self else { return }
            while await self.shouldRun {
                await self.refreshTick()
                let interval = await self.nextInterval()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() async {
        shouldRun = false
        refresherTask?.cancel()
        refresherTask = nil
    }

    func setVisible(_ isVisible: Bool) {
        let wasVisible = visible
        visible = isVisible

        // If transitioning from hidden → visible, immediately refresh to show current data
        if !wasVisible && isVisible {
            Task { await self.refreshTick() }
        }
    }

    func refreshNow() {
        Task { await self.refreshTick(userInitiated: true) }
    }

    // MARK: - Core

    private func ensureProcessPrimed() async {
        if process?.isRunning == true { return }
        await launchREPL()
        if process?.isRunning == true {
            backoffSeconds = 1
            availabilityHandler(false)
            await send("ping\n/status\n")
        } else {
            availabilityHandler(true)
        }
    }

    private func launchREPL() async {
        if state == .starting || state == .running { return }
        state = .starting

        // Build a bash -lc command to use user's login shell PATH
        let command = "codex"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bash", "-lc", command]

        var env = ProcessInfo.processInfo.environment
        if let terminalPATH = Self.terminalPATH() { env["PATH"] = terminalPATH }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await self?.consume(data: data, isError: false) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await self?.consume(data: data, isError: true) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = stdin
            stdoutPipe = stdout
            stderrPipe = stderr
            state = .running
        } catch {
            state = .idle
        }
    }

    private func handleTermination() async {
        state = .idle
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        availabilityHandler(true)
        guard shouldRun else { return }
        // Exponential backoff restart
        let delay = min(backoffSeconds, 60)
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        backoffSeconds = min(delay * 2, 60)
        await ensureProcessPrimed()
    }

    private func terminateProcess() async {
        guard let p = process else { return }
        p.interrupt()
        // Give it a moment, then SIGTERM if needed
        try? await Task.sleep(nanoseconds: 500_000_000)
        if p.isRunning { p.terminate() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Avoid using non-existent kill() API on Process; rely on terminate.
        if p.isRunning { p.terminate() }
        process = nil
        state = .idle
    }

    private func send(_ text: String) async {
        guard state == .running, let fh = stdinPipe?.fileHandleForWriting else { return }
        if let data = text.data(using: .utf8) {
            // FileHandle.write(_:) is available and sufficient here.
            fh.write(data)
        }
    }

    private func consume(data: Data, isError: Bool) async {
        if isError { bufferErr.append(data) } else { bufferOut.append(data) }
        // Drain complete lines without holding an inout across await
        let lines = drainLines(fromError: isError)
        for line in lines {
            await handleLine(line)
        }
    }

    private func drainLines(fromError: Bool) -> [String] {
        var produced: [String] = []
        var buffer = fromError ? bufferErr : bufferOut
        while true {
            if let idx = buffer.firstIndex(of: 0x0a) { // newline byte
                let lineData = buffer.subdata(in: 0..<idx)
                buffer.removeSubrange(0...idx)
                if let line = String(data: lineData, encoding: .utf8) {
                    produced.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                break
            }
        }
        // Write back the remaining buffer
        if fromError {
            bufferErr = buffer
        } else {
            bufferOut = buffer
        }
        return produced
    }

    private func handleLine(_ line: String) async {
        if line.isEmpty { return }
        let clean = stripANSI(line)
        let lower = clean.lowercased()
        let isFiveHour = (lower.contains("5h") || lower.contains("5 h") || lower.contains("5-hour") || lower.contains("5 hour")) && lower.contains("limit")
        if isFiveHour {
            var s = snapshot
            s.fiveHourPercent = extractPercent(from: clean) ?? s.fiveHourPercent
            s.fiveHourResetText = extractResetText(from: clean) ?? s.fiveHourResetText
            snapshot = s
            updateHandler(snapshot)
            return
        }
        let isWeekly = (lower.contains("weekly") && lower.contains("limit")) || lower.contains("week limit")
        if isWeekly {
            var s = snapshot
            s.weekPercent = extractPercent(from: clean) ?? s.weekPercent
            s.weekResetText = extractResetText(from: clean) ?? s.weekResetText
            snapshot = s
            updateHandler(snapshot)
            return
        }
        if lower.hasPrefix("account:") { var s = snapshot; s.accountLine = clean; snapshot = s; updateHandler(snapshot); return }
        if lower.hasPrefix("model:") { var s = snapshot; s.modelLine = clean; snapshot = s; updateHandler(snapshot); return }
        if lower.hasPrefix("token usage:") { var s = snapshot; s.usageLine = clean; snapshot = s; updateHandler(snapshot); return }
    }

    private func extractPercent(from line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let m = percentRegex.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            let str = (line as NSString).substring(with: m.range(at: 1))
            return Int(str)
        }
        return nil
    }

    private func extractResetText(from line: String) -> String? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = resetParenRegex.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        if let m = resetLineRegex.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func refreshTick(userInitiated: Bool = false) async {
        // Log-probe path: scan latest JSONL for token_count rate_limits
        let root = sessionsRoot()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            availabilityHandler(true)
            return
        }
        availabilityHandler(false)
        if let summary = probeLatestRateLimits(root: root) {
            var s = snapshot
            if let p = summary.fiveHour.usedPercent { s.fiveHourPercent = clampPercent(p) }
            if let p = summary.weekly.usedPercent { s.weekPercent = clampPercent(p) }
            s.fiveHourResetText = formatCodexReset(summary.fiveHour.resetAt, windowMinutes: summary.fiveHour.windowMinutes)
            s.weekResetText = formatCodexReset(summary.weekly.resetAt, windowMinutes: summary.weekly.windowMinutes)
            lastFiveHourResetDate = summary.fiveHour.resetAt
            s.usageLine = summary.stale ? "Usage is stale (>3m)" : nil
            s.eventTimestamp = summary.eventTimestamp
            snapshot = s
            updateHandler(snapshot)
        }

        // Optional: run a one-shot tmux /status probe when stale or on manual refresh
        await maybeProbeStatusViaTMUX(userInitiated: userInitiated)
    }

    // MARK: - Optional tmux /status probe
    private func maybeProbeStatusViaTMUX(userInitiated: Bool) async {
        let now = Date()
        let allowAuto = UserDefaults.standard.bool(forKey: "CodexAllowStatusProbe")
        if !userInitiated {
            guard allowAuto else { return }
            guard visible else { return }
            let stale5h = isResetInfoStale(kind: "5h", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
            let staleWeek = isResetInfoStale(kind: "week", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
            guard stale5h || staleWeek else { return }
            if let last = lastStatusProbe, now.timeIntervalSince(last) < 600 { return }
        }

        guard let tmuxSnap = await runCodexStatusViaTMUX() else { return }
        lastStatusProbe = now
        var merged = snapshot
        if tmuxSnap.fiveHourPercent > 0 { merged.fiveHourPercent = clampPercent(tmuxSnap.fiveHourPercent) }
        if !tmuxSnap.fiveHourResetText.isEmpty { merged.fiveHourResetText = tmuxSnap.fiveHourResetText }
        if tmuxSnap.weekPercent > 0 { merged.weekPercent = clampPercent(tmuxSnap.weekPercent) }
        if !tmuxSnap.weekResetText.isEmpty { merged.weekResetText = tmuxSnap.weekResetText }
        merged.eventTimestamp = now
        snapshot = merged
        updateHandler(merged)
        _ = CodexProbeCleanup.cleanupNowIfAuto()
    }

    private func runCodexStatusViaTMUX() async -> CodexUsageSnapshot? {
        guard let scriptURL = Bundle.main.url(forResource: "codex_status_capture", withExtension: "sh") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        // Provide WORKDIR to funnel probe sessions
        let workDir = CodexProbeConfig.probeWorkingDirectory()
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        // Do not force a model; use user's current Codex defaults to avoid disrupting sessions
        // Resolve codex binary if possible
        let envResolver = CodexCLIEnvironment()
        if let bin = envResolver.resolveBinary(customPath: nil) { env["CODEX_BIN"] = bin.path }

        process.environment = env
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = String(data: data, encoding: .utf8) else { return nil }
        return parseStatusJSON(json)
    }

    private func parseStatusJSON(_ json: String) -> CodexUsageSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ok = obj["ok"] as? Bool, !ok { return nil }
        var s = CodexUsageSnapshot()
        if let fh = obj["five_hour"] as? [String: Any] {
            if let p = fh["pct_used"] as? Int { s.fiveHourPercent = p }
            if let r = fh["resets"] as? String { s.fiveHourResetText = r }
        }
        if let wk = obj["weekly"] as? [String: Any] {
            if let p = wk["pct_used"] as? Int { s.weekPercent = p }
            if let r = wk["resets"] as? String { s.weekResetText = r }
        }
        s.eventTimestamp = Date()
        return s
    }

    private func nextInterval() -> UInt64 {
        // Read user preference for polling interval (default 120s = 2 min)
        let userInterval = UInt64(UserDefaults.standard.object(forKey: "UsagePollingInterval") as? Int ?? 300)

        // Energy optimization: Stop polling entirely when nothing is visible
        // (menu bar and strips both hidden)
        let urgent = isUrgent()
        if !visible && !urgent {
            // When hidden and not urgent: don't poll at all (1 hour = effectively disabled)
            return 3600 * 1_000_000_000
        }

        // Policy when visible or urgent:
        // - On AC power: use userInterval
        // - On battery: 300s
        if !Self.onACPower() {
            return 300 * 1_000_000_000
        }
        return userInterval * 1_000_000_000
    }

    private func isUrgent() -> Bool {
        if snapshot.fiveHourPercent >= 80 { return true }
        if let reset = lastFiveHourResetDate {
            if reset.timeIntervalSinceNow <= 15 * 60 { return true }
        }
        return false
    }

    private static func onACPower() -> Bool {
        // Best-effort detection using IOKit; fall back to assuming AC if unavailable.
        #if os(macOS)
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() {
            let type = typeCF as String
            return type == (kIOPSACPowerValue as String)
        }
        #endif
        // Fallback: if Low Power Mode is enabled, treat as battery-like
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        }
        return true
    }

    // MARK: - Log probe helpers

    private func sessionsRoot() -> URL {
        if let override = UserDefaults.standard.string(forKey: "SessionsRootOverride"), !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    private func probeLatestRateLimits(root: URL) -> RateLimitSummary? {
        let candidates = findCandidateFiles(root: root, daysBack: 7, limit: 12)
        for url in candidates {
            if let summary = parseTokenCountTail(url: url) { return summary }
        }
        return RateLimitSummary(
            fiveHour: RateLimitWindowInfo(usedPercent: nil, resetAt: nil, windowMinutes: nil),
            weekly: RateLimitWindowInfo(usedPercent: nil, resetAt: nil, windowMinutes: nil),
            eventTimestamp: nil,
            stale: true,
            sourceFile: nil
        )
    }

    private func findCandidateFiles(root: URL, daysBack: Int, limit: Int) -> [URL] {
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
                if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for u in items where u.pathExtension.lowercased() == "jsonl" {
                        urls.append(u)
                    }
                }
            }
            if urls.count >= limit { break }
        }
        urls.sort { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        if urls.count > limit { urls = Array(urls.prefix(limit)) }
        return urls
    }

    private func parseTokenCountTail(url: URL) -> RateLimitSummary? {
        guard let lines = tailLines(url: url, maxBytes: 512 * 1024) else { return nil }
        // Walk most-recent → older. Accept both legacy token_count and new turn.completed payloads
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (obj["type"] as? String) == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }

            // Establish a createdAt for this event early (best-effort)
            let createdAt = decodeFlexibleDate(obj["created_at"]) ??
                            decodeFlexibleDate(payload["created_at"]) ??
                            decodeFlexibleDate(obj["timestamp"]) ??
                            decodeFlexibleDate(payload["timestamp"]) ??
                            Date()

            // Surface usage tokens if present (new or legacy forms)
            extractUsageIfPresent(from: payload, createdAt: createdAt)

            // Prefer any payload that contains rate_limits, regardless of type label
            if let rate = payload["rate_limits"] as? [String: Any] {
                // New format: captured_at anchors relative deltas; prefer it over event timestamp
                let capturedAt = decodeFlexibleDate(rate["captured_at"] as Any?) ?? createdAt
                // Clamp future timestamps (clock skew protection)
                if capturedAt > Date() { continue }

                let primary = rate["primary"] as? [String: Any]
                let secondary = rate["secondary"] as? [String: Any]
                let five = decodeWindow(primary, created: createdAt, capturedAt: capturedAt)
                let week = decodeWindow(secondary, created: createdAt, capturedAt: capturedAt)
                let base = capturedAt
                let stale = Date().timeIntervalSince(base) > 3 * 60
                return RateLimitSummary(fiveHour: five, weekly: week, eventTimestamp: base, stale: stale, sourceFile: url)
            }

            // Legacy: specifically labeled token_count with rate_limits
            if (payload["type"] as? String) == "token_count",
               let rate = payload["rate_limits"] as? [String: Any] {
                let capturedAt = decodeFlexibleDate(rate["captured_at"] as Any?) ?? createdAt
                if capturedAt > Date() { continue }
                let primary = rate["primary"] as? [String: Any]
                let secondary = rate["secondary"] as? [String: Any]
                let five = decodeWindow(primary, created: createdAt, capturedAt: capturedAt)
                let week = decodeWindow(secondary, created: createdAt, capturedAt: capturedAt)
                let base = capturedAt
                let stale = Date().timeIntervalSince(base) > 3 * 60
                return RateLimitSummary(fiveHour: five, weekly: week, eventTimestamp: base, stale: stale, sourceFile: url)
            }
        }
        return nil
    }

    // MARK: - Usage extraction (new + legacy)

    private func extractUsageIfPresent(from payload: [String: Any], createdAt: Date) {
        // New model: turn.completed with usage {...}
        if let kind = payload["type"] as? String, kind == "turn.completed" || kind == "turn_completed" {
            if let usage = payload["usage"] as? [String: Any] {
                var s = snapshot
                s.lastInputTokens = intValue(usage["input_tokens"]) ?? s.lastInputTokens
                s.lastCachedInputTokens = intValue(usage["cached_input_tokens"]) ?? s.lastCachedInputTokens
                s.lastOutputTokens = intValue(usage["output_tokens"]) ?? s.lastOutputTokens
                s.lastReasoningOutputTokens = intValue(usage["reasoning_output_tokens"]) ?? s.lastReasoningOutputTokens
                if let i = s.lastInputTokens, let o = s.lastOutputTokens {
                    s.lastTotalTokens = i + o
                } else {
                    s.lastTotalTokens = intValue(usage["total_tokens"]) ?? s.lastTotalTokens
                }
                snapshot = s
                updateHandler(snapshot)
                // Usage sampling for cap ETA disabled; analytics will compute on demand.
                return
            }
        }
        // Legacy path: token_count.info.last_token_usage {...}
        if let kind = payload["type"] as? String, kind == "token_count" {
            if let info = payload["info"] as? [String: Any] {
                if let last = info["last_token_usage"] as? [String: Any] {
                    var s = snapshot
                    s.lastInputTokens = intValue(last["input_tokens"]) ?? s.lastInputTokens
                    s.lastCachedInputTokens = intValue(last["cached_input_tokens"]) ?? s.lastCachedInputTokens
                    s.lastOutputTokens = intValue(last["output_tokens"]) ?? s.lastOutputTokens
                    s.lastReasoningOutputTokens = intValue(last["reasoning_output_tokens"]) ?? s.lastReasoningOutputTokens
                    s.lastTotalTokens = intValue(last["total_tokens"]) ?? ((s.lastInputTokens ?? 0) + (s.lastOutputTokens ?? 0))
                    snapshot = s
                    updateHandler(snapshot)
                    // Usage sampling for cap ETA disabled; analytics will compute on demand.
                }
            }
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Double(s) { return Int(v.rounded()) }
        return nil
    }

    // MARK: - Flexible date decoding for Codex logs

    private func decodeFlexibleDate(_ any: Any?) -> Date? {
        guard let any = any else { return nil }
        // Numeric epoch seconds/millis/micros
        if let d = any as? Double { return Date(timeIntervalSince1970: normalizeEpochSeconds(d)) }
        if let i = any as? Int { return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(i))) }
        if let s = any as? String {
            // Digits-only string → numeric epoch
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)),
               let val = Double(s) {
                return Date(timeIntervalSince1970: normalizeEpochSeconds(val))
            }
            // ISO8601 with or without fractional seconds
            let iso1 = ISO8601DateFormatter(); iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso1.date(from: s) { return d }
            let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: s) { return d }
            // Common textual fallbacks
            let fmts = [
                "yyyy-MM-dd HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ssZZZZZ",
                "yyyy/MM/dd HH:mm:ss"
            ]
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
            for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        }
        return nil
    }

    private func normalizeEpochSeconds(_ value: Double) -> Double {
        // Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private func decodeWindow(_ dict: [String: Any]?, created: Date, capturedAt: Date?) -> RateLimitWindowInfo {
        guard let dict else { return RateLimitWindowInfo(usedPercent: nil, resetAt: nil, windowMinutes: nil) }
        var used: Int?
        if let d = dict["used_percent"] as? Double { used = Int(d.rounded()) }
        else if let i = dict["used_percent"] as? Int { used = max(0, min(100, i)) }
        else if let n = dict["used_percent"] as? NSNumber { used = Int(truncating: n) }

        var resetsVal: Double?
        if let d = dict["resets_in_seconds"] as? Double { resetsVal = d }
        else if let i = dict["resets_in_seconds"] as? Int { resetsVal = Double(i) }
        else if let n = dict["resets_in_seconds"] as? NSNumber { resetsVal = n.doubleValue }

        let minutes = dict["window_minutes"] as? Int

        var resetAt: Date?
        if let delta = resetsVal {
            // New semantics: delta is relative to capturedAt when present
            let base = capturedAt ?? created
            resetAt = base.addingTimeInterval(delta)
        }

        // New format uses absolute epoch under various keys (resets_at / reset_at / resetsAt)
        if resetAt == nil {
            let absoluteKeys = [
                "resets_at",
                "reset_at",
                "resetsAt",
                "resetAt",
                "resets_at_ms",
                "reset_at_ms"
            ]
            for key in absoluteKeys {
                guard let value = dict[key] else { continue }
                if key.hasSuffix("_ms") {
                    if let num = value as? Double {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num))
                        break
                    }
                    if let num = value as? Int {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(Double(num)))
                        break
                    }
                    if let num = value as? NSNumber {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num.doubleValue))
                        break
                    }
                    if let s = value as? String, let num = Double(s) {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num))
                        break
                    }
                } else if let date = decodeFlexibleDate(value) {
                    resetAt = date
                    break
                }
            }
        }

        return RateLimitWindowInfo(usedPercent: used, resetAt: resetAt, windowMinutes: minutes)
    }

    private func tailLines(url: URL, maxBytes: Int) -> [String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let toRead = min(maxBytes, max(0, fileSize))
        let startOffset = UInt64(max(0, fileSize - toRead))
        do { try fh.seek(toOffset: startOffset) } catch { return nil }
        let data = (try? fh.readToEnd()) ?? Data()
        guard !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { if let lastNL = text.lastIndex(of: "\n") { text = String(text[..<lastNL]) } }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    }

    private func formatCodexReset(_ date: Date?, windowMinutes: Int?) -> String {
        guard let date else { return "" }
        let tz = TimeZone(identifier: "America/Los_Angeles")
        let timeOnly = DateFormatter()
        timeOnly.locale = Locale(identifier: "en_US_POSIX")
        timeOnly.timeZone = tz
        timeOnly.dateFormat = "HH:mm"
        let t = timeOnly.string(from: date)
        // 5-hour window → (resets HH:mm). Weekly → resets HH:mm on d MMM
        if let w = windowMinutes, w <= 360 { // treat <=6h as 5h style
            return "resets \(t)"
        } else {
            let dayFmt = DateFormatter()
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            dayFmt.timeZone = tz
            dayFmt.dateFormat = "d MMM"
            let d = dayFmt.string(from: date)
            return "resets \(t) on \(d)"
        }
    }

    private func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }

    private func stripANSI(_ s: String) -> String {
        var result = s
        // Remove CSI escape sequences: ESC [ ... final byte in @-~
        if let re = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", options: []) {
            result = re.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        // Remove OSC sequences ending with BEL: ESC ] ... BEL
        if let re2 = try? NSRegularExpression(pattern: "\u{001B}\\][^\u{0007}]*\u{0007}", options: []) {
            result = re2.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        return result
    }

    private static func terminalPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "echo -n \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
}
