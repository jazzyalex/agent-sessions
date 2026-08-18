import Foundation

protocol QwenCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError>
}

/// Locates Qwen Code and verifies the resume flags advertised by the installed binary.
/// The installed Qwen Code 0.21.13 `--help` advertises `--resume <id>` and `--continue`;
/// that help surface is all that was observed at 0.21.13 — model execution was
/// authentication-blocked, so end-to-end resume is untested (matrix pins 0.14.3).
struct QwenCLIEnvironment: QwenCLIEnvironmentProviding {
    static let binaryName = "qwen"

    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
        let supportsResume: Bool
        let supportsContinue: Bool
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "Qwen Code executable not found."
            case .commandFailed(let detail):
                return detail.isEmpty ? "Failed to execute qwen --version." : detail
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
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            probeEnv.loginShellExecutablePath(),
            which(Self.binaryName),
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ].compactMap { $0 }

        var firstExecutable: URL?
        var seen: Set<String> = []
        for path in candidates where seen.insert(path).inserted {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            if firstExecutable == nil { firstExecutable = url }
            if supportsResumeFlags(binary: url) { return url }
        }
        return firstExecutable
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }
        do {
            let version = try runCLI(binary, "--version")
            let combined = [version.stdout, version.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let help = try? runCLI(binary, "--help")
            let helpText = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")

            let supportsResume = helpContainsFlag("--resume", in: helpText)
            let supportsContinue = helpContainsFlag("--continue", in: helpText)

            // A probe that never ran is not evidence that Qwen lacks resume
            // flags. A Qwen that actually ran exits 0 for at least one of
            // --version/--help, or prints a flag we recognise; anything else
            // means we learned nothing, and calling that "supports nothing"
            // silently disables every resume action.
            let learnedNothing = !supportsResume && !supportsContinue
            if version.exitCode != 0, (help?.exitCode ?? 127) != 0, learnedNothing {
                let reason = [version.stderr, help?.stderr]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                return .failure(.commandFailed(reason))
            }

            return .success(ProbeResult(
                versionString: version.exitCode == 0 && !combined.isEmpty ? combined : "unknown",
                binaryURL: binary,
                supportsResume: supportsResume,
                supportsContinue: supportsContinue
            ))
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


    private func supportsResumeFlags(binary: URL) -> Bool {
        let help = try? runCLI(binary, "--help")
        let output = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")
        return helpContainsFlag("--resume", in: output) || helpContainsFlag("--continue", in: output)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { $0.isWhitespace || ",=[](){}<>:;".contains($0) }.contains { $0 == flag }
    }
}
