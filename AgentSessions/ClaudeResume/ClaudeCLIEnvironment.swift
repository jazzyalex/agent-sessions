import Foundation

/// Lightweight CLI probe for the `claude` command.
/// Detects binary location, version string, and presence of resume/continue flags.
struct ClaudeCLIEnvironment {
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
                return "Claude CLI executable not found."
            case let .commandFailed(stderr):
                return stderr.isEmpty ? "Failed to execute claude --version." : stderr
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
        if let fromLogin = whichViaLoginShell("claude"), FileManager.default.isExecutableFile(atPath: fromLogin) {
            return URL(fileURLWithPath: fromLogin)
        }

        // 3) Try our current process PATH
        if let path = which("claude") { return URL(fileURLWithPath: path) }

        // 4) Common install locations (Homebrew, npm global)
        var candidates: [String] = []
        if let brewPrefix = runAndCapture(["/usr/bin/env", "brew", "--prefix"], useSafeHome: false).out?.trimmingCharacters(in: .whitespacesAndNewlines), !brewPrefix.isEmpty {
            candidates.append("\(brewPrefix)/bin/claude")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
        if let npmPrefix = runAndCapture(["/usr/bin/env", "npm", "prefix", "-g"], useSafeHome: false).out?.trimmingCharacters(in: .whitespacesAndNewlines), !npmPrefix.isEmpty {
            candidates.append("\(npmPrefix)/bin/claude")
        }
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/claude"))
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"))

        for path in Set(candidates) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }

        // 5) Project-local .bin
        let local = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("node_modules/.bin/claude")
        if FileManager.default.isExecutableFile(atPath: local) { return URL(fileURLWithPath: local) }

        return nil
    }

    /// Returns version string and feature support by inspecting `--version` and `--help`.
    func probe(customPath: String?) -> Result<ProbeResult, ProbeError> {
        guard let binary = resolveBinary(customPath: customPath) else {
            return .failure(.binaryNotFound)
        }

        let shell = defaultShell()
        let versionCmd = "\(escapeForShell(binary.path)) --version"
        let helpCmd = "\(escapeForShell(binary.path)) --help"

        let vres = runAndCapture([shell, "-lic", versionCmd], useSafeHome: true)
        guard vres.status == 0 else {
            return .failure(.commandFailed(vres.err ?? "Failed to execute claude --version."))
        }
        let versionStr = (vres.out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let hres = runAndCapture([shell, "-lic", helpCmd], useSafeHome: true)
        let helpOut = (hres.out ?? "") + (hres.err ?? "")
        // Heuristic: look for flags in help text; if help is non-standard JS output, default to false
        let supportsResume = helpOut.range(of: "--resume", options: .regularExpression) != nil
        let supportsContinue = helpOut.range(of: "--continue", options: .regularExpression) != nil

        return .success(ProbeResult(versionString: versionStr, binaryURL: binary, supportsResume: supportsResume, supportsContinue: supportsContinue))
    }

    // MARK: - Helpers

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
        let res = runAndCapture([shell, "-lic", "command -v \(command) || true"], useSafeHome: false).out?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !res.isEmpty else { return nil }
        if res == command { return nil }
        return res.split(whereSeparator: { $0.isNewline }).first.map(String.init)
    }

    private func defaultShell() -> String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    private func runAndCapture(_ argv: [String], useSafeHome: Bool = false) -> (status: Int32, out: String?, err: String?) {
        guard let first = argv.first else { return (127, nil, "no command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        if useSafeHome {
            // Provide a writable HOME to avoid sandbox writes under read-only '/'
            let base = NSTemporaryDirectory()
            let safeHome = (base as NSString).appendingPathComponent("AgentSessions-claude-safe-home")
            try? FileManager.default.createDirectory(atPath: safeHome, withIntermediateDirectories: true)
            env["HOME"] = safeHome
        }
        process.environment = env
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
