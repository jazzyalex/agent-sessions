import Foundation

protocol ClaudeTerminalLaunching {
    func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws
}

@MainActor
final class ClaudeResumeCoordinator {
    private let env: ClaudeCLIEnvironment
    private let builder: ClaudeResumeCommandBuilder
    private let launcher: ClaudeTerminalLaunching

    struct NoopLauncher: ClaudeTerminalLaunching { func launchInTerminal(_ package: ClaudeResumeCommandBuilder.CommandPackage) throws {} }

    init(env: ClaudeCLIEnvironment = ClaudeCLIEnvironment(),
         builder: ClaudeResumeCommandBuilder = ClaudeResumeCommandBuilder(),
         launcher: ClaudeTerminalLaunching = NoopLauncher()) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    /// Resume a Claude session in Terminal, with a fallback policy.
    /// - Parameters:
    ///   - input: sessionID (optional), workingDirectory (optional), binary override (optional)
    ///   - policy: whether to try continue() on failure/unavailability
    ///   - dryRun: if true, do not launch Terminal; return the command that would run
    func resumeInTerminal(input: ClaudeResumeInput,
                          policy: ClaudeFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> ClaudeResumeResult {
        // Probe CLI
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = (try? probe.get()) == nil ? (probe.failureValue?.localizedDescription ?? "Claude CLI not found.") : "Claude CLI not found."
            return ClaudeResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        // Choose initial strategy
        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        var strategy: ClaudeResumeCommandBuilder.Strategy?
        var used: ClaudeStrategyUsed = .none

        if canResume {
            strategy = .resumeByID(id: input.sessionID!)
            used = .resumeByID
        } else if policy == .resumeThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            // No viable strategy
            let reason: String
            if !hasID && policy == .resumeOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsResume && policy == .resumeOnly {
                reason = "Installed Claude CLI does not support --resume."
            } else {
                reason = "Claude CLI does not advertise required flags (--resume/--continue)."
            }
            return ClaudeResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        guard let strategy else {
            return ClaudeResumeResult(launched: false, strategy: .none, error: "No strategy selected.", command: nil)
        }

        // Build command
        let pkg: ClaudeResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return ClaudeResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return ClaudeResumeResult(launched: false, strategy: used, error: nil, command: pkg.shellCommand)
        }

        // Launch Terminal
        do {
            try launcher.launchInTerminal(pkg)
            return ClaudeResumeResult(launched: true, strategy: used, error: nil, command: pkg.shellCommand)
        } catch {
            // Fallback if allowed and not already continue
            if policy == .resumeThenContinue, used == .resumeByID, info.supportsContinue {
                do {
                    let pkg2 = try builder.makeCommand(strategy: .continueMostRecent, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(pkg2)
                    return ClaudeResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: pkg2.shellCommand)
                } catch {
                    return ClaudeResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return ClaudeResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == ClaudeCLIEnvironment.ProbeResult, Failure == ClaudeCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
