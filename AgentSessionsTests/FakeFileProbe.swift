import Foundation
@testable import AgentSessions

/// Test double for `FileProbing`: answers from a fixed set of paths instead of
/// the machine the suite happens to run on.
///
/// Declared at file scope, and `Sendable` without any actor isolation, so test
/// classes that are `@MainActor` can still hand it to non-isolated production
/// code — the same reason `PresenceFixtureRoots` lives at file scope.
struct FakeFileProbe: FileProbing {
    var files: Set<String>
    var directories: Set<String>
    var executables: Set<String>
    var sqliteTablesByPath: [String: Set<String>]

    init(files: Set<String> = [],
         directories: Set<String> = [],
         executables: Set<String> = [],
         sqliteTablesByPath: [String: Set<String>] = [:]) {
        self.files = files
        self.directories = directories
        self.executables = executables
        self.sqliteTablesByPath = sqliteTablesByPath
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

    func fileExists(atPath path: String) -> Bool {
        files.contains(path) || directories.contains(path) || sqliteTablesByPath[path] != nil
    }
    func directoryExists(atPath path: String) -> Bool { directories.contains(path) }
    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(atPath path: String) -> [URL] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let childPaths = files
            .union(directories)
            .union(sqliteTablesByPath.keys)
            .filter { candidate in
                guard candidate.hasPrefix(prefix) else { return false }
                return !candidate.dropFirst(prefix.count).contains("/")
            }
        return childPaths.map { URL(fileURLWithPath: $0, isDirectory: directories.contains($0)) }
    }
    func descendantDirectories(named name: String,
                               atPath path: String,
                               skippingSubtreesNamed skippedNames: Set<String>) -> [URL] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return directories
            .filter { candidate in
                guard candidate.hasPrefix(prefix), URL(fileURLWithPath: candidate).lastPathComponent == name else {
                    return false
                }
                let parents = candidate.dropFirst(prefix.count).split(separator: "/").dropLast().map(String.init)
                return !parents.contains(where: skippedNames.contains)
            }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func sqliteDatabase(atPath path: String, containsTable table: String) -> Bool {
        sqliteTablesByPath[path]?.contains(table) == true
    }
}
