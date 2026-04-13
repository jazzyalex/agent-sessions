import Foundation

protocol CursorCLIEnvironmentProviding {
    func probe(customPath: String?) -> Result<CursorCLIEnvironment.ProbeResult, CursorCLIEnvironment.ProbeError>
}

/// Lightweight CLI probe for the Cursor Agent CLI (`agent` command).
/// Detects binary location, version string, and resume/continue flag support.
struct CursorCLIEnvironment: CursorCLIEnvironmentProviding {
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
                return "Cursor CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute agent --version." : stderr
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
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        let loginShellCandidates = [
            whichViaLoginShell("agent"),
            whichViaLoginShell("cursor")
        ].compactMap { $0 }
        if let url = bestCursorCLI(from: loginShellCandidates) {
            return url
        }

        let pathCandidates = [
            which("agent"),
            which("cursor")
        ].compactMap { $0 }
        if let url = bestCursorCLI(from: pathCandidates) {
            return url
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agent",
            "/opt/homebrew/bin/agent",
            "/usr/local/bin/agent",
            "\(home)/.local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "/usr/local/bin/cursor"
        ]

        if let url = bestCursorCLI(from: candidates) {
            return url
        }

        return nil
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let versionRes = try executor.run([binary.path, "--version"], cwd: nil)
            let versionString: String
            if versionRes.exitCode == 0 {
                let versionCombined = [versionRes.stdout, versionRes.stderr]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                versionString = versionCombined.isEmpty ? "unknown" : versionCombined
            } else {
                // Cursor CLI may exit non-zero for --version in supported install states
                // (e.g. agent-only install without Cursor IDE). Keep probing help flags.
                versionString = "unknown"
            }

            let topHelp = (try? executor.run([binary.path, "--help"], cwd: nil))
            let agentHelp = (try? executor.run([binary.path, "agent", "--help"], cwd: nil))
            let helpOut = [topHelp?.stdout, topHelp?.stderr, agentHelp?.stdout, agentHelp?.stderr]
                .compactMap { $0 }
                .joined(separator: "\n")

            let supportsResume = helpOut.contains("--resume")
            let supportsContinue = helpOut.contains("--continue")

            return .success(
                ProbeResult(
                    versionString: versionString,
                    binaryURL: binary,
                    supportsResume: supportsResume,
                    supportsContinue: supportsContinue
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

    private func bestCursorCLI(from paths: [String]) -> URL? {
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
        let topHelp = (try? executor.run([binary.path, "--help"], cwd: nil))
        let agentHelp = (try? executor.run([binary.path, "agent", "--help"], cwd: nil))
        let helpOut = [topHelp?.stdout, topHelp?.stderr, agentHelp?.stdout, agentHelp?.stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        return helpOut.contains("--resume") || helpOut.contains("--continue")
    }
}
