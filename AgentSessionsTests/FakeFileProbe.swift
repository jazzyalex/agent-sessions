import Foundation
@testable import AgentSessions

/// Test double for `FileProbing`: answers from a fixed set of paths instead of
/// the machine the suite happens to run on.
///
/// Declared at file scope, and `Sendable` without any actor isolation, so test
/// classes that are `@MainActor` can still hand it to non-isolated production
/// code — the same reason `PresenceFixtureRoots` lives at file scope.
struct FakeFileProbe: FileProbing {
    var directories: Set<String>
    var executables: Set<String>

    init(directories: Set<String> = [], executables: Set<String> = []) {
        self.directories = directories
        self.executables = executables
    }

    /// Convenience for the common case: every ancestor of `path` exists as a
    /// directory, and nothing else does. Mirrors how a real repo checkout looks
    /// to `inferCWDBestEffort`'s prefix walk.
    static func withDirectoryTree(upTo path: String) -> FakeFileProbe {
        var dirs: Set<String> = []
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            dirs.insert(prefix)
        }
        return FakeFileProbe(directories: dirs)
    }

    func directoryExists(atPath path: String) -> Bool { directories.contains(path) }
    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
}
