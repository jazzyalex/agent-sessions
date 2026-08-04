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
        // Probing spawns a login shell plus per-candidate --help with no
        // timeout, so it must never run on the MainActor.
        let env = self.env
        let binaryOverride = input.binaryOverride
        let probe = await Task.detached { env.probe(customPath: binaryOverride) }.value
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
            try await launcher.launchInTerminal(package)
            return PiResumeResult(launched: true, strategy: used, error: nil, command: package.shellCommand)
        } catch {
            // No retry here. Nothing `launchInTerminal` throws is
            // command-dependent: Terminal/iTerm fail only when osascript exits
            // non-zero, and the command reaches it as an opaque argv item;
            // Warp fails on a missing scheme handler, a directory-create or
            // tab-config write, or a refused open -- none of them a function of
            // which command was requested.
            // Retrying with a *different* command cannot recover — and if it
            // did succeed it would resume an unrelated session while reporting
            // success.
            return PiResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == PiCLIEnvironment.ProbeResult, Failure == PiCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
