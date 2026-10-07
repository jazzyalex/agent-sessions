import Foundation
import CryptoKit

/// Bounded filesystem discovery for the DSH session persistence layout.
final class DeepSeekHarnessDiscovery: SessionDiscovery {
    private struct CachedContentFingerprint {
        let stat: SessionFileStat
        let value: String
    }

    private static let contentFingerprintCacheLimit = 2_048
    private static let contentFingerprintCacheLock = NSLock()
    private static var contentFingerprintCache: [String: CachedContentFingerprint] = [:]
#if DEBUG
    static var testManifestFingerprintHashObserver: ((URL) -> Void)?
    static var testManifestFingerprintBeforeOpenObserver: ((URL) -> Void)?
    static var testManifestFingerprintAfterOpenObserver: ((URL) -> Void)?
#endif

    private let customRoot: String?
    private let homeDirectory: URL
    private let environment: [String: String]
    private let directoryContents: (URL) throws -> [URL]
    private let itemAttributes: (String) throws -> [FileAttributeKey: Any]

    init(customRoot: String? = nil,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         fileManager: FileManager = .default,
         directoryContents: ((URL) throws -> [URL])? = nil,
         itemAttributes: ((String) throws -> [FileAttributeKey: Any])? = nil) {
        self.customRoot = Self.normalized(customRoot)
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.directoryContents = directoryContents ?? { url in
            try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        }
        self.itemAttributes = itemAttributes ?? { path in
            try fileManager.attributesOfItem(atPath: path)
        }
    }

    func sessionsRoot() -> URL {
        if let customRoot {
            let expanded = Self.expand(customRoot, homeDirectory: homeDirectory)
            // The preference names a sessions root, matching the other file-backed sources.
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return DeepSeekHarnessSettings.sessionsRoot(homeDirectory: homeDirectory, environment: environment)
    }

    func discoverSessionFiles() -> [URL] {
        discover().candidates.map(\.selectedURL)
    }

    func discover() -> DeepSeekHarnessDiscoveryResult {
        let root = sessionsRoot()
        let rootType: FileAttributeType
        do {
            rootType = try fileType(root)
        } catch {
            if Self.isMissingFileError(error) {
                return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
            }
            return DeepSeekHarnessDiscoveryResult(
                candidates: [], issues: [.filesystemAccess(root.path)], encoding: nil
            )
        }
        guard rootType == .typeDirectory else {
            return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
        }

        var issues: [DeepSeekHarnessFormatError] = []
        var artifacts: [(url: URL, project: URL, session: URL, generation: Int, compression: DeepSeekHarnessCompression)] = []
        var encodings = Set<DeepSeekHarnessCompression>()

        let projectDirectories: [URL]
        do {
            projectDirectories = try directChildren(of: root)
        } catch {
            return DeepSeekHarnessDiscoveryResult(
                candidates: [], issues: [.filesystemAccess(root.path)], encoding: nil
            )
        }
        for projectDirectory in projectDirectories {
            guard !Task.isCancelled else {
                return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
            }
            let projectType: FileAttributeType
            do { projectType = try fileType(projectDirectory) }
            catch { issues.append(.filesystemAccess(projectDirectory.path)); continue }
            guard projectType == .typeDirectory else { continue }
            let sessionEntries: [URL]
            do { sessionEntries = try directChildren(of: projectDirectory) }
            catch { issues.append(.filesystemAccess(projectDirectory.path)); continue }
            for child in sessionEntries {
                guard !Task.isCancelled else {
                    return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
                }
                let childType: FileAttributeType
                do { childType = try fileType(child) }
                catch { issues.append(.filesystemAccess(child.path)); continue }
                if childType == .typeRegular, let compression = Self.parseLegacyFlatFilename(child.lastPathComponent) {
                    issues.append(.legacyLayout(child))
                    encodings.insert(compression)
                    continue
                }
                guard childType == .typeDirectory else { continue }
                let sessionArtifacts: [URL]
                do { sessionArtifacts = try directChildren(of: child) }
                catch { issues.append(.filesystemAccess(child.path)); continue }
                for artifact in sessionArtifacts {
                    guard !Task.isCancelled else {
                        return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
                    }
                    let artifactType: FileAttributeType
                    do { artifactType = try fileType(artifact) }
                    catch { issues.append(.filesystemAccess(artifact.path)); continue }
                    guard artifactType == .typeRegular else { continue }
                    guard let parsed = Self.parseGenerationFilename(artifact.lastPathComponent) else { continue }
                    artifacts.append((artifact, projectDirectory, child, parsed.generation, parsed.compression))
                    encodings.insert(parsed.compression)
                }
            }
        }

        guard encodings.count <= 1 else {
            issues.append(.encodingMismatch)
            return DeepSeekHarnessDiscoveryResult(candidates: [], issues: issues, encoding: nil)
        }
        let encoding = encodings.first
        var grouped: [URL: [(url: URL, project: URL, session: URL, generation: Int, compression: DeepSeekHarnessCompression)]] = [:]
        for artifact in artifacts {
            grouped[artifact.session, default: []].append(artifact)
        }

        var candidates: [DeepSeekHarnessSessionCandidate] = []
        for (sessionDirectory, members) in grouped {
            guard !Task.isCancelled else {
                return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
            }
            let sorted = members.sorted { lhs, rhs in
                if lhs.generation != rhs.generation { return lhs.generation > rhs.generation }
                return lhs.url.path < rhs.url.path
            }
            guard let selected = sorted.first else { continue }
            if sorted.dropFirst().contains(where: { $0.generation == selected.generation }) {
                issues.append(.ambiguousSession(sessionDirectory.lastPathComponent))
                continue
            }
            do {
                let header = try DeepSeekHarnessArtifactReader.readHeader(url: selected.url, compression: selected.compression)
                guard (0...4).contains(header.version) else {
                    throw DeepSeekHarnessFormatError.unsupportedVersion(header.version)
                }
                guard header.version == selected.generation else {
                    throw DeepSeekHarnessFormatError.canonicalPathMismatch
                }
                let canonical = Self.canonicalGenerationURL(root: root,
                                                              cwd: header.cwd,
                                                              id: header.id,
                                                              version: header.version,
                                                              compression: selected.compression)
                let canonicalPath = canonical.standardizedFileURL
                let selectedPath = selected.url.standardizedFileURL
                let sameSpelling = canonicalPath == selectedPath
                let samePhysicalPath = canonicalPath.resolvingSymlinksInPath()
                    == selectedPath.resolvingSymlinksInPath()
                guard sameSpelling || samePhysicalPath else {
                    throw DeepSeekHarnessFormatError.canonicalPathMismatch
                }
                let siblingURLs = sorted
                    .filter { $0.compression == selected.compression }
                    .map(\.url)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let revision = try Self.manifestRevision(siblings: siblingURLs)
                candidates.append(DeepSeekHarnessSessionCandidate(
                    id: header.id,
                    projectDirectory: selected.project,
                    sessionDirectory: selected.session,
                    selectedURL: selected.url,
                    generation: selected.generation,
                    compression: selected.compression,
                    header: header,
                    manifestRevision: revision,
                    siblings: siblingURLs
                ))
            } catch let error as DeepSeekHarnessFormatError {
                issues.append(error)
            } catch is CancellationError {
                return DeepSeekHarnessDiscoveryResult(candidates: [], issues: [], encoding: nil)
            } catch {
                issues.append(.invalidHeader)
            }
        }

        var byID: [String: [DeepSeekHarnessSessionCandidate]] = [:]
        for candidate in candidates { byID[candidate.id, default: []].append(candidate) }
        candidates = byID.values.flatMap { group -> [DeepSeekHarnessSessionCandidate] in
            guard group.count == 1, let only = group.first else {
                if let id = group.first?.id { issues.append(.ambiguousSession(id)) }
                return []
            }
            return [only]
        }
        candidates.sort { $0.id < $1.id }
        return DeepSeekHarnessDiscoveryResult(candidates: candidates, issues: issues, encoding: encoding)
    }

    static func parseGenerationFilename(_ filename: String) -> (generation: Int, compression: DeepSeekHarnessCompression)? {
        let compression: DeepSeekHarnessCompression
        let raw: String
        if filename.hasSuffix(".jsonl.zstd") {
            compression = .zstd
            raw = String(filename.dropLast(".zstd".count))
        } else if filename.hasSuffix(".jsonl") {
            compression = .plain
            raw = filename
        } else {
            return nil
        }
        if raw == "session.jsonl" { return (0, compression) }
        guard raw.hasPrefix("session.v"), raw.hasSuffix(".jsonl") else { return nil }
        let digits = raw.dropFirst("session.v".count).dropLast(".jsonl".count)
        guard !digits.isEmpty, digits.first != "0", digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let generation = Int(digits), generation > 0 else { return nil }
        return (generation, compression)
    }

    /// Released pre-directory DSH layouts stored `<encoded-id>.jsonl[.zstd]`
    /// directly below a project key. They are compatibility errors, not
    /// generation zero candidates, and still participate in root-wide encoding
    /// consistency checks.
    private static func parseLegacyFlatFilename(_ filename: String) -> DeepSeekHarnessCompression? {
        if filename.hasSuffix(".jsonl.zstd") {
            let stem = filename.dropLast(".jsonl.zstd".count)
            return stem.isEmpty ? nil : .zstd
        }
        if filename.hasSuffix(".jsonl") {
            let stem = filename.dropLast(".jsonl".count)
            return stem.isEmpty ? nil : .plain
        }
        return nil
    }

    static func encodeSegment(_ raw: String) -> String {
        precondition(!raw.isEmpty, "DSH path segments must not be empty")
        if raw == "." { return "~002E" }
        if raw == ".." { return "~002E~002E" }
        var output = ""
        for unit in raw.utf16 {
            if !isSafeASCII(unit) {
                output += "~" + String(format: "%04X", unit)
            } else {
                output.append(Character(UnicodeScalar(unit)!))
            }
        }
        return output
    }

    static func projectKey(_ cwd: String) -> String {
        precondition(!cwd.isEmpty)
        var readable = ""
        var separatorRun = false
        for unit in cwd.utf16 {
            if unit == 0x2F || unit == 0x5C || unit == 0x3A {
                if !separatorRun { readable.append("-") }
                separatorRun = true
            } else if !isSafeASCII(unit) {
                readable += "~" + String(format: "%04X", unit)
                separatorRun = false
            } else {
                readable.append(Character(UnicodeScalar(unit)!))
                separatorRun = false
            }
        }
        let slug = readable.drop(while: { $0 == "-" })
        return "--\(slug.isEmpty ? "root" : String(slug.prefix(251)))--"
    }

    static func canonicalGenerationURL(root: URL,
                                       cwd: String?,
                                       id: String,
                                       version: Int,
                                       compression: DeepSeekHarnessCompression) -> URL {
        let project = cwd.map(projectKey) ?? "_no-cwd"
        let session = encodeSegment(id)
        let basename = version == 0 ? "session.jsonl" : "session.v\(version).jsonl"
        return root.appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent(basename + (compression == .zstd ? ".zstd" : ""), isDirectory: false)
    }

    /// Generic directory-artifact revision resolver backing
    /// `SessionSourceDescriptor.artifactRevision`.
    ///
    /// Derives the logical sessions root from a previously selected canonical
    /// generation URL (`<root>/<project>/<session>/<generation>`), inspects only
    /// that session directory, and returns its currently selected generation.
    /// Fail-closed:
    /// nil for non-canonical URLs, session directories that do not look like
    /// generation containers, root problems, ambiguity, or an unreadable selected
    /// file. The root always derives from the given URL — resolution never falls back
    /// to the default root, so a failure here can never redirect a scan at `~/.dsh`.
    static func resolveArtifactRevision(forSelectedURL url: URL) -> SessionArtifactRevision? {
        guard !Task.isCancelled, parseGenerationFilename(url.lastPathComponent) != nil else { return nil }
        let sessionDirectory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        let projectDirectory = sessionDirectory.deletingLastPathComponent()
        let root = projectDirectory.deletingLastPathComponent()
        for directory in [root, projectDirectory, sessionDirectory] {
            guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory else {
                return nil
            }
        }
        // The session directory must itself contain a generation file; otherwise a
        // non-canonical ancestry would derive a bogus root and scan an unrelated tree.
        guard let members = try? fileManager.contentsOfDirectory(at: sessionDirectory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: []) else {
            return nil
        }
        var artifacts: [(url: URL, generation: Int, compression: DeepSeekHarnessCompression)] = []
        for member in members {
            guard !Task.isCancelled else { return nil }
            guard let parsed = parseGenerationFilename(member.lastPathComponent) else { continue }
            // A visible canonical generation that is not a regular file must
            // block revision resolution; silently skipping it could select an
            // older generation and publish stale telemetry.
            guard let attributes = try? fileManager.attributesOfItem(atPath: member.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular else { return nil }
            artifacts.append((member, parsed.generation, parsed.compression))
        }
        guard !artifacts.isEmpty,
              Set(artifacts.map { $0.compression }).count == 1 else { return nil }
        let sorted = artifacts.sorted {
            if $0.generation != $1.generation { return $0.generation > $1.generation }
            return $0.url.path < $1.url.path
        }
        guard let selected = sorted.first,
              !sorted.dropFirst().contains(where: { $0.generation == selected.generation }) else {
            return nil
        }

        let header: DeepSeekHarnessHeader
        do {
            header = try DeepSeekHarnessArtifactReader.readHeader(
                url: selected.url, compression: selected.compression)
        } catch {
            return nil
        }
        guard header.version == selected.generation else { return nil }
        let canonical = canonicalGenerationURL(root: root,
                                               cwd: header.cwd,
                                               id: header.id,
                                               version: header.version,
                                               compression: selected.compression)
        let canonicalPath = canonical.standardizedFileURL
        let selectedPath = selected.url.standardizedFileURL
        guard canonicalPath == selectedPath
                || canonicalPath.resolvingSymlinksInPath() == selectedPath.resolvingSymlinksInPath()
        else { return nil }

        let siblings = sorted.map { $0.url }
        guard let manifestRevision = try? manifestRevision(siblings: siblings),
              let stat = SessionFileStat.from(selected.url) else { return nil }
        return SessionArtifactRevision(selectedURL: selected.url,
                                       manifestRevision: manifestRevision,
                                       physicalStat: stat)
    }

    private func directChildren(of directory: URL) throws -> [URL] {
        try directoryContents(directory)
    }

    private func fileType(_ url: URL) throws -> FileAttributeType {
        let attributes = try itemAttributes(url.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw CocoaError(.fileReadUnknown)
        }
        return type
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue)
    }

    private static func manifestRevision(siblings: [URL]) throws -> String {
        let canonicalSiblings = siblings.sorted { lhs, rhs in
            if lhs.lastPathComponent != rhs.lastPathComponent {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhs.standardizedFileURL.path < rhs.standardizedFileURL.path
        }
        var rows: [String] = []
        rows.reserveCapacity(canonicalSiblings.count)
        for url in canonicalSiblings {
            try checkCancellation()
            guard let stat = SessionFileStat.precise(from: url) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let contentFingerprint = try manifestContentFingerprint(for: url, stat: stat)
            rows.append("\(url.lastPathComponent)\u{0}\(stat.mtime)\u{0}\(stat.size)\u{0}\(stat.fingerprint ?? "")\u{0}\(contentFingerprint)")
        }
        let serialized = rows.joined(separator: "\n")
        return SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestContentFingerprint(for url: URL, stat expectedStat: SessionFileStat) throws -> String {
        try checkCancellation()
        guard expectedStat.size >= 0,
              expectedStat.size <= Int64(DeepSeekHarnessArtifactReader.maxBytes) else {
            throw DeepSeekHarnessFormatError.limitsExceeded("manifest artifact bytes")
        }
        let key = url.standardizedFileURL.path
        contentFingerprintCacheLock.lock()
        let cached = contentFingerprintCache[key]
        contentFingerprintCacheLock.unlock()
        if let cached, cached.stat == expectedStat {
            return cached.value
        }

        #if DEBUG
        testManifestFingerprintBeforeOpenObserver?(url)
        #endif
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if DEBUG
        testManifestFingerprintAfterOpenObserver?(url)
        #endif
        let descriptor = handle.fileDescriptor
        guard SessionFileStat.precise(fromFileDescriptor: descriptor) == expectedStat else {
            throw DeepSeekHarnessFormatError.staleAnchor
        }
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            guard bytesRead <= Int64(DeepSeekHarnessArtifactReader.maxBytes) else {
                throw DeepSeekHarnessFormatError.limitsExceeded("manifest artifact bytes")
            }
            hasher.update(data: chunk)
#if DEBUG
            testManifestFingerprintHashObserver?(url)
#endif
        }
        guard SessionFileStat.precise(fromFileDescriptor: descriptor) == expectedStat,
              let finalStat = SessionFileStat.precise(from: url), finalStat == expectedStat else {
            throw DeepSeekHarnessFormatError.staleAnchor
        }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        contentFingerprintCacheLock.lock()
        if contentFingerprintCache.count >= contentFingerprintCacheLimit,
           contentFingerprintCache[key] == nil,
           let evictedKey = contentFingerprintCache.keys.first {
            contentFingerprintCache.removeValue(forKey: evictedKey)
        }
        contentFingerprintCache[key] = CachedContentFingerprint(stat: expectedStat, value: value)
        contentFingerprintCacheLock.unlock()
        return value
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSafeASCII(_ unit: UInt16) -> Bool {
        unit == 0x2D || unit == 0x2E || unit == 0x5F ||
            (unit >= 0x30 && unit <= 0x39) ||
            (unit >= 0x41 && unit <= 0x5A) ||
            (unit >= 0x61 && unit <= 0x7A)
    }

    private static func expand(_ path: String, homeDirectory: URL) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}
