import Foundation
import Darwin
import Observation
import CryptoKit

/// Only OpenCode process environments are inspected, and only storage/configuration
/// paths are retained. A Finder-launched app need not share a terminal's XDG roots.
struct OpenCodeRuntimeProfile: Hashable {
    let config: URL
    let state: URL
    let data: URL

    init(environment: [String: String], home: URL) {
        func path(_ key: String, fallback: URL) -> URL {
            guard let value = environment[key], value.hasPrefix("/") else { return fallback }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        let profileHome = path("HOME", fallback: home)
        config = path("OPENCODE_CONFIG_DIR", fallback:
            path("XDG_CONFIG_HOME", fallback: profileHome.appendingPathComponent(".config"))
                .appendingPathComponent("opencode"))
        state = path("XDG_STATE_HOME", fallback: profileHome.appendingPathComponent(".local/state"))
            .appendingPathComponent("opencode")
        data = path("XDG_DATA_HOME", fallback: profileHome.appendingPathComponent(".local/share"))
            .appendingPathComponent("opencode")
    }

    static func discover() -> Set<Self> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var profiles: Set<Self> = [Self(environment: [:], home: home),
                                   Self(environment: ProcessInfo.processInfo.environment, home: home)]
        // pgrep emits only PIDs. Bound the process and never log its environment.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "opencode(\\.exe)?", "-u", String(getuid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return profiles }
        guard done.wait(timeout: .now() + 1) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return profiles
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        for value in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).prefix(128) {
            guard let pid = Int32(value), let environment = environment(pid: pid) else { continue }
            profiles.insert(Self(environment: environment, home: home))
        }
        return profiles
    }

    static func environment(pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return nil }
        var offset = 4
        func next() -> String? {
            guard offset < size, let end = bytes[offset..<size].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(bytes: bytes[offset..<end], encoding: .utf8)
        }
        _ = next() // executable path, then padding, then argv
        while offset < size && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc { guard next() != nil else { return nil } }
        let allowed: Set<String> = ["HOME", "OPENCODE_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"]
        var result: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            if allowed.contains(key) { result[key] = String(entry[entry.index(after: separator)...]) }
        }
        return result
    }
}

/// Owns only its marked drop-in package. Existing configuration and other plugins
/// are never rewritten. Modified/colliding packages are preserved and reported.
struct OpenCodePresenceInstaller {
    static let packageName = "agent-sessions-presence"
    static let markerName = ".agent-sessions-managed.json"
    private static let owner = "com.triada.AgentSessions.opencode-presence"
    private static let names = ["package.json", "tui.js"]
    let payload: URL
    let retiredRoot: URL
    private let fm = FileManager.default

    private struct Manifest: Codable {
        let owner: String
        let hashes: [String: String]
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func package(_ root: URL) -> URL { root.appendingPathComponent("plugins/" + Self.packageName) }
    private func fail(_ path: URL) -> NSError {
        NSError(domain: "OpenCodePresenceIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Preserved an unrecognized or modified integration at \(path.path)."])
    }

    private func manifest(at directory: URL) throws -> Manifest {
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try directory.appendingPathComponent(Self.markerName).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.markerName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.owner == Self.owner, Set(manifest.hashes.keys) == Set(Self.names),
              Set(try fm.contentsOfDirectory(atPath: directory.path)) == Set(Self.names + [Self.markerName]) else {
            throw fail(directory)
        }
        for name in Self.names {
            let file = directory.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let data = try? Data(contentsOf: file), hash(data) == manifest.hashes[name] else { throw fail(directory) }
        }
        return manifest
    }

    @discardableResult
    func install(configRoot: URL) throws -> Bool {
        guard configRoot.path != "/" else { throw fail(configRoot) }
        let destination = package(configRoot)
        let files = try Dictionary(uniqueKeysWithValues: Self.names.map { name in
            (name, try Data(contentsOf: payload.appendingPathComponent(name)))
        })
        let expected = files.mapValues(hash)
        let exists = fm.fileExists(atPath: destination.path)
        if exists, try manifest(at: destination).hashes == expected { return false }
        let plugins = destination.deletingLastPathComponent()
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        // Stage outside the discovery directory; a watcher never sees a half package.
        let staged = configRoot.appendingPathComponent(".agent-sessions-presence-" + UUID().uuidString)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var exchanged = false
        defer {
            // A failed write/swap must not accumulate a fresh staging package on
            // every reconciliation. After a swap this path holds the old version.
            if !exchanged { try? fm.removeItem(at: staged) }
        }
        for (name, content) in files {
            let file = staged.appendingPathComponent(name)
            try content.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try JSONEncoder().encode(Manifest(owner: Self.owner, hashes: expected))
            .write(to: staged.appendingPathComponent(Self.markerName), options: .atomic)
        if exists {
            // Atomic directory exchange retains the previous version for recovery.
            let result = staged.path.withCString { stagedPath in
                destination.path.withCString { renamex_np(stagedPath, $0, UInt32(RENAME_SWAP)) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            exchanged = true
            try retire(staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        return true
    }

    func disable(configRoot: URL) throws {
        let destination = package(configRoot)
        guard fm.fileExists(atPath: destination.path) else { return }
        _ = try manifest(at: destination)
        try retire(destination)
    }

    private func retire(_ directory: URL) throws {
        try fm.createDirectory(at: retiredRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.moveItem(at: directory, to: retiredRoot.appendingPathComponent(UUID().uuidString))
    }
}

actor OpenCodePresenceIntegration {
    static let shared = OpenCodePresenceIntegration()
    private var profiles = Set<OpenCodeRuntimeProfile>()

    func stateRoots() -> [URL] {
        let defaults = OpenCodeRuntimeProfile(environment: ProcessInfo.processInfo.environment,
                                              home: FileManager.default.homeDirectoryForCurrentUser)
        return Array(Set(profiles.map(\.state) + [defaults.state]))
    }

    func reconcile(enabled: Bool, payload: URL?, support: URL,
                   discoveredProfiles: Set<OpenCodeRuntimeProfile>? = nil) -> String {
        let fm = FileManager.default
        profiles = discoveredProfiles ?? OpenCodeRuntimeProfile.discover()
        let record = support.appendingPathComponent("Integrations/opencode-managed-roots.json")
        let previous = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: record))) ?? []
        let available = profiles.filter { fm.fileExists(atPath: $0.config.path) || fm.fileExists(atPath: $0.data.path)
            || fm.fileExists(atPath: $0.state.path) }.map(\.config.path)
        let roots = Set(previous + available).filter { $0.hasPrefix("/") && $0 != "/" }
            .sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !enabled || payload != nil else { return "TUI integration unavailable: bundled files are missing." }
        guard !roots.isEmpty else {
            return enabled ? "TUI integration will install automatically when OpenCode is detected."
                : "TUI integration is inactive while live detection or OpenCode is disabled."
        }
        let installer = OpenCodePresenceInstaller(payload: payload ?? support,
                                                retiredRoot: support.appendingPathComponent("Integrations/RetiredOpenCode"))
        var errors: [String] = []
        var installedRoots = 0
        for root in roots {
            do {
                if enabled {
                    // Remembered roots support updates/removal, but must not
                    // resurrect deleted profiles after their clients have closed.
                    guard available.contains(root.path)
                        || fm.fileExists(atPath: root.appendingPathComponent("plugins/" + OpenCodePresenceInstaller.packageName).path) else { continue }
                    try installer.install(configRoot: root)
                    installedRoots += 1
                } else { try installer.disable(configRoot: root) }
            } catch { errors.append(error.localizedDescription) }
        }
        do {
            if previous != roots.map(\.path) {
                try fm.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(roots.map(\.path)).write(to: record, options: .atomic)
            }
        } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { return "TUI integration needs attention: " + errors.joined(separator: " ") }
        if enabled && installedRoots == 0 { return "TUI integration will install automatically when OpenCode is detected." }
        return enabled ? "TUI integration installed and managed automatically. OpenCode 2.x loads it in any terminal."
            : "TUI integration removed from OpenCode discovery while live detection or OpenCode is disabled."
    }
}

@MainActor @Observable
final class OpenCodePresenceIntegrationModel {
    static let shared = OpenCodePresenceIntegrationModel()
    private(set) var status = "Preparing the automatic TUI integration…"
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil, !AppRuntime.isRunningTests else { return }
        task = Task { [weak self] in
            await AppReadyGate.waitUntilReady()
            while !Task.isCancelled {
                let defaults = UserDefaults.standard
                let enabled = AgentEnablement.isEnabled(.opencode, defaults: defaults)
                    && (defaults.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool ?? true)
                let support = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/AgentSessions")
                let payload = Bundle.main.resourceURL?.appendingPathComponent("OpenCodePresence")
                self?.status = await OpenCodePresenceIntegration.shared.reconcile(enabled: enabled, payload: payload, support: support)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
