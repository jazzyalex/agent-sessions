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
    func fetchRateLimits(cooldownSuccess: TimeInterval = 10 * 60,
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

    // MARK: - Private

    private enum RPCError: Error {
        case unsupported       // CLI doesn't support app-server
        case timeout
        case invalidResponse
        case processError(String)
    }

    private func runRPC(binary: URL) async throws -> CodexUsageSnapshot? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://", "--session-source", "vscode"]

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

    private nonisolated static func parseRateLimitsResponseData(_ data: Data) -> CodexUsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return nil }

        // result.rateLimits matches the GetAccountRateLimitsResponse schema
        let rateLimits = (result["rateLimits"] as? [String: Any]) ?? result

        var snap = CodexUsageSnapshot()
        var hasData = false

        if let primary = rateLimits["primary"] as? [String: Any] {
            if let usedPercent = primary["usedPercent"] as? Int {
                snap.fiveHourRemainingPercent = max(0, min(100, 100 - usedPercent))
                snap.hasFiveHourRateLimit = true
                hasData = true
            } else if let usedPercent = primary["usedPercent"] as? Double {
                snap.fiveHourRemainingPercent = max(0, min(100, 100 - Int(usedPercent.rounded())))
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
            if let resetsAt = primary["resetsAt"] as? Int {
                let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
                snap.fiveHourResetText = formatResetISO8601(date)
                snap.hasFiveHourRateLimit = true
                hasData = true
            }
        }

        if let secondary = rateLimits["secondary"] as? [String: Any] {
            if let usedPercent = secondary["usedPercent"] as? Int {
                snap.weekRemainingPercent = max(0, min(100, 100 - usedPercent))
                snap.hasWeekRateLimit = true
                hasData = true
            } else if let usedPercent = secondary["usedPercent"] as? Double {
                snap.weekRemainingPercent = max(0, min(100, 100 - Int(usedPercent.rounded())))
                snap.hasWeekRateLimit = true
                hasData = true
            }
            if let resetsAt = secondary["resetsAt"] as? Int {
                let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
                snap.weekResetText = formatResetISO8601(date)
                snap.hasWeekRateLimit = true
                hasData = true
            }
        }

        guard hasData else { return nil }

        snap.limitsSource = .cliRPC
        snap.eventTimestamp = Date()
        return snap
    }

#if DEBUG
    nonisolated static func parseRateLimitsResponseForTesting(_ data: Data) -> CodexUsageSnapshot? {
        parseRateLimitsResponseData(data)
    }
#endif
}
