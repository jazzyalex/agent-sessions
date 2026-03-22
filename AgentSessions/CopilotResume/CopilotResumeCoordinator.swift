import Foundation

@MainActor
final class CopilotResumeCoordinator {
    private let env: CopilotCLIEnvironment
    private let builder: CopilotResumeCommandBuilder
    private let launcher: CopilotTerminalLaunching

    init(env: CopilotCLIEnvironment,
         builder: CopilotResumeCommandBuilder,
         launcher: CopilotTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: CopilotResumeInput,
                          policy: CopilotFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> CopilotResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Copilot CLI not found."
            return CopilotResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        let strategy: CopilotResumeCommandBuilder.Strategy
        let used: CopilotStrategyUsed

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
                reason = "Installed Copilot CLI does not support --resume."
            } else {
                reason = "Copilot CLI does not advertise required flags (--resume/--continue)."
            }
            return CopilotResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let pkg: CopilotResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return CopilotResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return CopilotResumeResult(launched: false, strategy: used, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return CopilotResumeResult(launched: true, strategy: used, error: nil, command: pkg.shellCommand)
        } catch {
            if policy == .resumeThenContinue, used == .resumeByID, info.supportsContinue {
                do {
                    let pkg2 = try builder.makeCommand(strategy: .continueMostRecent, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(pkg2)
                    return CopilotResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: pkg2.shellCommand)
                } catch {
                    return CopilotResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return CopilotResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == CopilotCLIEnvironment.ProbeResult, Failure == CopilotCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
