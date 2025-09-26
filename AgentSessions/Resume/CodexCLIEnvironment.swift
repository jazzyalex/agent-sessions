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
        // 1) Respect explicit override if it points to an executable
        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        // 2) Ask the user's login+interactive shell (mirrors Terminal PATH)
        if let fromLogin = whichViaLoginShell("codex"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        // 3) Try our current process PATH (may work if app launched from Terminal)
        if let path = which("codex") { return URL(fileURLWithPath: path) }

        // 4) Probe common Homebrew and npm global locations
        var candidates: [String] = []
        if let brewPrefix = runAndCapture(["/usr/bin/env", "brew", "--prefix"]).out?.trimmingCharacters(in: .whitespacesAndNewlines), !brewPrefix.isEmpty {
            candidates.append("\(brewPrefix)/bin/codex")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/opt/codex/bin/codex",
            "/usr/local/opt/codex/bin/codex"
        ])
        if let npmPrefix = runAndCapture(["/usr/bin/env", "npm", "prefix", "-g"]).out?.trimmingCharacters(in: .whitespacesAndNewlines), !npmPrefix.isEmpty {
            candidates.append("\(npmPrefix)/bin/codex")
        }
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/codex"))

        for path in Set(candidates) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }

        // 5) As a last resort, check project-local .bin (useful for dev builds)
        let local = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("node_modules/.bin/codex")
        if FileManager.default.isExecutableFile(atPath: local) { return URL(fileURLWithPath: local) }

        return nil
    }

    func probeVersion(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        // Run "<binary> --version" via the user's login shell so the Node shebang resolves
        let shell = defaultShell()
        let cmd = "\(escapeForShell(binary.path)) --version"
        let result = runAndCapture([shell, "-lic", cmd])
        guard result.status == 0, let stdout = result.out else {
            return .failure(.commandFailed(result.err ?? "Failed to execute codex --version."))
        }
        let version = CodexVersion.parse(from: stdout)
        return .success(ProbeResult(version: version, binaryURL: binary))
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
        let shell = defaultShell()
        let res = runAndCapture([shell, "-lic", "command -v \(command) || true"]).out?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !res.isEmpty else { return nil }
        // If the shell prints just the name, ignore; we need a path
        if res == command { return nil }
        return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    private func defaultShell() -> String {
        let env = ProcessInfo.processInfo.environment
        if let s = env["SHELL"], !s.isEmpty { return s }
        return "/bin/zsh"
    }

    private func runAndCapture(_ argv: [String]) -> (status: Int32, out: String?, err: String?) {
        guard let first = argv.first else { return (127, nil, "no command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return (127, nil, error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return (process.terminationStatus, out, err)
    }

    private func escapeForShell(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if !s.contains("'") { return "'\(s)'" }
        return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
