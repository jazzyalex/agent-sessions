import Foundation

protocol KimiCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<KimiCLIEnvironment.ProbeResult, KimiCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Kimi Code CLI.
///
/// Verified against `kimi --help` at CLI 0.29.1 and re-confirmed unchanged at
/// 0.31.1:
///
///     -S, --session [id]   Resume a session. With ID: resume that session.
///     -c, --continue       Continue the previous session for the working directory.
///
/// Kimi has no `--resume` flag, so — unlike Pi — there is no `supportsResume`
/// capability to probe for.
struct KimiCLIEnvironment: KimiCLIEnvironmentProviding {
    static let binaryName = "kimi"

    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsSession: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Kimi Code CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute kimi --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting
    private let probeEnv: CLIProbeEnvironment

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
        self.probeEnv = CLIProbeEnvironment(executor: executor, commandName: Self.binaryName)
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // One ordered list, searched as a whole, rather than group-by-group
        // early returns. `bestKimiCLI` falls back to the first executable it
        // saw, so with the groups separated an unverified hit from the login
        // shell was returned before the later locations were ever examined —
        // meaning an unrelated binary of the same name earlier in PATH would
        // mask a real CLI installed under one of them.
        let candidates: [String] = [
            probeEnv.loginShellExecutablePath(),
            which(Self.binaryName),
            "\(home)/.kimi-code/bin/\(Self.binaryName)",
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        return bestKimiCLI(from: candidates)
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try runCLI(binary, "--version")
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? runCLI(binary, "--help")
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            let supportsSession = helpContainsFlag("--session", in: helpOut)
            let supportsContinue = helpContainsFlag("--continue", in: helpOut)

            // A probe that never ran is not evidence that Kimi lacks resume
            // flags. A Kimi that actually ran exits 0 for at least one of
            // --version/--help, or prints a flag we recognise; anything else
            // means we learned nothing, and calling that "supports nothing"
            // silently disables every resume action.
            let learnedNothing = !supportsSession && !supportsContinue
            if versionRes.exitCode != 0, (helpRes?.exitCode ?? 127) != 0, learnedNothing {
                let reason = [versionRes.stderr, helpRes?.stderr]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                return .failure(.commandFailed(reason))
            }

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsSession: supportsSession,
                    supportsContinue: supportsContinue
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    /// Every invocation of the CLI goes through here so the child always gets a
    /// PATH that can resolve `#!/usr/bin/env node`.
    private func runCLI(_ binary: URL, _ argument: String) throws -> CommandResult {
        try executor.run([binary.path, argument], cwd: nil, environment: probeEnv.probeEnvironment())
    }

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }


    private func bestKimiCLI(from paths: [String]) -> URL? {
        var firstExecutable: URL?
        var seen = Set<String>()

        for path in paths {
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            if firstExecutable == nil {
                firstExecutable = url
            }
            if supportsResumeFlags(binary: url) {
                return url
            }
        }

        return firstExecutable
    }

    private func supportsResumeFlags(binary: URL) -> Bool {
        let help = try? runCLI(binary, "--help")
        let helpOut = [help?.stdout, help?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return helpContainsFlag("--session", in: helpOut)
            || helpContainsFlag("--continue", in: helpOut)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }
}
