import Darwin
import Foundation

private enum OpenClawPathResolver {
    private static func isUsableEnvironmentValue(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.caseInsensitiveCompare("null") != .orderedSame
            && trimmed.caseInsensitiveCompare("undefined") != .orderedSame
    }

    private static func fallbackHome(environment: [String: String]) -> URL {
        let operatingSystemHome = FileManager.default.homeDirectoryForCurrentUser
        let rawHome: String? = {
            if let home = environment["HOME"], isUsableEnvironmentValue(home) {
                return home
            }
            if let userProfile = environment["USERPROFILE"],
               isUsableEnvironmentValue(userProfile) {
                return userProfile
            }
            return nil
        }()
        guard let rawHome else { return operatingSystemHome }
        return url(for: rawHome, relativeTo: nil, tildeHome: operatingSystemHome)
    }

    static func effectiveHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let fallback = fallbackHome(environment: environment)
        guard let rawHome = environment["OPENCLAW_HOME"],
              isUsableEnvironmentValue(rawHome) else {
            return fallback
        }
        return url(for: rawHome, relativeTo: nil, tildeHome: fallback)
    }

    static func profileSuffix(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let rawProfile = environment["OPENCLAW_PROFILE"] else { return "" }
        let profile = rawProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty else { return "" }
        if profile.caseInsensitiveCompare("default") == .orderedSame {
            return ""
        }
        let bytes = Array(profile.utf8)
        guard bytes.count <= 64,
              let first = bytes.first,
              isValidProfileByte(first, first: true),
              bytes.dropFirst().allSatisfy({ isValidProfileByte($0, first: false) }) else {
            return nil
        }
        return "-\(profile)"
    }

    private static func isValidProfileByte(_ byte: UInt8, first: Bool) -> Bool {
        let lowercased = byte >= 65 && byte <= 90 ? byte + 32 : byte
        if (lowercased >= 97 && lowercased <= 122)
            || (lowercased >= 48 && lowercased <= 57) {
            return true
        }
        return !first && (lowercased == 95 || lowercased == 45)
    }

    static func profileIsValid(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        profileSuffix(environment: environment) != nil
    }

    static func environmentURL(for key: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               tildeHome: URL) -> URL? {
        guard let rawValue = environment[key],
              isUsableEnvironmentValue(rawValue) else {
            return nil
        }
        return url(for: rawValue, relativeTo: nil, tildeHome: tildeHome)
    }

    static func hasUsableEnvironmentValue(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isUsableEnvironmentValue(environment[key])
    }

    static func url(for rawValue: String, relativeTo baseURL: URL?, tildeHome: URL) -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: URL
        if value == "~" {
            resolved = tildeHome
        } else if value.hasPrefix("~/") {
            resolved = tildeHome.appendingPathComponent(String(value.dropFirst(2)))
        } else if value.hasPrefix("/") {
            resolved = URL(fileURLWithPath: value)
        } else if let baseURL {
            resolved = baseURL.appendingPathComponent(value)
        } else {
            resolved = URL(fileURLWithPath: value)
        }
        return resolved.standardizedFileURL
    }
}

/// Discovery for OpenClaw (and legacy Clawdbot) JSONL session transcripts.
///
/// Expected layouts:
/// - ~/.openclaw/agents/<agentId>/sessions/*.jsonl
/// - ~/.clawdbot/agents/<agentId>/sessions/*.jsonl   (legacy)
/// - $OPENCLAW_STATE_DIR/agents/<agentId>/sessions/*.jsonl
/// - configured `agents.entries.*.agentDir` SQLite stores
final class OpenClawSessionDiscovery: SessionDiscovery, @unchecked Sendable {
    struct AgentDirectory: Equatable {
        let agentID: String
        let path: String

        init(agentID: String, path: String) {
            self.agentID = agentID
            self.path = path
        }
    }

    struct SessionDatabaseDiscoveryResult {
        let databases: [URL]
        /// Owner IDs resolved from the same config/filesystem snapshot as
        /// `databases`. Indexers must use this map instead of re-reading the
        /// mutable OpenClaw config during the same refresh.
        let agentIDsByPath: [String: String]
        let ambiguousDatabasePaths: Set<String>
        let isAuthoritative: Bool

        func agentID(forDatabaseURL url: URL) -> String? {
            let path = OpenClawSessionDiscovery.canonicalDatabasePath(for: url)
            guard !ambiguousDatabasePaths.contains(path) else { return nil }
            return agentIDsByPath[path]
        }

        func isOwnershipAmbiguous(forDatabaseURL url: URL) -> Bool {
            ambiguousDatabasePaths.contains(
                OpenClawSessionDiscovery.canonicalDatabasePath(for: url))
        }
    }

    private let customRoot: String?
    private let includeDeleted: Bool
    private let configuredAgentDirectoriesOverride: [AgentDirectory]?
    private var beforeDatabaseProbeHookForTesting: (() -> Void)?

    init(customRoot: String? = nil,
         includeDeleted: Bool = true,
         configuredAgentDirectories: [AgentDirectory]? = nil) {
        self.customRoot = customRoot
        self.includeDeleted = includeDeleted
        self.configuredAgentDirectoriesOverride = configuredAgentDirectories
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            return url
        }

        let environment = ProcessInfo.processInfo.environment
        let home = OpenClawPathResolver.effectiveHome(environment: environment)
        if let stateDirectory = OpenClawPathResolver.environmentURL(
            for: "OPENCLAW_STATE_DIR",
            environment: environment,
            tildeHome: home) {
            return stateDirectory
        }

        // OpenClaw's profile/home environment is part of the effective state
        // root. Discovery and config loading must agree on this one snapshot,
        // or an authoritative refresh can scan and retire the wrong profile.
        let profileSuffix = OpenClawPathResolver.profileSuffix(environment: environment)
        let openclaw = home.appendingPathComponent(
            ".openclaw\(profileSuffix ?? "")", isDirectory: true)
        switch stateRootProbe(openclaw) {
        case .present:
            return openclaw
        case .indeterminate:
            // Do not silently switch to another state root after an access or
            // stat failure in the preferred root.
            return openclaw
        case .absent:
            break
        }

        // Named OpenClaw profiles do not fall back to a legacy Clawdbot
        // profile with the same suffix. A missing/invalid profile must stay in
        // its own OpenClaw namespace and be treated as non-authoritative.
        if profileSuffix == "" {
            let clawdbot = home.appendingPathComponent(".clawdbot", isDirectory: true)
            switch stateRootProbe(clawdbot) {
            case .present:
                return clawdbot
            case .indeterminate:
                return clawdbot
            case .absent:
                break
            }
        }

        // Default to the canonical OpenClaw location even if it doesn't exist yet.
        return openclaw
    }

    func discoverSessionFiles() -> [URL] {
        // Newest first (mtime)
        return collectSessionFiles().files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.lastPathComponent > $1.lastPathComponent
        }
    }

    /// Current OpenClaw stores one SQLite database per agent. Keep this
    /// separate from the JSONL file list because one database contains many
    /// sessions and therefore cannot be handed to the file-indexing parser as
    /// one session.
    func discoverSessionDatabases() -> [URL] {
        discoverSessionDatabaseResult().databases
    }

    /// A valid empty configuration is different from a configuration that
    /// could not be read. Callers must not retire previously indexed external
    /// stores after the latter.
    func discoverSessionDatabaseResult() -> SessionDatabaseDiscoveryResult {
        let root = sessionsRoot()
        let stateRoot = stateRootURL(for: root)
        let fm = FileManager.default
        let profileIsValid = customRoot != nil
            || OpenClawPathResolver.profileIsValid()
        let configuredDirectories = configuredAgentDirectories(stateRoot: stateRoot)
        let configuredAgentIDs = Set(configuredDirectories.directories.map(\.agentID))
        var candidatesByPath: [String: URL] = [:]
        var agentIDsByPath: [String: String] = [:]
        var ambiguousDatabasePaths = Set<String>()
        enum OwnerKind {
            case inferred
            case configured
        }
        var ownerKindsByPath: [String: OwnerKind] = [:]
        var conflictingDatabaseOwners = false
        var inferredAgentsSuppressedByConfiguration = Set<String>()
        func addCandidate(_ lexicalURL: URL,
                          canonicalURL: URL? = nil,
                          agentID: String?,
                          ownerKind: OwnerKind) {
            // A probed database carries the canonical URL captured by the
            // probe's final symlink-binding check. Do not resolve the lexical
            // URL again here: doing so re-opens a TOCTOU window after the
            // authority proof has completed.
            let normalized = (canonicalURL ?? Self.canonicalDatabaseURL(for: lexicalURL))
                .standardizedFileURL
            let path = normalized.path
            guard let agentID, !agentID.isEmpty else { return }
            candidatesByPath[path] = normalized
            if case .inferred = ownerKind, configuredAgentIDs.contains(agentID) {
                // An explicit agentDir is the effective store for that agent.
                // Do not keep an obsolete default-layout database alive beside
                // the configured store (or resurrect it when the configured
                // store is temporarily absent).
                inferredAgentsSuppressedByConfiguration.insert(agentID)
                candidatesByPath.removeValue(forKey: path)
                return
            }
            switch (ownerKindsByPath[path], ownerKind) {
            case (.some(.configured), .inferred):
                // An explicit config entry is authoritative over a directory
                // name inferred from the default layout.
                return
            case (.some(.configured), .configured):
                if agentIDsByPath[path] != agentID {
                    conflictingDatabaseOwners = true
                    ambiguousDatabasePaths.insert(path)
                }
            case (.some(.inferred), .configured):
                agentIDsByPath[path] = agentID
                ownerKindsByPath[path] = .configured
            case (.some(.inferred), .inferred):
                if agentIDsByPath[path] != agentID {
                    // Two default-layout names resolving to one physical
                    // database are conflicting provenance. Enumeration order
                    // must not decide which identity gets minted.
                    conflictingDatabaseOwners = true
                    ambiguousDatabasePaths.insert(path)
                }
                return
            case (.none, _):
                agentIDsByPath[path] = agentID
                ownerKindsByPath[path] = ownerKind
            }
        }
        var filesystemAuthoritative = true
        if root.lastPathComponent == "openclaw-agent.sqlite" {
            if let agentID = Self.defaultAgentID(forDatabaseURL: root) {
                addCandidate(root, agentID: agentID, ownerKind: .inferred)
            } else {
                // An inferred owner is part of the authority proof. An
                // ownerless root must not be returned as a candidate that can
                // later mint an identity from its path.
                filesystemAuthoritative = false
            }
        } else {
            let agentsRoot: URL = {
                if root.lastPathComponent == "agents" { return root }
                return root.appendingPathComponent("agents", isDirectory: true)
            }()
            let expectedAgentsRootBindings = Self.symlinkBindingsAlongPath(at: agentsRoot)
            switch Self.directoryProbe(at: agentsRoot) {
            case .present:
                guard Self.symlinkBindingsAlongPath(at: agentsRoot) == expectedAgentsRootBindings else {
                    filesystemAuthoritative = false
                    break
                }
                do {
                    // FileManager's recursive enumerator does not descend into
                    // symlinked agent directories. Enumerate the known
                    // `agents/<id>/agent/` boundary directly so aliases retain
                    // their lexical owner before canonicalization detects that
                    // they resolve to one physical database.
                    let agentDirectories = try fm.contentsOfDirectory(
                        at: agentsRoot,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles])
                    guard Self.symlinkBindingsAlongPath(at: agentsRoot) == expectedAgentsRootBindings else {
                        filesystemAuthoritative = false
                        break
                    }
                    for agentDirectory in agentDirectories {
                        guard Self.symlinkBindingsAlongPath(at: agentsRoot) == expectedAgentsRootBindings else {
                            filesystemAuthoritative = false
                            break
                        }
                        let expectedAgentBindings = Self.symlinkBindingsAlongPath(
                            at: agentDirectory)
                        switch Self.directoryProbe(at: agentDirectory) {
                        case .absent:
                            continue
                        case .indeterminate:
                            filesystemAuthoritative = false
                            continue
                        case .present:
                            break
                        }

                        guard Self.symlinkBindingsAlongPath(at: agentDirectory) == expectedAgentBindings else {
                            filesystemAuthoritative = false
                            continue
                        }

                        let url = agentDirectory
                            .appendingPathComponent("agent", isDirectory: true)
                            .appendingPathComponent("openclaw-agent.sqlite")
                        let expectedDatabaseBindings = Self.symlinkBindingsAlongPath(at: url)
                        guard Self.symlinkBindingsAlongPath(at: agentsRoot) == expectedAgentsRootBindings else {
                            filesystemAuthoritative = false
                            break
                        }

                        beforeDatabaseProbeHookForTesting?()
                        let probe = Self.regularFileProbe(
                            at: url,
                            expectedBindings: expectedDatabaseBindings)
                        guard case let .present(canonicalURL) = probe else {
                            if case .indeterminate = probe { filesystemAuthoritative = false }
                            continue
                        }
                        guard let agentID = Self.defaultAgentID(forDatabaseURL: url) else {
                            // Keep scanning other stores, but do not let this
                            // ownerless candidate make the snapshot authoritative.
                            filesystemAuthoritative = false
                            continue
                        }
                        addCandidate(url,
                                     canonicalURL: canonicalURL,
                                     agentID: agentID,
                                     ownerKind: .inferred)
                    }
                    if Self.symlinkBindingsAlongPath(at: agentsRoot) != expectedAgentsRootBindings {
                        filesystemAuthoritative = false
                    }
                } catch {
                    filesystemAuthoritative = false
                }
            case .absent:
                break
            case .indeterminate:
                filesystemAuthoritative = false
            }
        }

        // `agentDir` may be outside the state tree. The configured directory is
        // authoritative for both the database location and the agent identity;
        // do not infer an ID from an arbitrary external path.
        var configuredStorageAuthoritative = true
        for configured in configuredDirectories.directories {
            let directory = URL(fileURLWithPath: configured.path, isDirectory: true)
            let database = directory.appendingPathComponent("openclaw-agent.sqlite")
            switch Self.regularFileProbe(at: database) {
            case let .present(canonicalURL):
                addCandidate(database,
                             canonicalURL: canonicalURL,
                             agentID: configured.agentID,
                             ownerKind: .configured)
            case .absent:
                // Any explicitly configured store may be in the middle of a
                // move, including one external-store path changing to another
                // external-store path. Do not authorize retirement of the old
                // store until the configured replacement is observed.
                configuredStorageAuthoritative = false
                continue
            case .indeterminate:
                configuredStorageAuthoritative = false
            }
        }

        // A config file was present but could not be validated or parsed into
        // an ownership roster. Keep discovered rows available for the caller
        // to preserve, but mark every inferred path ambiguous so no caller can
        // mint an identity from an untrusted partial snapshot.
        if !configuredDirectories.isAuthoritative {
            ambiguousDatabasePaths.formUnion(candidatesByPath.keys)
        }

        let isAuthoritative = filesystemAuthoritative
            && configuredDirectories.isAuthoritative
            && configuredStorageAuthoritative
            && profileIsValid
            && !conflictingDatabaseOwners
        let safeAgentIDsByPath = agentIDsByPath.filter {
            !ambiguousDatabasePaths.contains($0.key)
        }
        return SessionDatabaseDiscoveryResult(
            databases: candidatesByPath.values.sorted { $0.path < $1.path },
            agentIDsByPath: safeAgentIDsByPath,
            ambiguousDatabasePaths: ambiguousDatabasePaths,
            isAuthoritative: isAuthoritative)
    }

    /// Returns the configured owner for an external database, or the stable
    /// default-layout owner inferred from `agents/<agentId>/agent/`.
    func agentID(forDatabaseURL url: URL) -> String? {
        discoverSessionDatabaseResult().agentID(forDatabaseURL: url)
    }

    func setBeforeDatabaseProbeHookForTesting(_ hook: (() -> Void)?) {
        beforeDatabaseProbeHookForTesting = hook
    }

    func discoverDelta(previousByPath: [String: SessionFileStat]) -> SessionDiscoveryDelta {
        // Use unsorted collection — diff doesn't need ordering, and we only sort
        // the smaller changedFiles slice rather than all files.
        let collection = collectSessionFiles()
        let files = collection.files
        let (currentByPath, changedFiles) = SessionFileStat.diff(files, against: previousByPath)
        let removedPaths = collection.hadEnumerationError
            ? []
            : Array(Set(previousByPath.keys).subtracting(currentByPath.keys))
        return SessionDiscoveryDelta(
            changedFiles: changedFiles.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            },
            removedPaths: removedPaths,
            currentByPath: currentByPath,
            driftDetected: collection.hadEnumerationError
        )
    }

    /// Collects all session files without sorting. Callers that need a specific
    /// order should sort the result themselves.
    private struct CollectedSessionFiles {
        let files: [URL]
        let hadEnumerationError: Bool
    }

    private func collectSessionFiles() -> CollectedSessionFiles {
        let root = sessionsRoot()
        let fm = FileManager.default

        let agentsRoot: URL = {
            if root.lastPathComponent == "agents" { return root }
            return root.appendingPathComponent("agents", isDirectory: true)
        }()

        switch Self.directoryProbe(at: agentsRoot) {
        case .absent:
            return CollectedSessionFiles(files: [], hadEnumerationError: false)
        case .indeterminate:
            return CollectedSessionFiles(files: [], hadEnumerationError: true)
        case .present:
            break
        }

        var found: [URL] = []
        var hadEnumerationError = customRoot == nil
            && !OpenClawPathResolver.profileIsValid()
        guard let enumerator = fm.enumerator(
            at: agentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                hadEnumerationError = true
                return false
            }) else {
            return CollectedSessionFiles(files: [], hadEnumerationError: true)
        }
        for case let url as URL in enumerator {
                guard url.lastPathComponent == "sessions" else { continue }

                switch Self.directoryProbe(at: url) {
                case .absent:
                    continue
                case .indeterminate:
                    hadEnumerationError = true
                    continue
                case .present:
                    break
                }

                if let sessionEnum = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                    errorHandler: { _, _ in
                        hadEnumerationError = true
                        return false
                    }) {
                    for case let file as URL in sessionEnum {
                        let name = file.lastPathComponent
                        if name.hasSuffix(".jsonl.lock") { continue }
                        if name.hasSuffix(".trajectory.jsonl") { continue }
                        if name.hasSuffix(".jsonl") {
                            found.append(file)
                            continue
                        }
                        if includeDeleted, name.contains(".jsonl.deleted.") {
                            found.append(file)
                        }
                    }
                } else {
                    hadEnumerationError = true
                }
        }
        return CollectedSessionFiles(files: found, hadEnumerationError: hadEnumerationError)
    }

    private enum DirectoryProbe: Equatable {
        case present
        case absent
        case indeterminate
    }

    private static func isMissingPathError(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == Int(POSIXErrorCode.ENOENT.rawValue)
            || code == NSFileNoSuchFileError
            || code == NSFileReadNoSuchFileError
    }

    private struct LexicalSymlinkBinding: Equatable {
        let lexicalPath: String
        let resolvedPath: String
    }

    /// Capture every symlink component, not only the final path component.
    /// The known OpenClaw layout can be reached through an `agents/<id>` alias,
    /// so checking only `.../agent` misses a link that disappears between the
    /// directory listing and the database probe.
    private static func symlinkBindingsAlongPath(at url: URL) -> [LexicalSymlinkBinding] {
        let standardized = url.standardizedFileURL
        var prefix = URL(fileURLWithPath: "/", isDirectory: true)
        var bindings: [LexicalSymlinkBinding] = []
        for component in standardized.pathComponents where component != "/" {
            prefix.appendPathComponent(component)
            if isLexicalSymlink(at: prefix) {
                bindings.append(LexicalSymlinkBinding(
                    lexicalPath: prefix.path,
                    resolvedPath: prefix.resolvingSymlinksInPath().standardizedFileURL.path))
            }
        }
        return bindings
    }

    private static func directoryProbe(at url: URL) -> DirectoryProbe {
        let initialBindings = symlinkBindingsAlongPath(at: url)
        let result: DirectoryProbe
        if !initialBindings.isEmpty {
            // Preserve the lexical owner while following the final alias for
            // the presence check. A broken or unreadable alias is
            // indeterminate so discovery cannot authorize destructive
            // retirement from a transient symlink failure.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            do {
                let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
                guard let isDirectory = values.isDirectory else {
                    result = .indeterminate
                    return result
                }
                result = isDirectory ? .present : .absent
            } catch {
                result = Self.isMissingPathError(error)
                    ? (Self.symlinkTargetsAreReachable(initialBindings)
                        ? .absent : .indeterminate)
                    : .indeterminate
            }
        } else {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard let isDirectory = values.isDirectory else {
                    result = .indeterminate
                    return result
                }
                result = isDirectory ? .present : .absent
            } catch {
                result = isMissingPathError(error) ? .absent : .indeterminate
            }
        }
        guard symlinkBindingsAlongPath(at: url) == initialBindings else { return .indeterminate }
        return result
    }

    private func stateRootProbe(_ url: URL) -> DirectoryProbe {
        // The state directory itself is the authority boundary. It may be
        // valid with only external configured agentDirs and no local agents/.
        Self.directoryProbe(at: url)
    }

    private func stateRootURL(for root: URL) -> URL {
        root.lastPathComponent == "agents"
            ? root.deletingLastPathComponent()
            : root
    }

    private static func canonicalDatabaseURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func canonicalDatabasePath(for url: URL) -> String {
        canonicalDatabaseURL(for: url).path
    }

    private enum DatabaseProbe: Equatable {
        case present(URL)
        case absent
        case indeterminate
    }

    private static func regularFileProbe(
        at url: URL,
        expectedBindings: [LexicalSymlinkBinding]? = nil
    ) -> DatabaseProbe {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        let initialBindings = symlinkBindingsAlongPath(at: url)
        if let expectedBindings {
            guard initialBindings == expectedBindings else { return .indeterminate }
        }
        let listingIsPresent: Bool
        do {
            let names = try fileManager.contentsOfDirectory(atPath: parent.path)
            listingIsPresent = names.contains(url.lastPathComponent)
        } catch {
            return Self.isMissingPathError(error)
                && (initialBindings.isEmpty
                    || Self.symlinkTargetsAreReachable(initialBindings))
                ? .absent : .indeterminate
        }
        guard symlinkBindingsAlongPath(at: url) == initialBindings else { return .indeterminate }
        guard listingIsPresent else { return .absent }

        let probeURL = isLexicalSymlink(at: url)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url
        do {
            let values = try probeURL.resourceValues(forKeys: [.isRegularFileKey])
            guard let isRegularFile = values.isRegularFile else {
                return .indeterminate
            }
            guard isRegularFile else { return .absent }
        } catch {
            return Self.isMissingPathError(error)
                && (initialBindings.isEmpty
                    || Self.symlinkTargetsAreReachable(initialBindings))
                ? .absent : .indeterminate
        }
        guard symlinkBindingsAlongPath(at: url) == initialBindings else { return .indeterminate }

        // Capture the canonical target before returning the proof. Callers
        // must use this URL directly rather than resolving `url` again.
        let canonicalURL = canonicalDatabaseURL(for: url)
        guard symlinkBindingsAlongPath(at: url) == initialBindings else {
            return .indeterminate
        }
        return .present(canonicalURL)
    }

    private static func isLexicalSymlink(at url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return true
        }
        // Preserve detection for a broken final link, where ordinary resource
        // values may throw ENOENT.
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func symlinkTargetsAreReachable(
        _ bindings: [LexicalSymlinkBinding]
    ) -> Bool {
        bindings.allSatisfy {
            FileManager.default.fileExists(atPath: $0.resolvedPath)
        }
    }

    private static func defaultAgentID(forDatabaseURL url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard let agentsIndex = parts.lastIndex(of: "agents"),
              agentsIndex + 1 < parts.count else { return nil }
        return normalizeAgentID(parts[agentsIndex + 1])
    }

    private static func normalizeAgentID(_ rawID: String) -> String? {
        let bytes = Array(rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        guard !bytes.isEmpty else { return nil }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(min(bytes.count, 64))
        for byte in bytes {
            let allowed = (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 95
                || byte == 45
            if allowed {
                normalized.append(byte)
            } else if normalized.last != 45 {
                normalized.append(45)
            }
        }
        while normalized.first == 45 { normalized.removeFirst() }
        while normalized.last == 45 { normalized.removeLast() }
        guard !normalized.isEmpty, normalized.count <= 64 else { return nil }
        return String(bytes: normalized, encoding: .utf8)
    }

    private struct ConfiguredAgentDirectories {
        let directories: [AgentDirectory]
        let isAuthoritative: Bool
    }

    private func configuredAgentDirectories(stateRoot: URL) -> ConfiguredAgentDirectories {
        if let configuredAgentDirectoriesOverride {
            var seenAgentIDs = Set<String>()
            var normalizedDirectories: [AgentDirectory] = []
            for directory in configuredAgentDirectoriesOverride {
                guard let agentID = Self.normalizeAgentID(directory.agentID),
                      seenAgentIDs.insert(agentID).inserted else {
                    return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
                }
                normalizedDirectories.append(
                    AgentDirectory(agentID: agentID, path: directory.path))
            }
            return ConfiguredAgentDirectories(directories: normalizedDirectories,
                                              isAuthoritative: true)
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        let home = OpenClawPathResolver.effectiveHome(environment: processEnvironment)
        let configCandidates: [URL]
        let hasExplicitConfigPath = OpenClawPathResolver.hasUsableEnvironmentValue(
            for: "OPENCLAW_CONFIG_PATH",
            environment: processEnvironment)
        if hasExplicitConfigPath {
            guard let configuredPath = OpenClawPathResolver.environmentURL(
                for: "OPENCLAW_CONFIG_PATH",
                environment: processEnvironment,
                tildeHome: home) else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
            configCandidates = [configuredPath]
        } else {
            let legacyFirst = stateRoot.lastPathComponent.hasPrefix(".clawdbot")
            let names = legacyFirst
                ? ["clawdbot.json", "openclaw.json"]
                : ["openclaw.json", "clawdbot.json"]
            configCandidates = names.map {
                stateRoot.appendingPathComponent($0)
            }
        }

        var configURL: URL?
        for candidate in configCandidates {
            switch Self.regularFileProbe(at: candidate) {
            case .present(_):
                configURL = candidate
            case .absent:
                if hasExplicitConfigPath {
                    return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
                }
                continue
            case .indeterminate:
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
            if configURL != nil { break }
        }
        guard let configURL else {
            return ConfiguredAgentDirectories(directories: [], isAuthoritative: true)
        }
        guard let loaded = OpenClawConfigLoader.loadObjectWithSources(
            at: configURL,
            stateRoot: stateRoot) else {
            return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
        }
        let root = loaded.value
        let binaryOverride = UserDefaults.standard.string(
            forKey: PreferencesKey.Paths.openClawBinaryOverride)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let validation: OpenClawConfigLoader.ValidationSnapshot?
        if customRoot == nil || binaryOverride != nil {
            guard let validated = OpenClawConfigLoader.validateSchema(
                at: configURL,
                stateRoot: stateRoot,
                sourceRevisions: loaded.sourceRevisions,
                sourceBindings: loaded.sourceBindings,
                environment: loaded.environment,
                validatorEnvironment: loaded.validatorEnvironment) else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
            validation = validated
        } else {
            // The installed CLI validates the canonical OpenClaw state root,
            // but treats an arbitrary caller-supplied root as an incomplete
            // profile and may block while it resolves plugins. The local
            // parser still proves JSON5/include stability and validates the
            // ownership shape below. An explicit binary override opts back
            // into the external validator for callers that require it.
            validation = nil
        }

        // The locally parsed object and the validator must describe the same
        // config/include snapshot. A changed source is retryable, never an
        // authoritative empty or partial ownership map.
        if let validation {
            guard validation.isCurrent(configURL: configURL,
                                       stateRoot: stateRoot,
                                       sourceRevisions: loaded.sourceRevisions) else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
        }

        guard let rawAgents = root["agents"] else {
            if let validation {
                guard validation.isCurrent(configURL: configURL,
                                           stateRoot: stateRoot,
                                           sourceRevisions: loaded.sourceRevisions) else {
                    return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
                }
            }
            return ConfiguredAgentDirectories(directories: [], isAuthoritative: true)
        }
        guard let agents = rawAgents as? [String: Any] else {
            return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
        }

        let entriesResult: (entries: [(String, [String: Any])], isValid: Bool)
        if let rawEntries = agents["entries"] {
            guard let currentEntries = rawEntries as? [String: Any] else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
            var entries: [(String, [String: Any])] = []
            var seenAgentIDs = Set<String>()
            var isValid = true
            for (rawID, rawEntry) in currentEntries {
                guard let agentID = Self.normalizeAgentID(rawID),
                      let entry = rawEntry as? [String: Any],
                      seenAgentIDs.insert(agentID).inserted else {
                    isValid = false
                    continue
                }
                entries.append((agentID, entry))
            }
            entriesResult = (entries, isValid)
        } else if let rawList = agents["list"] {
            if let legacyList = rawList as? [Any] {
                var entries: [(String, [String: Any])] = []
                var seenAgentIDs = Set<String>()
                var isValid = true
                for rawEntry in legacyList {
                    guard let entry = rawEntry as? [String: Any] else {
                        isValid = false
                        continue
                    }
                    let rawID = (entry["id"] as? String)
                        ?? (entry["agentId"] as? String)
                        ?? (entry["agent_id"] as? String)
                    guard let rawID else {
                        isValid = false
                        continue
                    }
                    guard let agentID = Self.normalizeAgentID(rawID),
                          seenAgentIDs.insert(agentID).inserted else {
                        isValid = false
                        continue
                    }
                    entries.append((agentID, entry))
                }
                entriesResult = (entries, isValid)
            } else if let legacyMap = rawList as? [String: Any] {
                var entries: [(String, [String: Any])] = []
                var seenAgentIDs = Set<String>()
                var isValid = true
                for (rawID, rawEntry) in legacyMap {
                    guard let agentID = Self.normalizeAgentID(rawID),
                          let entry = rawEntry as? [String: Any],
                          seenAgentIDs.insert(agentID).inserted else {
                        isValid = false
                        continue
                    }
                    entries.append((agentID, entry))
                }
                entriesResult = (entries, isValid)
            } else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
        } else {
            entriesResult = ([], true)
        }

        guard entriesResult.isValid else {
            return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
        }

        let environment = OpenClawConfigLoader.effectiveEnvironment(
            baseEnvironment: validation?.environment ?? loaded.environment,
            root: root)
        var directories: [AgentDirectory] = []
        var resolutionFailed = false
        for (agentID, entry) in entriesResult.entries {
            guard let rawValue = entry["agentDir"] else {
                continue
            }
            guard let rawPath = rawValue as? String,
                  !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                resolutionFailed = true
                continue
            }
            guard let expandedEnvironmentPath = OpenClawConfigLoader.expandEnvironmentVariables(
                rawPath,
                environment: environment) else {
                resolutionFailed = true
                continue
            }
            let path = OpenClawPathResolver.url(
                for: expandedEnvironmentPath,
                relativeTo: nil,
                tildeHome: home).path
            directories.append(AgentDirectory(agentID: agentID, path: path))
        }
        if let validation {
            guard validation.isCurrent(configURL: configURL,
                                       stateRoot: stateRoot,
                                       sourceRevisions: loaded.sourceRevisions) else {
                return ConfiguredAgentDirectories(directories: [], isAuthoritative: false)
            }
        }
        return ConfiguredAgentDirectories(
            directories: directories.sorted { $0.agentID < $1.agentID },
            isAuthoritative: !resolutionFailed)
    }
}

/// OpenClaw configuration is JSON5, not strict JSON. Keep this small parser
/// local to discovery so agentDir support does not depend on a second config
/// implementation or silently ignore valid comments, trailing commas, and
/// `$include` overlays.
private enum OpenClawConfigLoader {
    private static let maxIncludeDepth = 10
    private static let maxConfigFileBytes: UInt64 = 2 * 1024 * 1024
    private static let maxIncludePathBytes = 4096

    // Keep this list aligned with OpenClaw's workspace-dotenv trust boundary.
    // Workspace files may provide ordinary project variables, but must not
    // promote credentials, routing overrides, or security switches into the
    // validator's process environment.
    private static let blockedWorkspaceDotEnvKeys: Set<String> = [
        "AI_GATEWAY_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN",
        "ANTHROPIC_ADMIN_API_KEY", "ANTHROPIC_ADMIN_KEY", "BASETEN_API_KEY",
        "ARCEEAI_API_KEY", "AZURE_OPENAI_API_KEY", "AZURE_SPEECH_API_KEY",
        "AZURE_SPEECH_KEY", "AZURE_SPEECH_REGION", "BRAVE_API_KEY",
        "BYTEPLUS_API_KEY", "BYTEPLUS_SEED_SPEECH_API_KEY", "CEREBRAS_API_KEY",
        "CLAWROUTER_API_KEY", "CODEX_API_KEY", "COHERE_API_KEY",
        "CHUTES_API_KEY", "CHUTES_OAUTH_TOKEN", "CLOUDFLARE_AI_GATEWAY_API_KEY",
        "COMFY_API_KEY", "COMFY_CLOUD_API_KEY", "COPILOT_GITHUB_TOKEN",
        "DASHSCOPE_API_KEY", "DEEPGRAM_API_KEY", "DEEPINFRA_API_KEY",
        "DEEPSEEK_API_KEY", "ELEVENLABS_API_KEY", "EXA_API_KEY", "FAL_API_KEY",
        "FAL_KEY", "FIRECRAWL_API_KEY", "FIREWORKS_API_KEY", "GEMINI_API_KEY",
        "GH_TOKEN", "GITHUB_TOKEN", "GOOGLE_API_KEY", "GOOGLE_CLOUD_API_KEY",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GRADIUM_API_KEY", "GROQ_API_KEY", "HF_TOKEN", "HUGGINGFACE_HUB_TOKEN",
        "INWORLD_API_KEY", "KILOCODE_API_KEY", "KIMICODE_API_KEY", "KIMI_API_KEY",
        "LITELLM_API_KEY", "LM_API_TOKEN", "MINIMAX_API_KEY",
        "MINIMAX_CODE_PLAN_KEY", "MINIMAX_CODING_API_KEY", "MINIMAX_OAUTH_TOKEN",
        "MISTRAL_API_KEY", "MODEL_API_KEY", "MODELSTUDIO_API_KEY",
        "MOONSHOT_API_KEY", "NVIDIA_API_KEY", "OLLAMA_API_KEY", "OPENAI_API_KEY",
        "OPENAI_ADMIN_KEY",
        "OPENCODE_API_KEY", "OPENCODE_ZEN_API_KEY", "OPENROUTER_API_KEY",
        "PARALLEL_API_KEY", "PERPLEXITY_API_KEY", "QIANFAN_API_KEY", "QWEN_API_KEY",
        "QWEN_TOKEN_PLAN_API_KEY", "RUNWAY_API_KEY", "RUNWAYML_API_SECRET",
        "SENSEAUDIO_API_KEY", "SGLANG_API_KEY", "SPEECH_KEY", "SPEECH_REGION",
        "STEPFUN_API_KEY", "SYNTHETIC_API_KEY", "TAVILY_API_KEY", "TOGETHER_API_KEY",
        "TOKENHUB_API_KEY", "TOKENPLAN_API_KEY", "VENICE_API_KEY", "VLLM_API_KEY",
        "VOLCANO_ENGINE_API_KEY", "VOLCENGINE_TTS_API_KEY", "VOLCENGINE_TTS_APPID",
        "VOLCENGINE_TTS_TOKEN", "VOYAGE_API_KEY", "VYDRA_API_KEY", "XAI_API_KEY",
        "XIAOMI_API_KEY", "XIAOMI_TOKEN_PLAN_API_KEY", "XI_API_KEY", "ZAI_API_KEY", "Z_AI_API_KEY",
        "ALL_PROXY", "BROWSER_EXECUTABLE_PATH", "CLAWHUB_AUTH_TOKEN",
        "CLAWHUB_CONFIG_PATH", "CLAWHUB_TOKEN", "CLAWHUB_URL", "COMSPEC",
        "DISCORD_API_URL", "HTTP_PROXY", "HTTPS_PROXY", "HOMEBREW_BREW_FILE",
        "HOMEBREW_CURL_PATH", "HOMEBREW_GIT_PATH", "HOMEBREW_PREFIX", "IRC_HOST",
        "APPDATA", "LOCALAPPDATA", "MATTERMOST_URL", "NODE_TLS_REJECT_UNAUTHORIZED",
        "NO_PROXY", "NPM_CONFIG_PREFIX", "NPM_EXECPATH", "OPENAI_API_KEYS", "PATH",
        "PI_CODING_AGENT_DIR", "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH", "PNPM_HOME", "PROGRAMFILES",
        "PROGRAMFILES(X86)", "PROGRAMW6432", "STATE_DIRECTORY", "AWS_ACCESS_KEY_ID",
        "AWS_ACCOUNT_ID", "AWS_ACCOUNT_ID_ENDPOINT_MODE", "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_BEDROCK_SKIP_AUTH", "AWS_CONFIG_FILE", "AWS_CREDENTIAL_EXPIRATION",
        "AWS_CREDENTIAL_SCOPE", "AWS_EC2_METADATA_DISABLED",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT", "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
        "AWS_EC2_METADATA_V1_DISABLED", "AWS_ENDPOINT_URL", "AWS_PROFILE",
        "AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME", "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN", "AWS_SHARED_CREDENTIALS_FILE", "AWS_WEB_IDENTITY_TOKEN_FILE",
        "BUZZ_RELAY_URL", "NODE_OPTIONS", "NODE_PATH", "NODE_REDIRECT_WARNINGS",
        "NODE_REPL_EXTERNAL_MODULE", "NODE_REPL_HISTORY", "NODE_V8_COVERAGE",
        "PYTHONHOME", "PYTHONPATH", "PERL5LIB", "PERL5OPT", "RUBYLIB", "RUBYOPT",
        "BASHOPTS", "BASH_ENV", "ENV", "KSH_ENV", "BROWSER", "GIT_ALLOW_PROTOCOL",
        "GIT_EDITOR", "GIT_EXTERNAL_DIFF", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR",
        "GIT_EXEC_PATH", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PROTOCOL_FROM_USER",
        "GIT_SEQUENCE_EDITOR", "GIT_TEMPLATE_DIR", "GIT_SSL_NO_VERIFY", "GIT_SSL_CAINFO",
        "GIT_SSL_CAPATH", "CC", "CPP", "CXX", "CXXCPP", "CARGO_BUILD_RUSTC",
        "CARGO_BUILD_RUSTC_WRAPPER", "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
        "CARGO_BUILD_RUSTDOC", "RUSTC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER",
        "RUSTDOC", "CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER", "SHELL", "SHELLOPTS",
        "PS4", "GCONV_PATH", "IFS", "SSLKEYLOGFILE", "JAVA_OPTS", "JAVA_TOOL_OPTIONS",
        "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "PYTHONBREAKPOINT", "DOTNET_STARTUP_HOOKS",
        "DOTNET_ADDITIONAL_DEPS", "FPATH", "GLIBC_TUNABLES", "MAVEN_OPTS", "MAKE",
        "MAKEFLAGS", "MFLAGS", "SBT_OPTS", "GRADLE_OPTS", "ANT_OPTS", "HGRCPATH",
        "HGEDITOR", "HGMERGE", "EXINIT", "VIMINIT", "MYVIMRC", "GVIMINIT", "LUA_INIT",
        "LUA_INIT_5_1", "LUA_INIT_5_2", "LUA_INIT_5_3", "LUA_INIT_5_4", "EMACSLOADPATH",
        "RUBYSHELL", "GIT_HOOK_PATH", "SVN_EDITOR", "SVN_SSH", "BZR_EDITOR", "BZR_SSH",
        "BZR_PLUGIN_PATH", "SUDO_ASKPASS", "JULIA_EDITOR", "CONFIG_SITE", "CONFIG_SHELL",
        "CMAKE_TOOLCHAIN_FILE", "CATALINA_OPTS", "CORECLR_PROFILER", "HELM_PLUGINS",
        "PACKER_PLUGIN_PATH", "VAGRANT_VAGRANTFILE", "ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS",
        "ELIXIR_ERL_OPTIONS", "R_ENVIRON", "R_PROFILE", "R_ENVIRON_USER", "R_PROFILE_USER",
        "TCLLIBPATH", "HOSTALIASES", "SMS_ALLOWED_USERS",
        "SMS_DANGEROUSLY_DISABLE_SIGNATURE_VALIDATION", "SMS_PUBLIC_WEBHOOK_URL",
        "SLACK_API_URL", "SYNOLOGY_CHAT_INCOMING_URL", "SYNOLOGY_ALLOWED_USER_IDS",
        "SYNOLOGY_NAS_HOST", "UV_PYTHON", "ZALO_API_URL"
    ]
    private static let blockedWorkspaceDotEnvPrefixes = [
        "ANTHROPIC_API_KEY_", "CLAWHUB_", "CLOUDSDK_", "AWS_CONTAINER_",
        "AWS_ENDPOINT_URL_", "OPENAI_API_KEY_", "OCM_", "OPENCLAW_",
        "DYLD_", "LD_", "BASH_FUNC_"
    ]
    // OpenClaw applies the host-env override policy to workspace dotenv too.
    // Keep this second set separate from blockedEverywhereKeys: these names
    // are allowed in trusted inherited environments but are unsafe when a
    // workspace file tries to override the validator's runtime.
    private static let blockedWorkspaceDotEnvOverrideOnlyKeys: Set<String> = [
        "HOME", "GRADLE_USER_HOME", "ZDOTDIR", "GIT_DIR", "GIT_WORK_TREE",
        "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_SSH_COMMAND",
        "GIT_SSH", "GIT_PROXY_COMMAND", "GIT_ASKPASS", "GIT_SSL_NO_VERIFY",
        "GIT_SSL_CAINFO", "GIT_SSL_CAPATH", "SSH_ASKPASS", "LESSOPEN", "LESSCLOSE",
        "PAGER", "MANPAGER", "GIT_PAGER", "EDITOR", "VISUAL", "FCEDIT", "SUDO_EDITOR",
        "PROMPT_COMMAND", "HISTFILE", "PERL5DB", "PERL5DBCMD", "OPENSSL_CONF",
        "OPENSSL_ENGINES", "PYTHONSTARTUP", "WGETRC", "CURL_HOME", "CLASSPATH",
        "CFLAGS", "CGO_CFLAGS", "CGO_LDFLAGS", "GOFLAGS", "MAKEFLAGS", "MFLAGS",
        "CORECLR_PROFILER_PATH", "PHPRC", "PHP_INI_SCAN_DIR", "DENO_DIR",
        "BUN_CONFIG_REGISTRY", "YARN_RC_FILENAME", "HTTP_PROXY", "HTTPS_PROXY",
        "ALL_PROXY", "NO_PROXY", "NODE_TLS_REJECT_UNAUTHORIZED", "NODE_EXTRA_CA_CERTS",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        "DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "PIP_INDEX_URL",
        "PIP_PYPI_URL", "PIP_EXTRA_INDEX_URL", "PIP_CONFIG_FILE", "PIP_FIND_LINKS",
        "PIP_TRUSTED_HOST", "UV_INDEX", "UV_INDEX_URL", "UV_PYTHON", "UV_EXTRA_INDEX_URL",
        "UV_DEFAULT_INDEX", "DOCKER_CONTEXT", "LIBRARY_PATH", "LDFLAGS", "CPATH",
        "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "GOPROXY",
        "GONOSUMCHECK", "GONOSUMDB", "GONOPROXY", "GOPRIVATE", "GOENV", "GOPATH",
        "HGRCPATH", "PYTHONUSERBASE", "RUSTC_WRAPPER", "RUSTFLAGS", "RUSTUP_DIST_ROOT",
        "RUSTUP_DIST_SERVER", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "RUSTUP_UPDATE_ROOT",
        "CARGO_HOME", "VIRTUAL_ENV", "LUA_PATH", "LUA_CPATH", "GEM_HOME", "GEM_PATH",
        "BUNDLE_GEMFILE", "COMPOSER_HOME", "CONDA_DEFAULT_ENV", "CONDA_PREFIX",
        "CARGO_BUILD_RUSTC_WRAPPER", "XDG_CACHE_HOME", "XDG_CONFIG_DIRS", "XDG_CONFIG_HOME",
        "XDG_DATA_DIRS", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME",
        "AWS_CONFIG_FILE", "KUBECONFIG", "GOOGLE_APPLICATION_CREDENTIALS",
        "AWS_SHARED_CREDENTIALS_FILE", "AWS_WEB_IDENTITY_TOKEN_FILE", "AZURE_AUTH_LOCATION",
        "HELM_HOME", "ANSIBLE_CONFIG", "ANSIBLE_LIBRARY", "ANSIBLE_CALLBACK_PLUGINS",
        "ANSIBLE_COLLECTIONS_PATH", "ANSIBLE_CONNECTION_PLUGINS", "ANSIBLE_FILTER_PLUGINS",
        "ANSIBLE_INVENTORY_PLUGINS", "ANSIBLE_LOOKUP_PLUGINS", "ANSIBLE_MODULE_UTILS",
        "ANSIBLE_REMOTE_TEMP", "ANSIBLE_ROLES_PATH", "ANSIBLE_STRATEGY_PLUGINS",
        "R_LIBS_USER", "TF_CLI_CONFIG_FILE", "TF_PLUGIN_CACHE_DIR", "AMQP_URL",
        "AWS_ACCESS_KEY_ID", "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_SECRET_ACCESS_KEY", "AWS_SECURITY_TOKEN",
        "AWS_SESSION_TOKEN", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "DATABASE_URL",
        "GH_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN", "MONGODB_URI", "NODE_AUTH_TOKEN",
        "NPM_TOKEN", "REDIS_URL", "SSH_AUTH_SOCK", "SYSTEMROOT", "WINDIR"
    ]
    private static let blockedWorkspaceDotEnvOverridePrefixes = [
        "GIT_CONFIG_", "NPM_CONFIG_", "CARGO_REGISTRIES_", "TF_VAR_"
    ]
    private static let blockedWorkspaceDotEnvSuffixes = [
        "_API_HOST", "_API_KEY", "_BASE_URL", "_CREDENTIALS", "_ENDPOINT",
        "_HOMESERVER", "_OAUTH_TOKEN", "_PASSWORD", "_SECRET", "_TOKEN"
    ]
    private static let blockedWorkspaceDotEnvTokenSequences = [
        ["DANGEROUSLY"], ["DISABLE", "AUTH"], ["DISABLE", "CERT"],
        ["DISABLE", "SIGNATURE"], ["DISABLE", "SSL"], ["DISABLE", "TLS"],
        ["SKIP", "AUTH"]
    ]

    private struct LoadContext {
        let allowedRoots: [URL]
        let environment: [String: String]
        let homeURL: URL
    }

    struct LoadedObject {
        let value: [String: Any]
        let sourceURLs: [URL]
        let sourceRevisions: [ConfigFileRevision]
        let sourceBindings: [ConfigPathBinding]
        /// The dotenv/process environment used while parsing includes and
        /// expanding `agentDir` values.
        let environment: [String: String]
        /// The environment passed to the trusted OpenClaw validator. It keeps
        /// state-dotenv and process values, plus only workspace dotenv names
        /// allowed by the installed OpenClaw provider registry.
        let validatorEnvironment: [String: String]
    }

    struct ConfigFileRevision: Hashable {
        let path: String
        let mtimeNanoseconds: Int64
        let size: UInt64
        let inode: UInt64
    }

    /// A config source may be addressed through a symlink. Revisions of the
    /// resolved target alone do not prove that the same target was validated.
    struct ConfigPathBinding: Hashable {
        let lexicalPath: String
        let resolvedPath: String
    }

    struct ValidationSnapshot {
        let inputKey: String
        let environment: [String: String]
        let validatorEnvironment: [String: String]
        let sourceBindings: [ConfigPathBinding]

        func isCurrent(configURL: URL,
                       stateRoot: URL,
                       sourceRevisions: [ConfigFileRevision]) -> Bool {
            guard OpenClawConfigLoader.sourceRevisionsAreCurrent(sourceRevisions),
                  OpenClawConfigLoader.sourceBindingsAreCurrent(sourceBindings),
                  OpenClawConfigLoader.baseEnvironment(stateRoot: stateRoot) == environment,
                  OpenClawConfigLoader.trustedValidatorEnvironment(stateRoot: stateRoot) == validatorEnvironment,
                  let executable = OpenClawConfigLoader.resolveValidatorExecutable(),
                  let currentKey = OpenClawConfigLoader.validationInputKey(
                    configURL: configURL,
                    stateRoot: stateRoot,
                    sourceRevisions: sourceRevisions,
                    sourceBindings: sourceBindings,
                    executable: executable,
                    environment: environment,
                    validatorEnvironment: validatorEnvironment) else {
                return false
            }
            return currentKey == inputKey
        }
    }

    static func loadObject(at url: URL, stateRoot: URL) -> [String: Any]? {
        loadObjectWithSources(at: url, stateRoot: stateRoot)?.value
    }

    static func loadObjectWithSources(at url: URL, stateRoot: URL) -> LoadedObject? {
        let lexicalURL = url.standardizedFileURL
        let environment = baseEnvironment(stateRoot: stateRoot)
        let validatorEnvironment = trustedValidatorEnvironment(stateRoot: stateRoot)
        let homeURL = OpenClawPathResolver.effectiveHome(environment: environment)
        let context = LoadContext(
            allowedRoots: includeRoots(configURL: lexicalURL,
                                       environment: environment,
                                       homeURL: homeURL),
            environment: environment,
            homeURL: homeURL)
        var sourceRevisions: [String: ConfigFileRevision] = [:]
        var sourceBindings = Set<ConfigPathBinding>()
        guard let value = loadValue(at: lexicalURL,
                                    stack: [],
                                    context: context,
                                    sourceRevisions: &sourceRevisions,
                                    sourceBindings: &sourceBindings) as? [String: Any] else {
            return nil
        }
        let revisions = sourceRevisions.values.sorted { $0.path < $1.path }
        let bindings = sourceBindings.sorted {
            ($0.lexicalPath, $0.resolvedPath) < ($1.lexicalPath, $1.resolvedPath)
        }
        return LoadedObject(
            value: value,
            sourceURLs: revisions.map { URL(fileURLWithPath: $0.path) },
            sourceRevisions: revisions,
            sourceBindings: bindings,
            environment: environment,
            validatorEnvironment: validatorEnvironment)
    }

    /// OpenClaw owns the configuration schema. Use its read-only validator
    /// when it is installed instead of maintaining a partial, drift-prone copy
    /// of a multi-megabyte schema in Agent Sessions. A missing validator is a
    /// hard authority failure: an unverified candidate must not replace the
    /// last known agent ownership map.
    static func validateSchema(at configURL: URL,
                               stateRoot: URL,
                               sourceRevisions: [ConfigFileRevision],
                               sourceBindings: [ConfigPathBinding],
                               environment: [String: String],
                               validatorEnvironment: [String: String]) -> ValidationSnapshot? {
        guard !sourceRevisions.isEmpty,
              sourceRevisionsAreCurrent(sourceRevisions),
              sourceBindingsAreCurrent(sourceBindings) else {
            return nil
        }
        guard let executable = resolveValidatorExecutable(),
              let key = validationInputKey(configURL: configURL,
                                           stateRoot: stateRoot,
                                           sourceRevisions: sourceRevisions,
                                           sourceBindings: sourceBindings,
                                           executable: executable,
                                           environment: environment,
                                           validatorEnvironment: validatorEnvironment) else {
            // A validator that cannot be fingerprinted is not a stable
            // authority. Fail closed rather than treating an unknown
            // executable revision as a validated snapshot.
            return nil
        }

        guard let result = runValidator(configURL: configURL,
                                        stateRoot: stateRoot,
                                        executable: executable,
                                        environment: validatorEnvironment,
                                        timeout: validatorTimeout(for: executable)) else {
            // Launch failures, timeouts, and malformed validator output are
            // retryable availability failures, not schema decisions.
            return nil
        }
        guard result,
              sourceRevisionsAreCurrent(sourceRevisions),
              sourceBindingsAreCurrent(sourceBindings),
              baseEnvironment(stateRoot: stateRoot) == environment,
              OpenClawConfigLoader.trustedValidatorEnvironment(stateRoot: stateRoot) == validatorEnvironment,
              validationInputKey(configURL: configURL,
                                 stateRoot: stateRoot,
                                 sourceRevisions: sourceRevisions,
                                 sourceBindings: sourceBindings,
                                 executable: executable,
                                 environment: environment,
                                 validatorEnvironment: validatorEnvironment) == key else {
            return nil
        }
        return ValidationSnapshot(inputKey: key,
                                  environment: environment,
                                  validatorEnvironment: validatorEnvironment,
                                  sourceBindings: sourceBindings)
    }

    static func sourceRevisionsAreCurrent(_ revisions: [ConfigFileRevision]) -> Bool {
        revisions.allSatisfy { revision(for: URL(fileURLWithPath: $0.path)) == $0 }
    }

    static func sourceBindingsAreCurrent(_ bindings: [ConfigPathBinding]) -> Bool {
        bindings.allSatisfy { binding in
            let lexicalURL = URL(fileURLWithPath: binding.lexicalPath)
                .standardizedFileURL
            let resolvedPath = lexicalURL.resolvingSymlinksInPath()
                .standardizedFileURL.path
            return lexicalURL.path == binding.lexicalPath
                && resolvedPath == binding.resolvedPath
        }
    }

    static func effectiveEnvironment(baseEnvironment: [String: String],
                                     root: [String: Any]) -> [String: String] {
        var environment = baseEnvironment
        if let env = root["env"] as? [String: Any],
           let vars = env["vars"] as? [String: Any] {
            for (key, value) in vars {
                if environment[key] == nil, let value = value as? String {
                    environment[key] = value
                }
            }
        }
        // Explicit process variables win over config-provided defaults.
        for (key, value) in ProcessInfo.processInfo.environment {
            environment[key] = value
        }
        return environment
    }

    /// OpenClaw expands only uppercase shell variable names. `$${...}` is an
    /// escaped literal and must never be substituted. Return nil for an
    /// unresolved variable without a fallback so discovery cannot silently
    /// point at an unrelated path.
    static func expandEnvironmentVariables(_ value: String,
                                           environment: [String: String]) -> String? {
        let characters = Array(value)
        var result = String()
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                result.append(characters[index])
                index += 1
                continue
            }

            if index + 2 < characters.count,
               characters[index + 1] == "$",
               characters[index + 2] == "{",
               let end = closingBrace(in: characters, from: index + 3) {
                result.append(contentsOf: String(characters[(index + 1)...end]))
                index = end + 1
                continue
            }

            guard index + 1 < characters.count, characters[index + 1] == "{",
                  let end = closingBrace(in: characters, from: index + 2) else {
                result.append(characters[index])
                index += 1
                continue
            }

            let expression = String(characters[(index + 2)..<end])
            let name: String
            let fallback: String?
            if let separator = expression.range(of: ":-") {
                name = String(expression[..<separator.lowerBound])
                fallback = String(expression[separator.upperBound...])
            } else {
                name = expression
                fallback = nil
            }

            guard isValidVariableName(name),
                  !(fallback?.contains("$") ?? false),
                  !(fallback?.contains("{") ?? false) else {
                result.append(contentsOf: String(characters[index...end]))
                index = end + 1
                continue
            }

            let replacement: String
            if let environmentValue = environment[name], !environmentValue.isEmpty {
                replacement = environmentValue
            } else if let fallback {
                replacement = fallback
            } else {
                return nil
            }
            result.append(contentsOf: replacement)
            index = end + 1
        }
        return result
    }

    private static func loadValue(at url: URL,
                                  stack: Set<String>,
                                  context: LoadContext,
                                  sourceRevisions: inout [String: ConfigFileRevision],
                                  sourceBindings: inout Set<ConfigPathBinding>) -> Any? {
        let lexicalURL = url.standardizedFileURL
        let normalized = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        sourceBindings.insert(ConfigPathBinding(lexicalPath: lexicalURL.path,
                                                resolvedPath: normalized.path))
        let path = normalized.path
        guard !stack.contains(path), stack.count <= maxIncludeDepth,
              let before = revision(for: normalized),
              before.size <= maxConfigFileBytes,
              let data = try? Data(contentsOf: normalized),
              let after = revision(for: normalized),
              before == after,
              let parsed = JSON5ValueParser.parse(data: data) else { return nil }

        if let previous = sourceRevisions[path], previous != before {
            return nil
        }

        sourceRevisions[path] = before
        var nextStack = stack
        nextStack.insert(path)
        return resolve(parsed,
                       baseURL: normalized.deletingLastPathComponent(),
                       stack: nextStack,
                       context: context,
                       sourceRevisions: &sourceRevisions,
                       sourceBindings: &sourceBindings)
    }

    private static func resolve(_ value: Any,
                                baseURL: URL,
                                stack: Set<String>,
                                context: LoadContext,
                                sourceRevisions: inout [String: ConfigFileRevision],
                                sourceBindings: inout Set<ConfigPathBinding>) -> Any? {
        if let object = value as? [String: Any] {
            var merged: [String: Any] = [:]
            if let includeValue = object["$include"] {
                guard let includePaths = includeURLs(from: includeValue,
                                                     baseURL: baseURL,
                                                     context: context) else { return nil }
                for includeURL in includePaths {
                    guard let included = loadValue(at: includeURL,
                                                   stack: stack,
                                                   context: context,
                                                   sourceRevisions: &sourceRevisions,
                                                   sourceBindings: &sourceBindings) as? [String: Any] else { return nil }
                    merged = merge(merged, included)
                }
            }

            for (key, rawValue) in object where key != "$include" {
                guard let resolved = resolve(rawValue,
                                             baseURL: baseURL,
                                             stack: stack,
                                             context: context,
                                             sourceRevisions: &sourceRevisions,
                                             sourceBindings: &sourceBindings) else { return nil }
                if let inherited = merged[key] as? [String: Any],
                   let local = resolved as? [String: Any] {
                    merged[key] = merge(inherited, local)
                } else {
                    merged[key] = resolved
                }
            }
            return merged
        }
        if let array = value as? [Any] {
            var resolved: [Any] = []
            resolved.reserveCapacity(array.count)
            for item in array {
                guard let item = resolve(item,
                                         baseURL: baseURL,
                                         stack: stack,
                                         context: context,
                                         sourceRevisions: &sourceRevisions,
                                         sourceBindings: &sourceBindings) else { return nil }
                resolved.append(item)
            }
            return resolved
        }
        return value
    }

    private static func includeURLs(from value: Any,
                                    baseURL: URL,
                                    context: LoadContext) -> [URL]? {
        let paths: [String]
        if let path = value as? String {
            paths = [path]
        } else if let values = value as? [Any] {
            paths = values.compactMap { $0 as? String }
            guard paths.count == values.count else { return nil }
        } else {
            return nil
        }
        var urls: [URL] = []
        urls.reserveCapacity(paths.count)
        for rawPath in paths {
            guard rawPath.utf8.count <= maxIncludePathBytes,
                  let expandedEnvironmentPath = expandEnvironmentVariables(
                    rawPath,
                    environment: context.environment) else { return nil }
            let url = OpenClawPathResolver.url(
                for: expandedEnvironmentPath,
                relativeTo: baseURL,
                tildeHome: context.homeURL)
            let lexicalURL = url.standardizedFileURL
            let normalized = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
            guard context.allowedRoots.contains(where: { isWithin(normalized, root: $0) }) else {
                return nil
            }
            // Preserve the lexical path. `loadValue` records the lexical to
            // resolved mapping so validation can reject a symlink retarget
            // between local parsing and the OpenClaw validator.
            urls.append(lexicalURL)
        }
        return urls
    }

    private static func baseEnvironment(stateRoot: URL) -> [String: String] {
        var environment = loadDotEnvironment(
            at: stateRoot.appendingPathComponent(".env"))
        let providerAuthEnvNames = knownProviderAuthEnvVarNames(stateRoot: stateRoot)
        let currentDirectoryEnvironment = loadDotEnvironment(
            at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env"))
            .filter { !isBlockedWorkspaceDotEnvKey(
                $0.key,
                providerAuthEnvNames: providerAuthEnvNames) }
        environment.merge(currentDirectoryEnvironment, uniquingKeysWith: { _, current in current })
        for (key, value) in ProcessInfo.processInfo.environment {
            environment[key] = value
        }
        return environment
    }

    private static func trustedValidatorEnvironment(stateRoot: URL) -> [String: String] {
        var environment = loadDotEnvironment(
            at: stateRoot.appendingPathComponent(".env"))
        // Keep ordinary workspace variables available only when the installed
        // OpenClaw provider registry can supply its dynamic auth names. A
        // custom validator has no trustworthy way to describe that registry,
        // so fail closed and do not import any workspace dotenv variables into
        // its process environment.
        if let providerAuthEnvNames = knownProviderAuthEnvVarNames(stateRoot: stateRoot) {
            let currentDirectoryEnvironment = loadDotEnvironment(
                at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".env"))
                .filter { !isBlockedWorkspaceDotEnvKey(
                    $0.key,
                    providerAuthEnvNames: providerAuthEnvNames) }
            environment.merge(currentDirectoryEnvironment, uniquingKeysWith: { _, current in current })
        }
        for (key, value) in ProcessInfo.processInfo.environment {
            environment[key] = value
        }
        return environment
    }

    private static func isBlockedWorkspaceDotEnvKey(
        _ key: String,
        providerAuthEnvNames: Set<String>? = nil
    ) -> Bool {
        let uppercased = key.uppercased()
        guard !uppercased.isEmpty else { return false }
        if providerAuthEnvNames?.contains(uppercased) == true
            || blockedWorkspaceDotEnvKeys.contains(uppercased)
            || blockedWorkspaceDotEnvOverrideOnlyKeys.contains(uppercased)
            || blockedWorkspaceDotEnvPrefixes.contains(where: { uppercased.hasPrefix($0) })
            || blockedWorkspaceDotEnvOverridePrefixes.contains(where: { uppercased.hasPrefix($0) })
            || blockedWorkspaceDotEnvSuffixes.contains(where: { uppercased.hasSuffix($0) }) {
            return true
        }
        if uppercased.hasPrefix("CARGO_TARGET_")
            && (uppercased.hasSuffix("_LINKER") || uppercased.hasSuffix("_RUNNER")) {
            return true
        }
        let tokens = uppercased.split(separator: "_").map(String.init)
        return blockedWorkspaceDotEnvTokenSequences.contains { sequence in
            guard tokens.count >= sequence.count else { return false }
            return (0...(tokens.count - sequence.count)).contains { index in
                sequence.enumerated().allSatisfy { offset, token in
                    tokens[index + offset] == token
                }
            }
        }
    }

    /// OpenClaw's provider-auth blocklist includes names contributed by its
    /// trusted installed/bundled plugins. Keep that policy in the installed
    /// registry instead of copying another growing list into Swift. If the
    /// registry bridge is unavailable, callers receive nil and the trusted
    /// validator path deliberately imports no workspace dotenv values.
    private static func knownProviderAuthEnvVarNames(stateRoot: URL) -> Set<String>? {
        guard let executable = resolveValidatorExecutable(),
              let module = providerEnvVarModuleURL(for: executable),
              let node = resolveNodeExecutable() else {
            return nil
        }

        let workspacePath = FileManager.default.currentDirectoryPath
        let script = """
        const moduleURL = process.env.AGENT_SESSIONS_OPENCLAW_PROVIDER_ENV_MODULE;
        const { listKnownProviderAuthEnvVarNames } = await import(moduleURL);
        const names = listKnownProviderAuthEnvVarNames({
          env: process.env,
          workspaceDir: process.cwd(),
          includeUntrustedWorkspacePlugins: false
        });
        process.stdout.write(JSON.stringify(names));
        """
        let process = Process()
        process.executableURL = node
        process.arguments = ["--input-type=module", "-e", script]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_SESSIONS_OPENCLAW_PROVIDER_ENV_MODULE"] = module.absoluteString
        environment["OPENCLAW_STATE_DIR"] = stateRoot.path
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath,
                                           isDirectory: true)

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let pipeCollector = ProcessPipeCollector(pipes: [output, errors])
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipeCollector.cancel()
            return nil
        }
        let timedOut = finished.wait(timeout: .now() + 2.0) == .timedOut
        if timedOut {
            stopTimedOutProcess(process, finished: finished, pipeCollector: pipeCollector)
            return nil
        }
        guard let pipeData = pipeCollector.collect(timeout: 0.5),
              let data = pipeData.first,
              data.count <= 128 * 1024,
              process.terminationStatus == 0,
              let names = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        let normalized = Set(names.map { $0.uppercased() }.filter(isValidVariableName))
        return normalized
    }

    private static func stopTimedOutProcess(
        _ process: Process,
        finished: DispatchSemaphore,
        pipeCollector: ProcessPipeCollector
    ) {
        if process.isRunning {
            process.terminate()
        }
        if finished.wait(timeout: .now() + 0.5) == .timedOut,
           process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        }
        pipeCollector.cancel()
    }

    /// Drains child-process pipes while the child is running. Installing the
    /// handlers only after waitpid can deadlock a validator that writes more
    /// than the OS pipe buffer before it exits.
    private final class ProcessPipeCollector: @unchecked Sendable {
        private static let maxBytesPerPipe = 128 * 1024

        private let pipes: [Pipe]
        private let buffers: Locked<[Data]>
        private let pipeLocks: [NSLock]
        private let completed = Locked(Set<Int>())
        private let overflowed = Locked(false)
        private let closed = Locked(false)
        private let group = DispatchGroup()

        init(pipes: [Pipe]) {
            self.pipes = pipes
            self.buffers = Locked(Array(repeating: Data(), count: pipes.count))
            self.pipeLocks = pipes.map { _ in NSLock() }
            for (index, pipe) in pipes.enumerated() {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.consume(index: index, handle: handle)
                }
            }
        }

        func collect(timeout: TimeInterval) -> [Data]? {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                cancel()
                // A finished child can leave a descendant holding stderr open.
                // The bytes already drained are still usable when the caller
                // has a complete bounded payload (JSON callers validate it
                // below); reject only an overflowed buffer.
                guard !overflowed.withLock({ $0 }) else { return nil }
                return buffers.withLock { $0 }
            }
            defer { closeHandles() }
            guard !overflowed.withLock({ $0 }) else { return nil }
            return buffers.withLock { $0 }
        }

        func cancel() {
            closeHandles()
            for index in pipes.indices {
                if completed.withLock({ $0.insert(index).inserted }) {
                    group.leave()
                }
            }
        }

        private func consume(index: Int, handle: FileHandle) {
            let lock = pipeLocks[index]
            lock.lock()
            defer { lock.unlock() }
            guard !closed.withLock({ $0 }) else { return }

            let data: Data
            do {
                data = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                finish(index: index, handle: handle)
                return
            }
            guard !data.isEmpty else {
                finish(index: index, handle: handle)
                return
            }

            let exceedsLimit = buffers.withLock { values -> Bool in
                guard values[index].count + data.count <= Self.maxBytesPerPipe else {
                    return true
                }
                values[index].append(data)
                return false
            }
            if exceedsLimit {
                overflowed.withLock { $0 = true }
                finish(index: index, handle: handle)
            }
        }

        private func finish(index: Int, handle: FileHandle) {
            handle.readabilityHandler = nil
            try? handle.close()
            complete(index: index)
        }

        private func complete(index: Int) {
            if completed.withLock({ $0.insert(index).inserted }) {
                group.leave()
            }
        }

        private func closeHandles() {
            guard closed.withLock({ value in
                guard !value else { return false }
                value = true
                return true
            }) else { return }
            for (index, pipe) in pipes.enumerated() {
                let lock = pipeLocks[index]
                lock.lock()
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                lock.unlock()
            }
        }
    }

    private static func providerEnvVarModuleURL(for executable: URL) -> URL? {
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.lastPathComponent == "openclaw.mjs" else { return nil }
        let module = resolved.deletingLastPathComponent()
            .appendingPathComponent("dist/plugin-sdk/provider-env-vars.js")
        return FileManager.default.isReadableFile(atPath: module.path) ? module : nil
    }

    private static func resolveNodeExecutable() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("node").path
            })
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ])
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func includeRoots(configURL: URL,
                                     environment: [String: String],
                                     homeURL: URL) -> [URL] {
        var roots = [configURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL]
        let configuredRoots = environment["OPENCLAW_INCLUDE_ROOTS"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        roots.append(contentsOf: configuredRoots.map {
            OpenClawPathResolver.url(for: $0, relativeTo: nil, tildeHome: homeURL)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        })
        return Array(Set(roots))
    }

    private static func revision(for url: URL) -> ConfigFileRevision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              modified.timeIntervalSince1970.isFinite else {
            return nil
        }
        let mtime = Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return ConfigFileRevision(path: url.path,
                                  mtimeNanoseconds: mtime,
                                  size: size,
                                  inode: inode)
    }

    private static func validationRevisionKey(
        sourceRevisions: [ConfigFileRevision]
    ) -> String {
        sourceRevisions
            .sorted { $0.path < $1.path }
            .map { "\($0.path)|\($0.mtimeNanoseconds)|\($0.size)|\($0.inode)" }
            .joined(separator: "\n")
    }

    private static func validationInputKey(
        configURL: URL,
        stateRoot: URL,
        sourceRevisions: [ConfigFileRevision],
        sourceBindings: [ConfigPathBinding],
        executable: URL,
        environment: [String: String],
        validatorEnvironment: [String: String]
    ) -> String? {
        guard let executableRevision = revision(for: executable) else {
            return nil
        }
        let environmentKey = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let validatorEnvironmentKey = validatorEnvironment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let dotenvPaths = [
            stateRoot.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env")
        ]
        let dotenvRevisions = dotenvPaths.map { url in
            "\(url.standardizedFileURL.resolvingSymlinksInPath().path)=\(fileRevisionKey(for: url))"
        }.joined(separator: "\n")
        let override = UserDefaults.standard.string(
            forKey: PreferencesKey.Paths.openClawBinaryOverride) ?? ""
        return [
            "config=\(configURL.standardizedFileURL.resolvingSymlinksInPath().path)",
            "state=\(stateRoot.standardizedFileURL.resolvingSymlinksInPath().path)",
            "sources=\(validationRevisionKey(sourceRevisions: sourceRevisions))",
            "bindings=\(validationBindingKey(sourceBindings: sourceBindings))",
            "validator=\(executable.standardizedFileURL.resolvingSymlinksInPath().path)|\(fileRevisionKey(executableRevision))",
            "override=\(override)",
            "dotenv=\(dotenvRevisions)",
            "environment=\(environmentKey)",
            "validatorEnvironment=\(validatorEnvironmentKey)"
        ].joined(separator: "\n")
    }

    private static func validationBindingKey(
        sourceBindings: [ConfigPathBinding]
    ) -> String {
        sourceBindings
            .sorted {
                ($0.lexicalPath, $0.resolvedPath) < ($1.lexicalPath, $1.resolvedPath)
            }
            .map { "\($0.lexicalPath)->\($0.resolvedPath)" }
            .joined(separator: "\n")
    }

    private static func fileRevisionKey(for url: URL) -> String {
        guard let fileRevision = revision(for: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? "unavailable" : "missing"
        }
        return fileRevisionKey(fileRevision)
    }

    private static func fileRevisionKey(_ fileRevision: ConfigFileRevision) -> String {
        "\(fileRevision.mtimeNanoseconds)|\(fileRevision.size)|\(fileRevision.inode)"
    }

    private static func runValidator(configURL: URL,
                                     stateRoot: URL,
                                     executable: URL,
                                     environment baseEnvironmentSnapshot: [String: String],
                                     timeout: TimeInterval) -> Bool? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["config", "validate", "--json"]
        var environment = baseEnvironmentSnapshot
        environment["OPENCLAW_CONFIG_PATH"] = configURL.path
        environment["OPENCLAW_STATE_DIR"] = stateRoot.path
        let executableDirectory = executable.deletingLastPathComponent().path
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(Set([executableDirectory] + path)).joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let pipeCollector = ProcessPipeCollector(pipes: [output, errors])
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipeCollector.cancel()
            return nil
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            stopTimedOutProcess(process, finished: finished, pipeCollector: pipeCollector)
            return nil
        }
        guard let pipeData = pipeCollector.collect(timeout: 0.5),
              let data = pipeData.first,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valid = object["valid"] as? Bool else {
            return nil
        }
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }
        return valid
    }

    private static func validatorTimeout(for executable: URL) -> TimeInterval {
        // A user-supplied validator is testable and must remain tightly
        // bounded. The installed OpenClaw CLI performs Node/plugin startup on
        // every invocation; two seconds is shorter than a normal cold start on
        // this machine and turns valid configs into false authority failures.
        let override = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawBinaryOverride)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return override == nil ? 5.0 : 2.0
    }

    private static func resolveValidatorExecutable() -> URL? {
        let override = UserDefaults.standard.string(forKey: PreferencesKey.Paths.openClawBinaryOverride)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [String]()
        if let override { candidates.append(override) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("openclaw").path
            })
        }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "/usr/bin/openclaw"
        ])
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != rootPath else { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    private static func closingBrace(in characters: [Character], from start: Int) -> Int? {
        guard start < characters.count else { return nil }
        return characters[start...].firstIndex(of: "}")
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        let characters = Array(name)
        guard let first = characters.first,
              first == "_" || (first >= "A" && first <= "Z") else { return false }
        return characters.dropFirst().allSatisfy {
            $0 == "_" || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }
    }

    private static func loadDotEnvironment(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var environment: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               ((value.first == "\"" && value.last == "\"") ||
                (value.first == "'" && value.last == "'")) {
                value.removeFirst()
                value.removeLast()
            }
            environment[key] = value
        }
        return environment
    }

    private static func merge(_ inherited: [String: Any], _ local: [String: Any]) -> [String: Any] {
        var result = inherited
        for (key, value) in local {
            if let prior = result[key] as? [String: Any],
               let next = value as? [String: Any] {
                result[key] = merge(prior, next)
            } else if let prior = result[key] as? [Any],
                      let next = value as? [Any] {
                // OpenClaw's include loader concatenates arrays, which is
                // required for fragments that each contribute agents.list.
                result[key] = prior + next
            } else {
                result[key] = value
            }
        }
        return result
    }
}

private struct JSON5ValueParser {
    private var characters: [Character]
    private var index: Int = 0

    private init(_ source: String) {
        characters = Array(source)
    }

    static func parse(data: Data) -> Any? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        var parser = JSON5ValueParser(source)
        return parser.parseDocument()
    }

    private mutating func parseDocument() -> Any? {
        skipTrivia()
        guard let value = parseValue() else { return nil }
        skipTrivia()
        return index == characters.count ? value : nil
    }

    private mutating func parseValue() -> Any? {
        skipTrivia()
        guard let current = peek() else { return nil }
        switch current {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"", "'": return parseString()
        default: return parseAtom()
        }
    }

    private mutating func parseObject() -> [String: Any]? {
        guard consume("{") else { return nil }
        skipTrivia()
        var object: [String: Any] = [:]
        if consume("}") { return object }

        while true {
            skipTrivia()
            let key: String?
            if let quote = peek(), quote == "\"" || quote == "'" {
                key = parseString()
            } else {
                key = parseIdentifier()
            }
            guard let key, consume(":") else { return nil }
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipTrivia()
            if consume("}") { return object }
            guard consume(",") else { return nil }
            skipTrivia()
            if consume("}") { return object }
        }
    }

    private mutating func parseArray() -> [Any]? {
        guard consume("[") else { return nil }
        skipTrivia()
        var array: [Any] = []
        if consume("]") { return array }

        while true {
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipTrivia()
            if consume("]") { return array }
            guard consume(",") else { return nil }
            skipTrivia()
            if consume("]") { return array }
        }
    }

    private mutating func parseString() -> String? {
        guard let quote = peek(), quote == "\"" || quote == "'" else { return nil }
        index += 1
        var result = String()
        while let current = peek() {
            index += 1
            if current == quote { return result }
            guard current == "\\" else {
                // JSON5 permits a physical line break in a string only as a
                // backslash line continuation. Treat an unescaped LF/CR as a
                // syntax error instead of silently accepting a config the
                // OpenClaw validator will reject.
                guard current != "\n", current != "\r" else { return nil }
                result.append(current)
                continue
            }
            guard let escaped = peek() else { return nil }
            index += 1
            switch escaped {
            case "b": result.append("\u{0008}")
            case "f": result.append("\u{000C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "v": result.append("\u{000B}")
            case "0": result.append("\0")
            case "\n": break
            case "\r":
                if peek() == "\n" { index += 1 }
            case "u":
                guard index + 4 <= characters.count else { return nil }
                let hex = String(characters[index..<(index + 4)])
                guard let scalarValue = UInt32(hex, radix: 16),
                      let scalar = UnicodeScalar(scalarValue) else { return nil }
                result.unicodeScalars.append(scalar)
                index += 4
            case "x":
                guard index + 2 <= characters.count else { return nil }
                let hex = String(characters[index..<(index + 2)])
                guard let scalarValue = UInt32(hex, radix: 16),
                      let scalar = UnicodeScalar(scalarValue) else { return nil }
                result.unicodeScalars.append(scalar)
                index += 2
            default: result.append(escaped)
            }
        }
        return nil
    }

    private mutating func parseIdentifier() -> String? {
        guard let current = peek(), isIdentifierStart(current) else { return nil }
        let start = index
        index += 1
        while let next = peek(), isIdentifierPart(next) { index += 1 }
        return String(characters[start..<index])
    }

    private mutating func parseAtom() -> Any? {
        let start = index
        while let current = peek(), !isDelimiter(current) { index += 1 }
        guard start != index else { return nil }
        let token = String(characters[start..<index])
        switch token {
        case "true": return true
        case "false": return false
        case "null": return NSNull()
        default:
            if token.hasPrefix("0x") || token.hasPrefix("0X"),
               let value = Int64(token.dropFirst(2), radix: 16) {
                return NSNumber(value: value)
            }
            if token.contains(".") || token.contains("e") || token.contains("E") {
                return Double(token)
            }
            if let value = Int64(token) { return NSNumber(value: value) }
            return nil
        }
    }

    private mutating func skipTrivia() {
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if characters[index] == "/", peek(1) == "/" {
                index += 2
                while let current = peek(), current != "\n" { index += 1 }
                continue
            }
            if characters[index] == "/", peek(1) == "*" {
                index += 2
                while index + 1 < characters.count {
                    if characters[index] == "*", characters[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }
            break
        }
    }

    private func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || "{}[],:".contains(character) || character == "/"
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        return characters.indices.contains(position) ? characters[position] : nil
    }

    private mutating func consume(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        index += 1
        return true
    }
}
