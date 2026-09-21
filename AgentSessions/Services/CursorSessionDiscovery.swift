import Foundation
import Darwin

/// Session discovery for Cursor agent transcripts and chat databases.
///
/// Cursor stores data in two locations:
/// - JSONL transcripts: `~/.cursor/projects/<project>/agent-transcripts/<uuid>/<uuid>.jsonl`
/// - Chat SQLite DBs: `~/.cursor/chats/<md5(projectPath)>/<sessionUUID>/store.db`
/// - ACP persisted sessions: `~/.cursor/acp-sessions/<sessionUUID>/store.db`
final class CursorSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

#if DEBUG
    /// Test-only seam after the ACP root has been descriptor-bound and before
    /// enumeration. Production discovery never mutates the configured root.
    static var boundACPRootHook: ((URL) -> Void)?
#endif

    private struct ACPDiscoveryCandidate {
        let url: URL
        let modifiedAt: Date
    }

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    /// Returns the projects root where agent-transcripts live.
    func sessionsRoot() -> URL {
        return CursorBackendDetector.projectsRoot(customRoot: customRoot)
    }

    /// Returns the chats root where per-session SQLite databases live.
    func chatsRoot() -> URL {
        return CursorBackendDetector.chatsRoot(customRoot: customRoot)
    }

    /// Returns the root containing Cursor ACP persisted sessions.
    func acpSessionsRoot() -> URL {
        CursorBackendDetector.acpSessionsRoot(customRoot: customRoot)
    }

    /// Returns the device/inode identity of the currently configured ACP root.
    /// Focused reloads use this as an authority token so a result read from a
    /// superseded root cannot be published after a root replacement or config
    /// transition.
    func acpSessionsRootIdentity() -> String? {
        guard isConfiguredRootCanonical(),
              let descriptor = openBoundDirectory(at: acpSessionsRoot()) else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        var fileStat = stat()
        guard Darwin.fstat(descriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return "\(fileStat.st_dev):\(fileStat.st_ino)"
    }

    /// The system temporary-directory alias `/var` resolves to `/private/var`
    /// on macOS. Treat that OS alias as canonical, but reject a user-supplied
    /// Cursor root whose own path resolves somewhere else.
    func isConfiguredRootCanonical() -> Bool {
        let root = CursorBackendDetector.cursorRoot(customRoot: customRoot)
        let raw = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        if raw == resolved { return true }

        for (alias, canonicalAlias) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            guard raw == alias || raw.hasPrefix(alias + "/") else { continue }
            let rewritten = canonicalAlias + String(raw.dropFirst(alias.count))
            if rewritten == resolved { return true }
        }
        return false
    }

    /// Discovers only canonical, non-symlink ACP stores.
    ///
    /// `[]` is an authoritative empty root. `nil` means the root could not be
    /// read or was not available, so callers must preserve the prior ACP
    /// projection instead of treating the failure as deletion.
    func discoverACPSessionDBs() -> [URL]? {
        let root = acpSessionsRoot()
        guard isConfiguredRootCanonical() else { return nil }
        guard let rootDescriptor = openBoundDirectory(at: root) else { return nil }
        defer { Darwin.close(rootDescriptor) }

#if DEBUG
        CursorSessionDiscovery.boundACPRootHook?(root)
#endif

        let duplicateDescriptor = Darwin.dup(rootDescriptor)
        guard duplicateDescriptor >= 0 else { return nil }
        guard let directoryStream = Darwin.fdopendir(duplicateDescriptor) else {
            Darwin.close(duplicateDescriptor)
            return nil
        }
        defer { Darwin.closedir(directoryStream) }

        let boundRoot = URL(fileURLWithPath: CursorBackendDetector.normalizedSystemAliasPath(root.path),
                            isDirectory: true)
        var candidates: [ACPDiscoveryCandidate] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directoryStream) else {
                guard errno == 0 else { return nil }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard UUID(uuidString: name) != nil else { continue }

            var childStat = stat()
            let childStatResult = name.withCString {
                Darwin.fstatat(rootDescriptor, $0, &childStat, AT_SYMLINK_NOFOLLOW)
            }
            guard childStatResult == 0 else {
                // The root descriptor is bound, but a child disappearing while
                // it is being inspected is still an indeterminate scan. Do not
                // turn that race into an authoritative empty result.
                return nil
            }
            guard (childStat.st_mode & S_IFMT) == S_IFDIR else { continue }

            let childDescriptor = name.withCString {
                Darwin.openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard childDescriptor >= 0 else {
                switch errno {
                case ELOOP, ENOTDIR:
                    continue
                default:
                    return nil
                }
            }
            defer { Darwin.close(childDescriptor) }

            let storeDescriptor = "store.db".withCString {
                Darwin.openat(childDescriptor, $0, O_RDONLY | O_NOFOLLOW)
            }
            guard storeDescriptor >= 0 else {
                // Cursor can publish the UUID directory before its database.
                // A symlink or non-directory store is a deterministic bad
                // candidate; other errors leave root authority indeterminate.
                switch errno {
                case ENOENT, ELOOP, ENOTDIR:
                    continue
                default:
                    return nil
                }
            }
            defer { Darwin.close(storeDescriptor) }

            var storeStat = stat()
            guard Darwin.fstat(storeDescriptor, &storeStat) == 0 else { return nil }
            guard (storeStat.st_mode & S_IFMT) == S_IFREG else { continue }

            switch CursorACPStoreReader.liveACPStoreAdmission(
                sessionDirectoryDescriptor: childDescriptor,
                storeDescriptor: storeDescriptor
            ) {
            case .valid:
                let sessionRoot = boundRoot.appendingPathComponent(name, isDirectory: true)
                candidates.append(ACPDiscoveryCandidate(
                    url: sessionRoot.appendingPathComponent("store.db", isDirectory: false),
                    modifiedAt: Date(timeIntervalSince1970:
                        TimeInterval(childStat.st_mtimespec.tv_sec)
                        + TimeInterval(childStat.st_mtimespec.tv_nsec) / 1_000_000_000)
                ))
            case .invalid:
                continue
            case .unavailable:
                // The candidate is present, but its structural admission could
                // not be completed. It is not authority to delete the prior
                // live projection.
                return nil
            }
        }

        // The returned URLs are later handed to parsers that receive paths,
        // while this method deliberately enumerates a bound descriptor. If the
        // pathname or any ancestor was replaced during the scan, reopen the
        // configured root component-by-component with O_NOFOLLOW and compare
        // its descriptor identity. A pathname-based lstat would follow a
        // substituted ancestor and could validate the wrong tree.
        var boundRootStat = stat()
        guard Darwin.fstat(rootDescriptor, &boundRootStat) == 0 else { return nil }
        guard let currentRootDescriptor = openBoundDirectory(at: boundRoot) else { return nil }
        defer { Darwin.close(currentRootDescriptor) }
        var currentRootStat = stat()
        guard Darwin.fstat(currentRootDescriptor, &currentRootStat) == 0,
              (currentRootStat.st_mode & S_IFMT) == S_IFDIR,
              currentRootStat.st_dev == boundRootStat.st_dev,
              currentRootStat.st_ino == boundRootStat.st_ino else { return nil }

        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.map(\.url)
    }

    private func openBoundDirectory(at url: URL) -> Int32? {
        let path = CursorBackendDetector.normalizedSystemAliasPath(url.path)
        guard path.hasPrefix("/") else { return nil }

        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { return nil }
        var currentDescriptor = rootDescriptor
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(component)
            let nextDescriptor = name.withCString {
                Darwin.openat(currentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(currentDescriptor)
                return nil
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    /// Discovers JSONL transcript files across all projects.
    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl",
                      url.path.contains("/agent-transcripts/") else { continue }
                found.append(url)
            }
        }

        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Discovers all store.db paths under the chats directory.
    func discoverChatDBs() -> [URL] {
        let root = chatsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "store.db" {
                    found.append(url)
                }
            }
        }
        return found
    }
}
