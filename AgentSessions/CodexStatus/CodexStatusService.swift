import Foundation
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

// ILLUSTRATIVE: Minimal model + service for Codex /status usage parsing.

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
        Task.detached { [weak self] in
            await self?.service?.refreshNow()
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
    }

    private func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }
}

// MARK: - Rate-limit models (log probe)

struct RateLimitWindow {
    var usedPercent: Int?
    var resetAt: Date?
    var windowMinutes: Int?
}

struct RateLimitSummary {
    var fiveHour: RateLimitWindow
    var weekly: RateLimitWindow
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
        visible = isVisible
    }

    func refreshNow() {
        Task { await self.refreshTick() }
    }

    // MARK: - Core

    private func ensureProcessPrimed() async {
        if process?.isRunning == true { return }
        await launchREPL(preferredModel: "gpt-5-nano")
        if process?.isRunning != true {
            await launchREPL(preferredModel: "gpt-5-mini")
        }
        if process?.isRunning == true {
            backoffSeconds = 1
            availabilityHandler(false)
            await send("ping\n/status\n")
        } else {
            availabilityHandler(true)
        }
    }

    private func launchREPL(preferredModel: String) async {
        if state == .starting || state == .running { return }
        state = .starting

        // Build a bash -lc command to use user's login shell PATH
        let command = "codex -m \(preferredModel)"
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

    private func refreshTick() async {
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
    }

    private func nextInterval() -> UInt64 {
        // Policy:
        // - On AC power: 60s when any indicator visible (strip OR menubar), else 300s.
        // - On battery: always 300s (keep it simple; no urgency override).
        // - Urgency still pins to 60s on AC power only.
        if !Self.onACPower() {
            return 300 * 1_000_000_000
        }
        var seconds: UInt64 = visible ? 60 : 300
        if isUrgent() { seconds = 60 }
        return seconds * 1_000_000_000
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
            fiveHour: RateLimitWindow(usedPercent: nil, resetAt: nil, windowMinutes: nil),
            weekly: RateLimitWindow(usedPercent: nil, resetAt: nil, windowMinutes: nil),
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
                    for u in items where u.lastPathComponent.hasPrefix("rollout-") && u.pathExtension.lowercased() == "jsonl" {
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (obj["type"] as? String) == "event_msg" else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            guard (payload["type"] as? String) == "token_count" else { continue }

            var createdAt: Date? = nil
            if let s = obj["created_at"] as? String { createdAt = iso.date(from: s) }
            if createdAt == nil, let s = payload["created_at"] as? String { createdAt = iso.date(from: s) }

            guard let created = createdAt else {
                // Skip events without timestamps - cannot determine staleness accurately
                continue
            }

            // Additional safety: reject future timestamps (clock skew protection)
            guard created <= Date() else { continue }

            guard let rate = payload["rate_limits"] as? [String: Any] else { continue }
            let primary = rate["primary"] as? [String: Any]
            let secondary = rate["secondary"] as? [String: Any]

            let five = decodeWindow(primary, created: created)
            let week = decodeWindow(secondary, created: created)
            let stale = Date().timeIntervalSince(created) > 3 * 60
            return RateLimitSummary(fiveHour: five, weekly: week, eventTimestamp: created, stale: stale, sourceFile: url)
        }
        return nil
    }

    private func decodeWindow(_ dict: [String: Any]?, created: Date) -> RateLimitWindow {
        guard let dict else { return RateLimitWindow(usedPercent: nil, resetAt: nil, windowMinutes: nil) }
        let used = (dict["used_percent"] as? Double).map { Int(($0).rounded()) }
        let resets = (dict["resets_in_seconds"] as? Double) ?? (dict["resets_in_seconds"] as? NSNumber)?.doubleValue
        let minutes = dict["window_minutes"] as? Int
        let resetAt = resets.map { created.addingTimeInterval($0) }
        return RateLimitWindow(usedPercent: used, resetAt: resetAt, windowMinutes: minutes)
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
