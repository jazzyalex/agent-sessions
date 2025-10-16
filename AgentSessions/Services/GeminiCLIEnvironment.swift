import Foundation

struct GeminiCLIEnvironment {
    struct ProbeResult {
        let versionString: String
        let binaryURL: URL
    }

    enum ProbeError: Error {
        case notFound
        case invalidResponse
    }

    private let executor: CommandExecuting

    init(executor: CommandExecuting = ProcessCommandExecutor()) {
        self.executor = executor
    }

    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        let command = customPath ?? "gemini"
        guard let url = which(command) else { return .failure(.notFound) }

        do {
            let result = try executor.run([url.path, "--version"], cwd: nil)
            if result.exitCode == 0 {
                return .success(ProbeResult(versionString: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), binaryURL: url))
            } else {
                return .failure(.invalidResponse)
            }
        } catch {
            return .failure(.notFound)
        }
    }

    private func which(_ command: String) -> URL? {
        if command.starts(with: "/") {
            let url = URL(fileURLWithPath: command)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        } else {
            guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
            for component in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}