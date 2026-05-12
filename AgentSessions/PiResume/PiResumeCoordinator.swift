import Foundation

@MainActor
final class PiResumeCoordinator {
    private let env: PiCLIEnvironmentProviding
    private let builder: PiResumeCommandBuilder
    private let launcher: PiTerminalLaunching

    init(env: PiCLIEnvironmentProviding,
         builder: PiResumeCommandBuilder,
         launcher: PiTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: PiResumeInput,
                          policy: PiFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> PiResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Pi CLI not found."
            return PiResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canSession = info.supportsSession && hasID
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        let strategy: PiResumeCommandBuilder.Strategy
        let used: PiStrategyUsed

        if canSession {
            strategy = .sessionByID(id: input.sessionID!)
            used = .sessionByID
        } else if canResume {
            strategy = .resumeByID(id: input.sessionID!)
            used = .resumeByID
        } else if policy == .resumeThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            let reason: String
            if !hasID && policy == .resumeOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsSession && !info.supportsResume && policy == .resumeOnly {
                reason = "Installed Pi CLI does not support --session or --resume."
            } else {
                reason = "Pi CLI does not advertise required flags (--session/--resume/--continue)."
            }
            return PiResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let package: PiResumeCommandBuilder.CommandPackage
        do {
            package = try builder.makeCommand(strategy: strategy,
                                              binaryURL: info.binaryURL,
                                              workingDirectory: input.workingDirectory,
                                              sessionDirectory: input.sessionDirectory)
        } catch {
            return PiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return PiResumeResult(launched: false, strategy: used, error: nil, command: package.shellCommand)
        }

        do {
            try launcher.launchInTerminal(package)
            return PiResumeResult(launched: true, strategy: used, error: nil, command: package.shellCommand)
        } catch {
            if policy == .resumeThenContinue, (used == .sessionByID || used == .resumeByID), info.supportsContinue {
                do {
                    let fallback = try builder.makeCommand(strategy: .continueMostRecent,
                                                           binaryURL: info.binaryURL,
                                                           workingDirectory: input.workingDirectory,
                                                           sessionDirectory: input.sessionDirectory)
                    try launcher.launchInTerminal(fallback)
                    return PiResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: fallback.shellCommand)
                } catch {
                    return PiResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return PiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == PiCLIEnvironment.ProbeResult, Failure == PiCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
