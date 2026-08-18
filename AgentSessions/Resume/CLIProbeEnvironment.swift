import Foundation

/// Environment for probing an agent CLI, and login-shell discovery of where it lives.
///
/// A Finder-launched app inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`
/// — no Homebrew, no npm prefix, no Node version-manager shim. CLIs shipped as Node
/// scripts start with `#!/usr/bin/env node`, so running one under that PATH dies with
/// `env: node: No such file or directory` before the CLI itself ever starts. Probing
/// a CLI therefore has to hand the child a PATH the user would actually have, which
/// only their login shell knows.
///
/// The shell is asked exactly once per instance and both answers come back from the
/// same invocation, delimited by markers: login shells print banners, MOTDs and
/// version-manager chatter, and without delimiters a banner line can be mistaken for
/// the resolved binary path.
final class CLIProbeEnvironment {
    struct Marker {
        let begin: String
        let end: String
    }

    static let pathMarker = Marker(begin: "__AS_PROBE_PATH_BEGIN__", end: "__AS_PROBE_PATH_END__")
    static let whichMarker = Marker(begin: "__AS_PROBE_WHICH_BEGIN__", end: "__AS_PROBE_WHICH_END__")

    private let executor: CommandExecuting
    private let commandName: String
    private var cached: (path: String, executablePath: String?)?

    init(executor: CommandExecuting, commandName: String) {
        self.executor = executor
        self.commandName = commandName
    }

    /// Where the login shell says the CLI lives, or nil if it does not know.
    func loginShellExecutablePath() -> String? {
        discover().executablePath
    }

    /// The environment probe commands should run under: the inherited environment
    /// with PATH widened to what the login shell and the usual install prefixes offer.
    func probeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = discover().path
        return env
    }

    /// Runs one probe command, widening PATH only when the inherited environment
    /// could not run it.
    ///
    /// The widening costs a login shell, which is worth hundreds of milliseconds
    /// and is pure waste whenever the app was launched from a terminal, the CLI
    /// is a native binary, or the user pointed us straight at an executable —
    /// all of which run fine on the PATH we already have. So try that first and
    /// only pay for the shell once something has actually failed.
    func run(_ binary: URL, _ argument: String) throws -> CommandResult {
        let inherited = try executor.run([binary.path, argument], cwd: nil)
        guard inherited.exitCode != 0 else { return inherited }

        guard let widened = try? executor.run([binary.path, argument],
                                              cwd: nil,
                                              environment: probeEnvironment()) else {
            return inherited
        }
        // Keep the first failure when widening did not help: its stderr names
        // what the user's own PATH did, which is what they can act on.
        return widened.exitCode == 0 ? widened : inherited
    }

    /// Whole-token flag match, so `--session-dir` never reads as `--session`.
    static func helpAdvertises(_ flag: String, in help: String) -> Bool {
        help.split { character in
            character.isWhitespace || ",=[](){}<>:;".contains(character)
        }
        .contains { $0 == flag }
    }

    /// The reason to report when a probe never executed the CLI, or nil when it
    /// did and we can trust what it said.
    ///
    /// A probe that could not run is not evidence that the CLI lacks resume
    /// flags — recording it that way is what silently disabled every resume
    /// action in #58. A CLI that actually ran exits 0 for at least one of
    /// `--version`/`--help`, or prints a flag we recognise.
    static func probeFailureReason(version: CommandResult,
                                   help: CommandResult?,
                                   learnedNothing: Bool) -> String? {
        guard version.exitCode != 0, (help?.exitCode ?? 127) != 0, learnedNothing else { return nil }
        return [version.stderr, help?.stderr]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// First executable of that name on the PATH this process inherited.
    static func which(_ command: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for component in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private func discover() -> (path: String, executablePath: String?) {
        if let cached { return cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        printf '%s%s%s\\n' '\(Self.pathMarker.begin)' "$PATH" '\(Self.pathMarker.end)'
        printf '%s%s%s\\n' '\(Self.whichMarker.begin)' "$(command -v '\(commandName)' || true)" '\(Self.whichMarker.end)'
        """
        // stdout only: the markers survive stderr chatter, but merging the streams
        // would let a banner printed between the two printfs land inside a field.
        let stdout = (try? executor.run([shell, "-lic", script], cwd: nil))?.stdout ?? ""

        let loginPath = Self.field(Self.pathMarker, in: stdout)
        let which = Self.field(Self.whichMarker, in: stdout).flatMap { candidate -> String? in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != commandName else { return nil }
            return trimmed
        }

        let resolved = (path: Self.mergedPath(loginPath: loginPath), executablePath: which)
        cached = resolved
        return resolved
    }

    /// Login-shell PATH first — the user's own ordering is the one that works —
    /// then our inherited PATH, then the prefixes a Node or Homebrew install uses.
    private static func mergedPath(loginPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Fixed prefixes only. The Node version managers people actually use put
        // their shims behind a version or a per-shell directory — nvm at
        // `~/.nvm/versions/node/<version>/bin`, fnm under a multishell path
        // keyed to the running shell — so there is nothing static to add for
        // them. The login-shell PATH above is what covers those installs, and
        // this list is the floor for when the shell could not be asked.
        let fallbacks = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let sources = [loginPath, ProcessInfo.processInfo.environment["PATH"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) }

        var seen = Set<String>()
        return (sources + fallbacks)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func field(_ marker: Marker, in output: String) -> String? {
        guard let start = output.range(of: marker.begin),
              let end = output.range(of: marker.end, range: start.upperBound..<output.endIndex) else {
            return nil
        }
        let value = String(output[start.upperBound..<end.lowerBound])
        return value.isEmpty ? nil : value
    }
}
