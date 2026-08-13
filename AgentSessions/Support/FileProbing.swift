import Foundation

/// Injectable seam over the filesystem existence checks that path decoding and
/// command building perform. The counterpart to `PresenceRootsResolving`: same
/// class of defect (production code reading the developer's real filesystem
/// with no way for a test to intercept it), different callers.
///
/// Both users below choose *what string to return* based on whether a path
/// happens to exist on the machine running the code, which silently couples
/// their unit tests to one developer's home directory:
///
///   - `CursorSessionParser.inferCWDBestEffort` walks candidate prefixes to
///     decide where a `-` is a path separator and where it is a literal hyphen,
///     so it decodes `Users-alexm-Repository-Codex-History` correctly only
///     where `/Users/alexm/Repository` exists. Elsewhere it returns
///     `/Users/alexm/Repository-Codex-History`.
///   - `AntigravityResumeCommandBuilder.makeCommand` emits the full binary path
///     when that path is executable and the bare command name when it is not,
///     so a test asserting the full path passes only where the binary is
///     installed at exactly that path.
///
/// `DefaultFileProbe` forwards to `FileManager.default`, so production behavior
/// is unchanged; tests inject a fake holding a fixed set of paths.
protocol FileProbing: Sendable {
    /// True when `path` exists *and* is a directory.
    func directoryExists(atPath path: String) -> Bool
    /// True when `path` exists and carries an executable bit for this process.
    func isExecutableFile(atPath path: String) -> Bool
}

/// The real filesystem. Bodies moved verbatim from the call sites.
struct DefaultFileProbe: FileProbing {
    init() {}

    func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
