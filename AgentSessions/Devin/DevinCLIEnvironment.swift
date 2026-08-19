import Foundation

protocol DevinCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<DevinCLIEnvironment.ProbeResult, DevinCLIEnvironment.ProbeError>
}

/// Locates and interrogates the Devin CLI.
///
/// Verified against `devin --help` at CLI 3000.3.27 (0becb483):
///
///     -c, --continue       Continue the most recent conversation.
///     -r, --resume [<SESSION_ID>]
///                          Resume a conversation. With an ID, resume that
///                          session; without one, pick interactively.
struct DevinCLIEnvironment: DevinCLIEnvironmentProviding {
    static let binaryName = "devin"

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
            case .binaryNotFound:
                return "Devin CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute devin --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let loginShellCandidates = [whichViaLoginShell(Self.binaryName)].compactMap { $0 }
        if let url = bestDevinCLI(from: loginShellCandidates) {
            return url
        }

        let pathCandidates = [which(Self.binaryName)].compactMap { $0 }
        if let url = bestDevinCLI(from: pathCandidates) {
            return url
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/share/devin/cli/\(Self.binaryName)",
            "\(home)/.local/bin/\(Self.binaryName)",
            "\(home)/.npm-global/bin/\(Self.binaryName)",
            "/opt/homebrew/bin/\(Self.binaryName)",
            "/usr/local/bin/\(Self.binaryName)"
        ]

        return bestDevinCLI(from: candidates)
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try executor.run([binary.path, "--version"], cwd: nil)
            let versionString: String
            if versionRes.exitCode == 0 {
                let combined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = combined.isEmpty ? "unknown" : combined
            } else {
                versionString = "unknown"
            }

            let helpRes = try? executor.run([binary.path, "--help"], cwd: nil)
            let helpOut = [helpRes?.stdout, helpRes?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsResume: helpContainsFlag("--resume", in: helpOut),
                    supportsContinue: helpContainsFlag("--continue", in: helpOut)
                )
            )
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
        do {
            let result = try executor.run([shell, "-lic", "command -v \(command) || true"], cwd: nil)
            let res = [result.stdout, result.stderr].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !res.isEmpty, res != command else { return nil }
            return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        } catch {
            return nil
        }
    }

    private func bestDevinCLI(from paths: [String]) -> URL? {
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
        let help = try? executor.run([binary.path, "--help"], cwd: nil)
        let helpOut = [help?.stdout, help?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return helpContainsFlag("--resume", in: helpOut)
            || helpContainsFlag("--continue", in: helpOut)
    }

    private func helpContainsFlag(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }
}
