import XCTest
@testable import AgentSessions

/// The helper four agents now share. Its behaviour was only ever pinned through
/// their probes, which is indirect enough that a marker or merge-order change
/// could look fine in every agent test and still be wrong here.
final class CLIProbeEnvironmentTests: XCTestCase {
    func testReadsPathAndExecutableFromBetweenTheMarkers() {
        let shell = FakeShell(stdout: """
        \(CLIProbeEnvironment.pathMarker.begin)/opt/homebrew/bin:/usr/bin\(CLIProbeEnvironment.pathMarker.end)
        \(CLIProbeEnvironment.whichMarker.begin)/opt/homebrew/bin/pi\(CLIProbeEnvironment.whichMarker.end)
        """)

        let env = CLIProbeEnvironment(executor: shell, commandName: "pi")

        XCTAssertEqual(env.loginShellExecutablePath(), "/opt/homebrew/bin/pi")
        XCTAssertTrue(env.probeEnvironment()["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/bin") == true)
    }

    /// Banners, MOTDs and version-manager chatter share stdout with the answer.
    /// Only what sits between the markers may be read — including when a noise
    /// line is itself a plausible executable path.
    func testIgnoresEverythingOutsideTheMarkers() {
        let shell = FakeShell(stdout: """
        Welcome to zsh!
        /usr/bin/env
        \(CLIProbeEnvironment.pathMarker.begin)/usr/bin\(CLIProbeEnvironment.pathMarker.end)
        nvm: using node v22
        \(CLIProbeEnvironment.whichMarker.begin)/opt/homebrew/bin/kimi\(CLIProbeEnvironment.whichMarker.end)
        have a nice day
        """)

        let env = CLIProbeEnvironment(executor: shell, commandName: "kimi")

        XCTAssertEqual(env.loginShellExecutablePath(), "/opt/homebrew/bin/kimi")
    }

    /// `command -v` prints nothing when the CLI is not installed, and some
    /// shells echo the bare name back instead. Neither is a path.
    func testReportsNoExecutableWhenTheShellFoundNothing() {
        let empty = FakeShell(stdout: """
        \(CLIProbeEnvironment.pathMarker.begin)/usr/bin\(CLIProbeEnvironment.pathMarker.end)
        \(CLIProbeEnvironment.whichMarker.begin)\(CLIProbeEnvironment.whichMarker.end)
        """)
        XCTAssertNil(CLIProbeEnvironment(executor: empty, commandName: "qwen").loginShellExecutablePath())

        let echoed = FakeShell(stdout: """
        \(CLIProbeEnvironment.pathMarker.begin)/usr/bin\(CLIProbeEnvironment.pathMarker.end)
        \(CLIProbeEnvironment.whichMarker.begin)qwen\(CLIProbeEnvironment.whichMarker.end)
        """)
        XCTAssertNil(CLIProbeEnvironment(executor: echoed, commandName: "qwen").loginShellExecutablePath())
    }

    /// The user's own ordering is the one that works, so the login-shell PATH
    /// leads; our fallbacks fill gaps behind it and never duplicate an entry.
    func testMergedPathLeadsWithTheLoginShellAndDoesNotRepeatEntries() throws {
        let shell = FakeShell(stdout: "\(CLIProbeEnvironment.pathMarker.begin)/first:/opt/homebrew/bin\(CLIProbeEnvironment.pathMarker.end)")

        let path = try XCTUnwrap(CLIProbeEnvironment(executor: shell, commandName: "pi").probeEnvironment()["PATH"])
        let entries = path.split(separator: ":").map(String.init)

        XCTAssertEqual(entries.first, "/first")
        XCTAssertEqual(entries.count, Set(entries).count, "duplicate PATH entries: \(path)")
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            XCTAssertTrue(entries.contains(expected), "missing fallback \(expected) in \(path)")
        }
    }

    /// Everything but PATH is inherited — a probe still needs HOME, and losing
    /// the rest of the environment is its own class of bug.
    func testKeepsTheRestOfTheInheritedEnvironment() {
        let shell = FakeShell(stdout: "\(CLIProbeEnvironment.pathMarker.begin)/usr/bin\(CLIProbeEnvironment.pathMarker.end)")

        let env = CLIProbeEnvironment(executor: shell, commandName: "pi").probeEnvironment()

        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    /// Spawning a login shell costs hundreds of milliseconds, and a probe asks
    /// for the environment once per command it runs.
    func testAsksTheLoginShellOnlyOnce() {
        let shell = FakeShell(stdout: """
        \(CLIProbeEnvironment.pathMarker.begin)/usr/bin\(CLIProbeEnvironment.pathMarker.end)
        \(CLIProbeEnvironment.whichMarker.begin)/usr/bin/pi\(CLIProbeEnvironment.whichMarker.end)
        """)

        let env = CLIProbeEnvironment(executor: shell, commandName: "pi")
        _ = env.loginShellExecutablePath()
        _ = env.probeEnvironment()
        _ = env.probeEnvironment()

        XCTAssertEqual(shell.invocations, 1)
    }

    /// A shell that fails or is missing must not take the probe down with it —
    /// the fallbacks alone still describe a usable PATH.
    func testSurvivesAShellThatCannotRun() {
        struct Failing: CommandExecuting {
            func run(_ command: [String], cwd: URL?) throws -> CommandResult {
                throw CommandError.executableNotFound(command.first ?? "")
            }
        }

        let env = CLIProbeEnvironment(executor: Failing(), commandName: "pi")

        XCTAssertNil(env.loginShellExecutablePath())
        XCTAssertTrue(env.probeEnvironment()["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    // MARK: - Lazy widening

    /// The whole point of widening is the login shell, and it is the expensive
    /// part. A command that already runs must not trigger it.
    func testRunDoesNotAskTheShellWhenTheInheritedEnvironmentWorks() {
        let executor = ScriptedExecutor(results: [CommandResult(stdout: "1.0.0", stderr: "", exitCode: 0)])

        let result = try? CLIProbeEnvironment(executor: executor, commandName: "pi")
            .run(URL(fileURLWithPath: "/opt/homebrew/bin/pi"), "--version")

        XCTAssertEqual(result?.stdout, "1.0.0")
        XCTAssertEqual(executor.loginShellInvocations, 0)
        XCTAssertEqual(executor.environmentsSeen, [nil], "the first attempt must inherit, not widen")
    }

    /// And when it does not run, the retry has to actually carry the wider PATH.
    func testRunRetriesWithTheWidenedPathAfterAFailure() throws {
        let executor = ScriptedExecutor(results: [
            CommandResult(stdout: "", stderr: "env: node: No such file or directory", exitCode: 127),
            CommandResult(stdout: "1.0.0", stderr: "", exitCode: 0)
        ])
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin"

        let result = try CLIProbeEnvironment(executor: executor, commandName: "pi")
            .run(URL(fileURLWithPath: "/opt/homebrew/bin/pi"), "--version")

        XCTAssertEqual(result.stdout, "1.0.0")
        XCTAssertEqual(executor.loginShellInvocations, 1)
        XCTAssertTrue(try XCTUnwrap(executor.environmentsSeen.last as? [String: String])["PATH"]?
            .contains("/opt/homebrew/bin") == true)
    }

    /// When widening does not help either, the user is better served by what
    /// their own PATH said than by a second copy of the same failure.
    func testRunKeepsTheFirstFailureWhenWideningDoesNotHelp() throws {
        let executor = ScriptedExecutor(results: [
            CommandResult(stdout: "", stderr: "env: node: No such file or directory", exitCode: 127),
            CommandResult(stdout: "", stderr: "still broken", exitCode: 1)
        ])

        let result = try CLIProbeEnvironment(executor: executor, commandName: "pi")
            .run(URL(fileURLWithPath: "/opt/homebrew/bin/pi"), "--version")

        XCTAssertEqual(result.stderr, "env: node: No such file or directory")
    }

    /// Hands back results in order and records what each attempt was given.
    private final class ScriptedExecutor: CommandExecuting {
        private var results: [CommandResult]
        var loginShellPATH = "/usr/bin:/bin"
        private(set) var loginShellInvocations = 0
        private(set) var environmentsSeen: [[String: String]?] = []

        init(results: [CommandResult]) {
            self.results = results
        }

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            try run(command, cwd: cwd, environment: nil)
        }

        func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
            if command.count == 3, command[1] == "-lic" {
                loginShellInvocations += 1
                return CommandResult(
                    stdout: "\(CLIProbeEnvironment.pathMarker.begin)\(loginShellPATH)\(CLIProbeEnvironment.pathMarker.end)",
                    stderr: "",
                    exitCode: 0
                )
            }
            environmentsSeen.append(environment)
            return results.isEmpty ? CommandResult(stdout: "", stderr: "", exitCode: 0) : results.removeFirst()
        }
    }

    private final class FakeShell: CommandExecuting {
        private let stdout: String
        private(set) var invocations = 0

        init(stdout: String) {
            self.stdout = stdout
        }

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            invocations += 1
            return CommandResult(stdout: stdout, stderr: "", exitCode: 0)
        }
    }
}
