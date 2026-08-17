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

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            whichViaLoginShell(Self.binaryName),
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
            let version = try executor.run([binary.path, "--version"], cwd: nil)
            let combined = [version.stdout, version.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let help = try? executor.run([binary.path, "--help"], cwd: nil)
            let helpText = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")
            return .success(ProbeResult(
                versionString: version.exitCode == 0 && !combined.isEmpty ? combined : "unknown",
                binaryURL: binary,
                supportsResume: helpContainsFlag("--resume", in: helpText),
                supportsContinue: helpContainsFlag("--continue", in: helpText)
            ))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private func whichViaLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? executor.run([shell, "-lic", "command -v \(command) || true"], cwd: nil) else {
            return nil
        }
        let output = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != command else { return nil }
        return output.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    private func supportsResumeFlags(binary: URL) -> Bool {
        let help = try? executor.run([binary.path, "--help"], cwd: nil)
        let output = [help?.stdout, help?.stderr].compactMap { $0 }.joined(separator: "\n")
        return helpContainsFlag("--resume", in: output) || helpContainsFlag("--continue", in: output)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { $0.isWhitespace || ",=[](){}<>:;".contains($0) }.contains { $0 == flag }
    }
}
