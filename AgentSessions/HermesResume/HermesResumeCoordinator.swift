import Foundation

@MainActor
final class HermesResumeCoordinator {
    private let env: HermesCLIEnvironment
    private let builder: HermesResumeCommandBuilder
    private let launcher: HermesTerminalLaunching

    init(env: HermesCLIEnvironment,
         builder: HermesResumeCommandBuilder,
         launcher: HermesTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: HermesResumeInput,
                          policy: HermesFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> HermesResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case .success(let info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Hermes CLI not found."
            return HermesResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        let strategy: HermesResumeCommandBuilder.Strategy
        let used: HermesStrategyUsed
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
                reason = "Installed Hermes CLI does not support --resume."
            } else {
                reason = "Hermes CLI does not advertise required flags (--resume/--continue)."
            }
            return HermesResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let pkg: HermesResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return HermesResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return HermesResumeResult(launched: false, strategy: used, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return HermesResumeResult(launched: true, strategy: used, error: nil, command: pkg.shellCommand)
        } catch {
            if policy == .resumeThenContinue, used == .resumeByID, info.supportsContinue {
                do {
                    let pkg2 = try builder.makeCommand(strategy: .continueMostRecent, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(pkg2)
                    return HermesResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: pkg2.shellCommand)
                } catch {
                    return HermesResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return HermesResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == HermesCLIEnvironment.ProbeResult, Failure == HermesCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(error) = self { return error }; return nil }
}
