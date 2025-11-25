import Foundation
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Codex Usage Tracking Architecture Documentation
//
// This service implements a three-tier system for tracking Codex API rate limit usage:
//
// ## Data Sources (Priority Order)
//
// 1. **PRIMARY: JSONL Log Parsing** (Passive, Free)
//    - Scans ~/.codex/sessions/YYYY/MM/DD/*.jsonl files for rate_limit events
//    - Extracts 5-hour and weekly limit percentages from log events
//    - Zero token cost (reads existing logs, no API calls)
//    - Frequency: Every 5 minutes (reduced on battery)
//    - Limitation: Only reflects usage from recent local Codex sessions
//
// 2. **SECONDARY: Auto /status Probe** (Active, 1-2 messages)
//    - Triggers when: no recent sessions OR data looks stale AND visible AND user opted-in
//    - Uses tmux to run `codex` CLI and send `/status` command
//    - Token cost: 1-2 messages
//    - Gated by: `CodexAllowStatusProbe` preference + 10min cooldown
//    - Purpose: Fetch current usage when user hasn't used Codex recently
//
// 3. **TERTIARY: Hard Probe (Manual)** (Active, 1-2 messages)
//    - User-triggered via Preferences → Usage Probes → "Run hard Codex /status probe now"
//    - Always available regardless of staleness or auto-probe settings
//    - Returns full diagnostics (success/failure, script output, etc.)
//    - Sets 1-hour "freshness" TTL to prevent immediate re-staleness
//
// ## Current Data Model (Being Refactored)
//
// NOTE: This code currently stores usage as "percent used" (0-100%) but is being migrated
// to "percent remaining" to match new server-side semantics (Nov 24, 2025 OpenAI changes).
//
// - CodexUsageSnapshot.fiveHourRemainingPercent: Stores "% remaining"
// - CodexUsageSnapshot.weekRemainingPercent: Stores "% remaining"
// - UI displays use helper methods to convert between used/remaining as needed
//
// ## Staleness Semantics
//
// "Stale" means "data is old" NOT "data is inaccurate" (server data is fresh since Nov 2025).
//
// Staleness thresholds:
// - 5-hour window: 30 minutes since last event
// - Weekly window: 4 hours since last event
//
// Staleness triggers:
// - UI display: Shows "Last updated Xh ago" instead of reset time
// - Auto-probe: May trigger if no recent sessions + visible + opted-in
// - Freshness TTL: Manual probes set 1-hour "fresh" window to smooth UI
//
// ## Key Files
//
// - CodexStatusService.swift (this file): Main service, JSONL parsing, probe orchestration
// - Resources/codex_status_capture.sh: Bash script for tmux-based /status probing
// - CodexProbeConfig.swift: Probe session identification logic
// - CodexProbeProject.swift: Probe session cleanup/deletion logic
// - UsageStaleCheck.swift: Staleness detection logic (thresholds, event age)
// - UsageFreshness.swift: Freshness TTL management (1-hour grace period)
//
// ILLUSTRATIVE: Minimal model + service for Codex usage parsing with optional CLI /status probe.

// Snapshot of parsed values from Codex /status or banner
struct CodexUsageSnapshot: Equatable {
    var fiveHourRemainingPercent: Int = 0
    var fiveHourResetText: String = ""
    var weekRemainingPercent: Int = 0
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

    // MARK: - Helper Methods for UI Display
    // Server now reports "remaining" but UI may want to show "used" (e.g., progress bars)

    func fiveHourPercentUsed() -> Int {
        return 100 - fiveHourRemainingPercent
    }

    func weekPercentUsed() -> Int {
        return 100 - weekRemainingPercent
    }
}

struct CodexProbeDiagnostics {
    let success: Bool
    let exitCode: Int32
    let scriptPath: String
    let workdir: String
    let codexBin: String?
    let tmuxBin: String?
    let timeoutSecs: String?
    let stdout: String
    let stderr: String
}

@MainActor
final class CodexUsageModel: ObservableObject {
    static let shared = CodexUsageModel()

    @Published var fiveHourRemainingPercent: Int = 0
    @Published var fiveHourResetText: String = ""
    @Published var weekRemainingPercent: Int = 0
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
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil

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
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                await svc.refreshNow()
                // Fallback timeout guard
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
                    if self.isUpdating { self.isUpdating = false }
                }
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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
                if self.isUpdating { self.isUpdating = false }
            }
        }
    }

    // Hard-probe from Preferences pane: forces a /status tmux probe, shows result via callback
    func hardProbeNow(completion: @escaping (Bool) -> Void) {
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                let diag = await svc.forceProbeNow()
                await MainActor.run {
                    if diag.success {
                        self.lastSuccessAt = Date()
                        setFreshUntil(for: .codex, until: Date().addingTimeInterval(60 * 60))
                    }
                    self.isUpdating = false
                    completion(diag.success)
                }
                return
            }
            // Create a short-lived service for the probe
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if diag.success {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .codex, until: Date().addingTimeInterval(60 * 60))
                }
                self.isUpdating = false
                completion(diag.success)
            }
        }
    }

    // Hard-probe variant that returns full diagnostics for UI display
    func hardProbeNowDiagnostics(completion: @escaping (CodexProbeDiagnostics) -> Void) {
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                let diag = await svc.forceProbeNow()
                await MainActor.run { completion(diag) }
                return
            }
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if diag.success {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .codex, until: Date().addingTimeInterval(60 * 60))
                }
                self.isUpdating = false
                completion(diag)
            }
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
        fiveHourRemainingPercent = clampPercent(s.fiveHourRemainingPercent)
        weekRemainingPercent = clampPercent(s.weekRemainingPercent)
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
        // Any snapshot means we received data; clear updating if set
        if isUpdating { isUpdating = false }
    }

    private func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }
}

// MARK: - Rate-limit models (log probe)

struct RateLimitWindowInfo {
    var remainingPercent: Int?
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
        // Manual refresh from strip/menu uses the same stale-only probe rule.
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
            s.fiveHourRemainingPercent = extractPercent(from: clean) ?? s.fiveHourRemainingPercent
            s.fiveHourResetText = extractResetText(from: clean) ?? s.fiveHourResetText
            snapshot = s
            updateHandler(snapshot)
            return
        }
        let isWeekly = (lower.contains("weekly") && lower.contains("limit")) || lower.contains("week limit")
        if isWeekly {
            var s = snapshot
            s.weekRemainingPercent = extractPercent(from: clean) ?? s.weekRemainingPercent
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
        // Log-probe path: scan latest JSONL for token_count/rate_limits across known roots
        let roots = sessionsRoots()
        guard !roots.isEmpty else { availabilityHandler(true); return }
        availabilityHandler(false)

        if let summary = probeLatestRateLimits(roots: roots) {
            var s = snapshot
            if let p = summary.fiveHour.remainingPercent { s.fiveHourRemainingPercent = clampPercent(p) }
            if let p = summary.weekly.remainingPercent { s.weekRemainingPercent = clampPercent(p) }
            s.fiveHourResetText = formatCodexReset(summary.fiveHour.resetAt, windowMinutes: summary.fiveHour.windowMinutes)
            s.weekResetText = formatCodexReset(summary.weekly.resetAt, windowMinutes: summary.weekly.windowMinutes)
            lastFiveHourResetDate = summary.fiveHour.resetAt
            s.usageLine = summary.stale ? "Usage is stale (>3m)" : nil
            s.eventTimestamp = summary.eventTimestamp
#if DEBUG
            if let f = summary.sourceFile { print("[CodexUsage] Parsed rate_limits from: \(f.path)") }
#endif
            snapshot = s
            updateHandler(snapshot)
        }

        // Optional: run a one-shot tmux /status probe only when stale (manual or auto)
        if !FeatureFlags.disableCodexProbes {
            await maybeProbeStatusViaTMUX(userInitiated: userInitiated)
        }
    }

    // MARK: - Optional tmux /status probe
    private func maybeProbeStatusViaTMUX(userInitiated: Bool) async {
        // Probes are strictly secondary and must only run when usage looks stale.
        let now = Date()
        let stale5h = isResetInfoStale(kind: "5h", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
        let staleWeek = isResetInfoStale(kind: "week", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
        guard stale5h || staleWeek else { return }

        // Additional gates for automatic/background path only
        if !userInitiated {
            let allowAuto = UserDefaults.standard.bool(forKey: "CodexAllowStatusProbe")
            guard allowAuto else { return }
            guard visible else { return }
            if let last = lastStatusProbe, now.timeIntervalSince(last) < 600 { return }
        }

        guard let tmuxSnap = await runCodexStatusViaTMUX() else { return }
        lastStatusProbe = now
        var merged = snapshot
        if tmuxSnap.fiveHourRemainingPercent > 0 { merged.fiveHourRemainingPercent = clampPercent(tmuxSnap.fiveHourRemainingPercent) }
        if !tmuxSnap.fiveHourResetText.isEmpty { merged.fiveHourResetText = tmuxSnap.fiveHourResetText }
        if tmuxSnap.weekRemainingPercent > 0 { merged.weekRemainingPercent = clampPercent(tmuxSnap.weekRemainingPercent) }
        if !tmuxSnap.weekResetText.isEmpty { merged.weekResetText = tmuxSnap.weekResetText }
        merged.eventTimestamp = now
        snapshot = merged
        updateHandler(merged)
        _ = CodexProbeCleanup.cleanupNowIfAuto()
    }

    // Hard-probe entry point: forces a tmux /status probe regardless of staleness or prefs.
    // Returns diagnostics; merges snapshot on success.
    func forceProbeNow() async -> CodexProbeDiagnostics {
        guard !FeatureFlags.disableCodexProbes else {
            return CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(not run)", workdir: CodexProbeConfig.probeWorkingDirectory(), codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Probes disabled by feature flag")
        }
        let (snap, diag) = await runCodexStatusViaTMUXAndCollect()
        if let tmuxSnap = snap {
            var merged = snapshot
            if tmuxSnap.fiveHourRemainingPercent > 0 { merged.fiveHourRemainingPercent = clampPercent(tmuxSnap.fiveHourRemainingPercent) }
            if !tmuxSnap.fiveHourResetText.isEmpty { merged.fiveHourResetText = tmuxSnap.fiveHourResetText }
            if tmuxSnap.weekRemainingPercent > 0 { merged.weekRemainingPercent = clampPercent(tmuxSnap.weekRemainingPercent) }
            if !tmuxSnap.weekResetText.isEmpty { merged.weekResetText = tmuxSnap.weekResetText }
            merged.eventTimestamp = Date()
            snapshot = merged
            updateHandler(merged)
            _ = CodexProbeCleanup.cleanupNowIfAuto()
        }
        return diag
    }

    private func runCodexStatusViaTMUX() async -> CodexUsageSnapshot? {
        let (snap, _) = await runCodexStatusViaTMUXAndCollect()
        return snap
    }

    private func runCodexStatusViaTMUXAndCollect() async -> (CodexUsageSnapshot?, CodexProbeDiagnostics) {
        guard let scriptURL = Bundle.main.url(forResource: "codex_status_capture", withExtension: "sh") else {
            let d = CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(missing)", workdir: CodexProbeConfig.probeWorkingDirectory(), codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Script not found in bundle")
            return (nil, d)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        let workDir = CodexProbeConfig.probeWorkingDirectory()
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["TIMEOUT_SECS"] = env["TIMEOUT_SECS"] ?? "14"
        let resolver = CodexCLIEnvironment()
        let codexBin = resolver.resolveBinary(customPath: nil)?.path
        if let codexBin { env["CODEX_BIN"] = codexBin }
        let tmuxBin = resolveTmuxPath()
        if let tmuxBin { env["TMUX_BIN"] = tmuxBin }

        // Provide a Terminal-like PATH so Node and vendor binaries resolve inside tmux
        if let terminalPATH = Self.terminalPATH() { env["PATH"] = terminalPATH }
        process.environment = env
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch {
            let d = CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: "", stderr: error.localizedDescription)
            print("[CodexProbe] Failed to launch capture script: \(error.localizedDescription)")
            return (nil, d)
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[CodexProbe] Script non-zero (\(process.terminationStatus)). stdout: \n\(stdout)")
            }
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[CodexProbe] Script stderr: \n\(stderr)")
            }
            let d = CodexProbeDiagnostics(success: false, exitCode: process.terminationStatus, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
            return (nil, d)
        }
        let snap = parseStatusJSON(stdout)
        let d = CodexProbeDiagnostics(success: snap != nil, exitCode: 0, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
        return (snap, d)
    }

    private func parseStatusJSON(_ json: String) -> CodexUsageSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ok = obj["ok"] as? Bool, !ok { return nil }
        var s = CodexUsageSnapshot()
        if let fh = obj["five_hour"] as? [String: Any] {
            if let p = fh["pct_used"] as? Int { s.fiveHourRemainingPercent = p }
            if let r = fh["resets"] as? String { s.fiveHourResetText = r }
        }
        if let wk = obj["weekly"] as? [String: Any] {
            if let p = wk["pct_used"] as? Int { s.weekRemainingPercent = p }
            if let r = wk["resets"] as? String { s.weekResetText = r }
        }
        s.eventTimestamp = Date()
        return s
    }

    private func nextInterval() -> UInt64 {
        // Read Codex-specific polling interval (defaults to 300s = 5 min)
        let userInterval = UInt64(UserDefaults.standard.object(forKey: "CodexPollingInterval") as? Int ?? 300)

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
        // Urgent if 5-hour limit is running low (≤20% remaining = ≥80% used)
        if snapshot.fiveHourPercentUsed() >= 80 { return true }
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

    private func sessionsRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ path: String) {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(url)
            }
        }
        if let override = UserDefaults.standard.string(forKey: "SessionsRootOverride"), !override.isEmpty {
            add(override)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            add((env as NSString).appendingPathComponent("sessions"))
        }
        add((NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions"))
        // Dedup by path
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0.path).inserted }
        return roots
    }

    private func probeLatestRateLimits(roots: [URL]) -> RateLimitSummary? {
        var files: [URL] = []
        for r in roots { files.append(contentsOf: findCandidateFiles(root: r, daysBack: 10, limit: 80)) }
        // Global sort by mtime desc across roots
        files.sort { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        for url in files {
            if let summary = parseTokenCountTail(url: url) { return summary }
        }
        return RateLimitSummary(
            fiveHour: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
            weekly: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
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
        // Walk most-recent → older. Be permissive about shape; Codex logs can vary.
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Prefer nested payload, but fall back to top-level when payload is absent.
            let payload = (obj["payload"] as? [String: Any]) ?? obj

            // Establish a createdAt for this event (best-effort)
            let createdAt = decodeFlexibleDate(obj["created_at"]) ??
                            decodeFlexibleDate(payload["created_at"]) ??
                            decodeFlexibleDate(obj["timestamp"]) ??
                            decodeFlexibleDate(payload["timestamp"]) ??
                            Date()

            // Surface usage tokens if present (new or legacy forms)
            extractUsageIfPresent(from: payload, createdAt: createdAt)

            // Rate limits may appear at payload.rate_limits or (legacy) at top-level
            if let rate = (payload["rate_limits"] as? [String: Any]) ?? (obj["rate_limits"] as? [String: Any]) {
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

            // Legacy: token_count style where rate_limits nested under payload.info
            if let kind = payload["type"] as? String, kind.lowercased() == "token_count" {
                if let info = payload["info"] as? [String: Any], let rate = info["rate_limits"] as? [String: Any] {
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
        }
        return nil
    }

    // MARK: - Usage extraction (new + legacy)

    private func extractUsageIfPresent(from payload: [String: Any], createdAt: Date) {
        // New model: turn.completed with usage {...}
        if let kind = (payload["type"] as? String)?.lowercased(), kind == "turn.completed" || kind == "turn_completed" || kind == "turn-completed" {
            if let usage = payload["usage"] as? [String: Any] ?? (payload["data"] as? [String: Any])?["usage"] as? [String: Any] {
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
        if let kind = (payload["type"] as? String)?.lowercased(), kind == "token_count" {
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
        guard let dict else { return RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil) }

        // Parse remaining percentage (post Nov 24, 2025 server-side change)
        var remaining: Int?
        if let d = dict["remaining_percent"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["remaining_percent"] as? Int { remaining = max(0, min(100, i)) }
        else if let n = dict["remaining_percent"] as? NSNumber { remaining = Int(truncating: n) }
        // Alternate naming: pct_left, pct_remaining
        else if let d = dict["pct_left"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["pct_left"] as? Int { remaining = max(0, min(100, i)) }
        else if let d = dict["pct_remaining"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["pct_remaining"] as? Int { remaining = max(0, min(100, i)) }

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

        return RateLimitWindowInfo(remainingPercent: remaining, resetAt: resetAt, windowMinutes: minutes)
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

    // Resolve tmux path via the user's login shell so GUI-launched app can find Homebrew installs.
    private func resolveTmuxPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "command -v tmux || true"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
