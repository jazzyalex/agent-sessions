import Foundation

protocol PiCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<PiCLIEnvironment.ProbeResult, PiCLIEnvironment.ProbeError>
}

struct PiCLIEnvironment: PiCLIEnvironmentProviding {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsSession: Bool
        let supportsResume: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Pi CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute pi --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting
    private let probeEnv: CLIProbeEnvironment

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
        self.probeEnv = CLIProbeEnvironment(executor: executor, commandName: "pi")
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // One ordered list, searched as a whole, rather than group-by-group
        // early returns. `bestPiCLI` falls back to the first executable it saw,
        // so with the groups separated an unverified hit from the login shell
        // was returned before the later locations were ever examined — meaning
        // an unrelated binary of the same name earlier in PATH would mask a
        // real CLI installed under one of them. `pi` is a short, generic name,
        // so that collision is not hypothetical.
        let candidates: [String] = [
            probeEnv.loginShellExecutablePath(),
            which("pi"),
            "\(home)/.local/bin/pi",
            "\(home)/.npm-global/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi"
        ].compactMap { $0 }

        return bestPiCLI(from: candidates)
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try runPi(binary, "--version")
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? runPi(binary, "--help")
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            let supportsSession = helpContainsFlag("--session", in: helpOut)
            let supportsResume = helpContainsFlag("--resume", in: helpOut)
            let supportsContinue = helpContainsFlag("--continue", in: helpOut)

            // A probe that never ran is not evidence that Pi lacks resume flags.
            // Reporting it as success-with-nothing-supported is what made the
            // resume coordinator answer "Pi CLI does not advertise required
            // flags" for a perfectly capable install. A Pi that actually ran
            // exits 0 for at least one of --version/--help, or prints a flag we
            // recognise; anything else means we learned nothing.
            let learnedNothing = !supportsSession && !supportsResume && !supportsContinue
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
                    supportsResume: supportsResume,
                    supportsContinue: supportsContinue
                )
            )
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    /// Every invocation of the CLI goes through here so the child always gets a
    /// PATH that can resolve `#!/usr/bin/env node`.
    private func runPi(_ binary: URL, _ argument: String) throws -> CommandResult {
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

    private func bestPiCLI(from paths: [String]) -> URL? {
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
        let help = try? runPi(binary, "--help")
        let helpOut = [help?.stdout, help?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return helpContainsFlag("--session", in: helpOut)
            || helpContainsFlag("--resume", in: helpOut)
            || helpContainsFlag("--continue", in: helpOut)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }
}
