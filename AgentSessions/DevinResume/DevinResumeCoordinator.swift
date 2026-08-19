import Foundation

@MainActor
final class DevinResumeCoordinator {
    private let env: DevinCLIEnvironmentProviding
    private let builder: DevinResumeCommandBuilder
    private let launcher: DevinTerminalLaunching

    init(env: DevinCLIEnvironmentProviding,
         builder: DevinResumeCommandBuilder,
         launcher: DevinTerminalLaunching) {
        self.env = env
        self.builder = builder
        self.launcher = launcher
    }

    func resumeInTerminal(input: DevinResumeInput,
                          policy: DevinFallbackPolicy = .sessionThenContinue,
                          dryRun: Bool = false) async -> DevinResumeResult {
        // Probing spawns a login shell plus per-candidate --help with no
        // timeout, so it must never run on the MainActor.
        let env = self.env
        let binaryOverride = input.binaryOverride
        let probe = await Task.detached { env.probe(customPath: binaryOverride) }.value
        guard case let .success(info) = probe else {
            let message = probe.failureValue?.localizedDescription ?? "Devin CLI not found."
            return DevinResumeResult(launched: false, strategy: .none, error: message, command: nil)
        }

        let hasID = (input.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let canResume = info.supportsResume && hasID
        // `--continue` resumes "the previous session for the working
        // directory", so without a known directory it resolves against
        // whatever the terminal happens to open in and silently attaches to an
        // unrelated session while reporting success. Refuse instead.
        let canContinue = info.supportsContinue && input.workingDirectory != nil

        let strategy: DevinResumeCommandBuilder.Strategy
        let used: DevinStrategyUsed

        if canResume {
            strategy = .sessionByID(id: input.sessionID!)
            used = .sessionByID
        } else if policy == .sessionThenContinue, canContinue {
            strategy = .continueMostRecent
            used = .continueMostRecent
        } else {
            let reason: String
            if !hasID && policy == .sessionOnly {
                reason = "No session ID available, and fallback is disabled."
            } else if hasID && !info.supportsResume && policy == .sessionOnly {
                reason = "Installed Devin CLI does not support --resume."
            } else if info.supportsContinue && input.workingDirectory == nil {
                reason = "No working directory for this session, so --continue would resume an unrelated one."
            } else {
                reason = "Devin CLI does not advertise required flags (--resume/--continue)."
            }
            return DevinResumeResult(launched: false, strategy: .none, error: reason, command: nil)
        }

        let package: DevinResumeCommandBuilder.CommandPackage
        do {
            package = try builder.makeCommand(strategy: strategy,
                                              binaryURL: info.binaryURL,
                                              workingDirectory: input.workingDirectory)
        } catch {
            return DevinResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }

        if dryRun {
            return DevinResumeResult(launched: false, strategy: used, error: nil, command: package.shellCommand)
        }

        do {
            try await launcher.launchInTerminal(package)
            return DevinResumeResult(launched: true, strategy: used, error: nil, command: package.shellCommand)
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
            return DevinResumeResult(launched: false, strategy: used, error: error.localizedDescription, command: nil)
        }
    }
}

private extension Result where Success == DevinCLIEnvironment.ProbeResult, Failure == DevinCLIEnvironment.ProbeError {
    var failureValue: Failure? { if case let .failure(e) = self { return e } ; return nil }
}
