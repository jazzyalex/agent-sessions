import Foundation

@MainActor
final class CursorResumeCoordinator {
    private let env: CursorCLIEnvironmentProviding
    private let builder: CursorResumeCommandBuilder
    private let launcher: CursorTerminalLaunching

    init(env: CursorCLIEnvironmentProviding,
         builder: CursorResumeCommandBuilder,
         launcher: CursorTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: CursorResumeInput,
                          policy: CursorFallbackPolicy = .resumeThenContinue,
                          dryRun: Bool = false) async -> CursorResumeResult {
        let probe = env.probe(customPath: input.binaryOverride)
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Cursor CLI not found."
            return CursorResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        let canContinue = info.supportsContinue

        let strategy: CursorResumeCommandBuilder.Strategy
        let used: CursorStrategyUsed

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
                reason = "Installed Cursor CLI does not support --resume."
            } else {
                reason = "Cursor CLI does not advertise required flags (--resume/--continue)."
            }
            return CursorResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let pkg: CursorResumeCommandBuilder.CommandPackage
        do {
            pkg = try builder.makeCommand(strategy: strategy, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
        } catch {
            return CursorResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return CursorResumeResult(launched: false, strategy: used, error: nil, command: pkg.shellCommand)
        }

        do {
            try launcher.launchInTerminal(pkg)
            return CursorResumeResult(launched: true, strategy: used, error: nil, command: pkg.shellCommand)
        } catch {
            if policy == .resumeThenContinue, used == .resumeByID, info.supportsContinue {
                do {
                    let pkg2 = try builder.makeCommand(strategy: .continueMostRecent, binaryURL: info.binaryURL, workingDirectory: input.workingDirectory)
                    try launcher.launchInTerminal(pkg2)
                    return CursorResumeResult(launched: true, strategy: .continueMostRecent, error: nil, command: pkg2.shellCommand)
                } catch {
                    return CursorResumeResult(launched: false, strategy: .continueMostRecent, error: error.localizedDescription, command: nil)
                }
            }
            return CursorResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == CursorCLIEnvironment.ProbeResult, Failure == CursorCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
