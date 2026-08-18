import Foundation

public enum CommandError: Error, LocalizedError {
    case executableNotFound(String)
    case executionFailed(command: [String], exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Executable not found at \(path)"
        case let .executionFailed(command, exitCode, stderr):
            let joined = command.joined(separator: " ")
            return "Command failed (exit \(exitCode)): \(joined)\n\(stderr)"
        }
    }
}

public struct CommandResult {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public protocol CommandExecuting {
    func run(_ command: [String], cwd: URL?) throws -> CommandResult
    /// Runs with an explicit child environment. Needed for CLIs shipped as
    /// `#!/usr/bin/env node` scripts: a Finder-launched app inherits a PATH with
    /// no Homebrew or npm prefix in it, so the shebang cannot find its interpreter.
    func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult
}

public extension CommandExecuting {
    /// Executors that have no control over the child environment — test doubles,
    /// and callers that never needed one — just inherit ours.
    func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
        try run(command, cwd: cwd)
    }
}

public struct ProcessCommandExecutor: CommandExecuting {
    public init() {}

    public func run(_ command: [String], cwd: URL?) throws -> CommandResult {
        try run(command, cwd: cwd, environment: nil)
    }

    public func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
        guard !command.isEmpty else {
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }

        let process = Process()
        // Only assign when the caller passed a dict. A fresh Process already
        // has environment == nil (inherit). Writing nil explicitly does not
        // inherit on this Foundation: the child starts empty, `/bin/sh` then
        // invents a POSIX default PATH, and every 2-arg probe loses Homebrew.
        if let environment {
            process.environment = environment
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = cwd
        process.executableURL = URL(fileURLWithPath: command[0])

        do {
            try process.run()
        } catch {
            throw CommandError.executableNotFound(command[0])
        }

        process.waitForExit()

        let stdoutData = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let stderrData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
