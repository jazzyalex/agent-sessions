import Foundation

struct CodexCLIEnvironment {
    struct ProbeResult {
        let version: CodexVersion
        let binaryURL: URL
    }

    enum ProbeError: Error, LocalizedError {
        case binaryNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Codex CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute codex --version." : stderr
            }
        }
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func resolveBinary(customPath: String?) -> URL? {
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let path = which("codex") {
            return URL(fileURLWithPath: path)
        }

        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/homebrew/opt/codex/bin", "/usr/local/opt/codex/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    func probeVersion(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        do {
            let result = try executor.run([binary.path, "--version"], cwd: nil)
            guard result.exitCode == 0 else {
                return .failure(.commandFailed(result.stderr))
            }
            let version = CodexVersion.parse(from: result.stdout)
            return .success(ProbeResult(version: version, binaryURL: binary))
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    private func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
