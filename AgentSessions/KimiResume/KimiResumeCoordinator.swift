import Foundation

@MainActor
final class KimiResumeCoordinator {
    private let env: KimiCLIEnvironmentProviding
    private let builder: KimiResumeCommandBuilder
    private let launcher: KimiTerminalLaunching

    init(env: KimiCLIEnvironmentProviding,
         builder: KimiResumeCommandBuilder,
         launcher: KimiTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: KimiResumeInput,
                          policy: KimiFallbackPolicy = .sessionThenContinue,
                          dryRun: Bool = false) async -> KimiResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Kimi Code CLI not found."
            return KimiResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canSession = info.supportsSession && hasID
        let canContinue = info.supportsContinue

        let strategy: KimiResumeCommandBuilder.Strategy
        let used: KimiStrategyUsed

        if canSession {
            strategy = .sessionByID(id: input.sessionID!)
            used = .sessionByID
        } else if policy == .sessionThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            let reason: String
            if !hasID && policy == .sessionOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsSession && policy == .sessionOnly {
                reason = "Installed Kimi Code CLI does not support --session."
            } else {
                reason = "Kimi Code CLI does not advertise required flags (--session/--continue)."
            }
            return KimiResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let package: KimiResumeCommandBuilder.CommandPackage
        do {
            package = try builder.makeCommand(strategy: strategy,
                                              binaryURL: info.binaryURL,
                                              workingDirectory: input.workingDirectory)
        } catch {
            return KimiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return KimiResumeResult(launched: false, strategy: used, error: nil, command: package.shellCommand)
        }

        do {
            try launcher.launchInTerminal(package)
            return KimiResumeResult(launched: true, strategy: used, error: nil, command: package.shellCommand)
        } catch {
            if policy == .sessionThenContinue, used == .sessionByID, info.supportsContinue {
                do {
                    let fallback = try builder.makeCommand(strategy: .continueMostRecent,
                                                           binaryURL: info.binaryURL,
                                                           workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(fallback)
                    return KimiResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: fallback.shellCommand)
                } catch {
                    return KimiResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return KimiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == KimiCLIEnvironment.ProbeResult, Failure == KimiCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
