import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexRPC")

// MARK: - Codex CLI RPC Probe
//
// Spawns `codex app-server --listen stdio://` and communicates via JSON-RPC
// on stdin/stdout to call `account/rateLimits/read`. No tmux, no PTY, no
// token cost — the app-server reads credentials from ~/.codex/auth.json and
// calls the API internally.
//
// Protocol: JSON-RPC 2.0 (same as the Codex VS Code extension).
// Handshake: send `initialize`, then `account/rateLimits/read`.

actor CodexCLIRPCProbe {
    private static let defaultSuccessCooldown: TimeInterval = 60

    private var permanentlyUnavailable = false
    private var lastProbeAt: Date? = nil
    private var lastProbeFailed = false

    private final class ResponseReadState {
        private let lock = NSLock()
        private var accumulated = Data()
        private var resolved = false

        func resolveIfNeeded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else { return false }
            resolved = true
            return true
        }

        func appendAndSnapshot(_ data: Data) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else { return nil }
            accumulated.append(data)
            return accumulated
        }
    }

    /// Returns a snapshot on success, nil on failure (caller falls through).
    func fetchRateLimits(cooldownSuccess: TimeInterval = CodexCLIRPCProbe.defaultSuccessCooldown,
                         cooldownFailure: TimeInterval = 60 * 60) async -> CodexUsageSnapshot? {
        guard !permanentlyUnavailable else { return nil }

        let now = Date()
        if let last = lastProbeAt {
            let cd = lastProbeFailed ? cooldownFailure : cooldownSuccess
            if now.timeIntervalSince(last) < cd { return nil }
        }

        lastProbeAt = now

        guard let codexBin = CodexCLIEnvironment().resolveBinary(customPath: nil) else {
            os_log("CodexRPC: codex binary not found", log: log, type: .info)
            lastProbeFailed = true
            return nil
        }

        do {
            let response = try await runRPC(binary: codexBin)
            lastProbeFailed = false
            return response
        } catch RPCError.unsupported {
            os_log("CodexRPC: app-server RPC not supported, disabling permanently", log: log, type: .info)
            permanentlyUnavailable = true
            return nil
        } catch {
            os_log("CodexRPC: probe failed: %{public}@", log: log, type: .error,
                   error.localizedDescription)
            lastProbeFailed = true
            return nil
        }
    }

#if DEBUG
    nonisolated static var defaultSuccessCooldownForTesting: TimeInterval {
        defaultSuccessCooldown
    }
#endif

    // MARK: - Private

    private enum RPCError: Error {
        case unsupported       // CLI doesn't support app-server
        case timeout
        case invalidResponse
        case processError(String)
    }

    private nonisolated static var appServerArguments: [String] {
        ["app-server", "--listen", "stdio://"]
    }

    private func runRPC(binary: URL) async throws -> CodexUsageSnapshot? {
        let process = Process()
        process.executableURL = binary
        process.arguments = Self.appServerArguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Scrub OAuth tokens from env to avoid interfering with the app-server's
        // own credential loading.
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.contains("OPENAI") || key.contains("CODEX_TOKEN") {
            env.removeValue(forKey: key)
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            throw RPCError.unsupported
        }

        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }

        // 1. Send initialize
        let initReq = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"AgentSessions\",\"version\":\"1.0\"}}}\n"
        stdinPipe.fileHandleForWriting.write(Data(initReq.utf8))

        // 2. Wait for initialize response
        _ = try await readResponse(from: stdoutPipe, timeout: 8)

        // 3. Send account/rateLimits/read
        let rateLimitReq = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\"}\n"
        stdinPipe.fileHandleForWriting.write(Data(rateLimitReq.utf8))

        // 4. Read rate limits response
        let responseData = try await readResponse(from: stdoutPipe, timeout: 10)

        // 5. Close stdin to signal we're done
        stdinPipe.fileHandleForWriting.closeFile()

        return Self.parseRateLimitsResponseData(responseData)
    }

    /// Read a single JSON-RPC response using async readability handler.
    /// Avoids blocking the actor executor with synchronous `availableData`.
    private func readResponse(from pipe: Pipe, timeout: TimeInterval) async throws -> Data {
        let handle = pipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            let state = ResponseReadState()

            // Set up a timeout watchdog
            let timeoutItem = DispatchWorkItem { [weak handle] in
                guard state.resolveIfNeeded() else { return }
                handle?.readabilityHandler = nil
                continuation.resume(throwing: RPCError.timeout)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData

                if data.isEmpty {
                    // EOF — no response received
                    guard state.resolveIfNeeded() else { return }
                    timeoutItem.cancel()
                    fileHandle.readabilityHandler = nil
                    continuation.resume(throwing: RPCError.timeout)
                    return
                }

                guard let snapshot = state.appendAndSnapshot(data) else { return }
                // Check for a complete JSON-RPC response (line with "id" field)
                if let lines = String(data: snapshot, encoding: .utf8) {
                    for line in lines.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty,
                              let lineData = trimmed.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              json["id"] != nil else { continue }
                        guard state.resolveIfNeeded() else { return }
                        timeoutItem.cancel()
                        fileHandle.readabilityHandler = nil
                        continuation.resume(returning: lineData)
                        return
                    }
                }
            }
        }
    }

    /// Extracts `usedPercent` (Int or Double) from a raw window dict and
    /// converts it to the classifier's `remainingPercent` convention. Not
    /// clamped here — the classifier treats out-of-range values as suspect;
    /// clamping happens only once a routed result is stored on the snapshot.
    private nonisolated static func extractRemainingPercent(_ window: [String: Any]) -> Double? {
        if let usedPercent = window["usedPercent"] as? Int {
            return 100 - Double(usedPercent)
        }
        if let usedPercent = window["usedPercent"] as? Double {
            return 100 - usedPercent
        }
        return nil
    }

    /// Extracts `resetsAt` (Int epoch seconds) from a raw window dict.
    private nonisolated static func extractResetAt(_ window: [String: Any]) -> Date? {
        guard let resetsAt = window["resetsAt"] as? Int else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }

    /// Extracts a declared window length in minutes. The app-server's field
    /// name for this is unconfirmed, so this tries several plausible
    /// candidates before giving up; when every window returns nil the router
    /// falls back to the legacy positional mapping (primary=5h, secondary=weekly).
    private nonisolated static func extractWindowMinutes(_ window: [String: Any]) -> Int? {
        for key in ["windowMinutes", "windowSizeMinutes", "windowMinutesTotal"] {
            if let minutes = window[key] as? Int { return minutes }
            if let minutes = window[key] as? Double { return Int(minutes.rounded()) }
        }
        for key in ["windowSizeSeconds", "windowSeconds"] {
            if let seconds = window[key] as? Int { return seconds / 60 }
            if let seconds = window[key] as? Double { return Int((seconds / 60).rounded()) }
        }
        return nil
    }

    /// Builds a classifier input from a raw `primary`/`secondary` window dict.
    /// Returns nil when the dict itself is absent, or present but carries none
    /// of the three signals the classifier can use — an absent window is
    /// never suspect, only an unclassifiable-but-present one is.
    private nonisolated static func makeWindowInput(_ window: [String: Any]?) -> CodexRateLimitWindowInput? {
        guard let window else { return nil }
        let remainingPercent = extractRemainingPercent(window)
        let resetAt = extractResetAt(window)
        let windowMinutes = extractWindowMinutes(window)
        guard remainingPercent != nil || resetAt != nil || windowMinutes != nil else { return nil }
        return CodexRateLimitWindowInput(remainingPercent: remainingPercent, resetAt: resetAt, windowMinutes: windowMinutes)
    }

    private nonisolated static func parseRateLimitsResponseData(_ data: Data) -> CodexUsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return nil }

        // result.rateLimits matches the GetAccountRateLimitsResponse schema
        let rateLimits = (result["rateLimits"] as? [String: Any]) ?? result

        // Route by window length, not slot position — see
        // CodexRateLimitWindowClassifier for why `primary`/`secondary` can no
        // longer be trusted to mean "5h"/"weekly" (OpenAI can drop the 5h
        // window entirely, which moves the weekly window into `primary`).
        let primaryInput = makeWindowInput(rateLimits["primary"] as? [String: Any])
        let secondaryInput = makeWindowInput(rateLimits["secondary"] as? [String: Any])
        let routing = CodexRateLimitWindowClassifier.route(primaryInput, secondaryInput)

        var snap = CodexUsageSnapshot()
        var hasData = false

        if let fiveHour = routing.fiveHour {
            hasData = true
            if let rp = fiveHour.remainingPercent {
                snap.fiveHourRemainingPercent = max(0, min(100, Int(rp.rounded())))
            }
            snap.hasFiveHourRateLimit = true
            if let resetAt = fiveHour.resetAt {
                snap.fiveHourResetText = formatResetISO8601(resetAt)
            }
        }

        if let weekly = routing.weekly {
            hasData = true
            if let rp = weekly.remainingPercent {
                snap.weekRemainingPercent = max(0, min(100, Int(rp.rounded())))
            }
            snap.hasWeekRateLimit = true
            if let resetAt = weekly.resetAt {
                snap.weekResetText = formatResetISO8601(resetAt)
            }
        }

        snap.usageFormatSuspect = routing.suspect

        // A response with NOTHING placeable is treated as "no data" — fall through
        // so the app shows its calm reconnecting state, never an alarming
        // "can't verify". This is the common case for the CLI-RPC probe during the
        // connect window (a lone window with no readable length). A partial-suspect
        // response still surfaces via hasData.
        guard hasData else { return nil }

        snap.limitsSource = .cliRPC
        snap.eventTimestamp = Date()
        return snap
    }

#if DEBUG
    nonisolated static func parseRateLimitsResponseForTesting(_ data: Data) -> CodexUsageSnapshot? {
        parseRateLimitsResponseData(data)
    }

    nonisolated static var appServerArgumentsForTesting: [String] {
        appServerArguments
    }
#endif
}
