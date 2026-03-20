import Foundation

@MainActor
final class OpenCodeResumeCoordinator {
    private let env: OpenCodeCLIEnvironment
    private let builder: OpenCodeResumeCommandBuilder
    private let launcher: OpenCodeTerminalLaunching

    init(env: OpenCodeCLIEnvironment,
         builder: OpenCodeResumeCommandBuilder,
         launcher: OpenCodeTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: OpenCodeResumeInput,
                          policy: OpenCodeFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> OpenCodeResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = (try? probe.get()) == nil ? (probe.failureValue?.localizedDescription ?? "OpenCode CLI not found.") : "OpenCode CLI not found."
            return OpenCodeResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        let strategy: OpenCodeResumeCommandBuilder.Strategy
        let used: OpenCodeStrategyUsed

        if canResume {
            strategy = .resumeByID(id: input.sessionID!)
            used = .resumeByID
        } else if policy == .resumeThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            let reason: String
            if !hasID && policy == .resumeOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsResume && policy == .resumeOnly {
                reason = "Installed OpenCode CLI does not support --session."
            } else {
                reason = "OpenCode CLI does not advertise required flags (--session/--continue)."
            }
            return OpenCodeResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let pkg: OpenCodeResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return OpenCodeResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return OpenCodeResumeResult(launched: false, strategy: used, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return OpenCodeResumeResult(launched: true, strategy: used, error: nil, command: pkg.shellCommand)
        } catch {
            if policy == .resumeThenContinue, used == .resumeByID, info.supportsContinue {
                do {
                    let pkg2 = try builder.makeCommand(strategy: .continueMostRecent, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(pkg2)
                    return OpenCodeResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: pkg2.shellCommand)
                } catch {
                    return OpenCodeResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return OpenCodeResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == OpenCodeCLIEnvironment.ProbeResult, Failure == OpenCodeCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
