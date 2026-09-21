import Foundation

/// Everything the CLI needs to enumerate and read one source, taken from its descriptor in
/// `SessionSourceDescriptorCatalog`. Adding a source to the app therefore adds it here too.
struct SourceDriver {
    let source: SessionSource
    private let descriptor: SessionSourceDescriptor

    init?(_ descriptor: SessionSourceDescriptor) {
        // A source that can neither enumerate files nor list database rows has nothing for
        // a headless host to read.
        guard descriptor.makeDiscovery != nil || descriptor.listDatabaseSessions != nil else { return nil }
        self.source = descriptor.source
        self.descriptor = descriptor
    }

    func discoverFiles() -> [URL] {
        descriptor.makeDiscovery?(availabilityContext).discoverSessionFiles() ?? []
    }

    /// Lightweight rows for sources whose sessions live in a shared database; empty for
    /// file-backed sources.
    func databaseSessions() -> [Session] {
        descriptor.listDatabaseSessions?(availabilityContext) ?? []
    }

    func parseLight(_ url: URL) -> Session? {
        descriptor.parseLightweightByPath?(url) ?? descriptor.parseFullByPath?(url)
    }

    func parseFull(_ url: URL) -> Session? {
        descriptor.parseFullByPath?(url)
    }

    /// Full load of one session by its stable ID, for sources that share a storage path.
    func loadByID(_ url: URL, _ sessionID: String) -> Session? {
        descriptor.parseFullByIdentity?(url, sessionID)
    }

    var usesIdentity: Bool { descriptor.parseFullByIdentity != nil }
}

let drivers: [SourceDriver] = SessionSourceDescriptorCatalog.ordered.compactMap(SourceDriver.init)

func driver(named name: String) -> SourceDriver? {
    drivers.first { $0.source.rawValue == name }
}

/// The seams descriptor closures probe the filesystem through. `AvailabilityContext.live`
/// is app-only (it reaches the app's memoized PATH cache), so the CLI builds its own with
/// a plain PATH scan.
let availabilityContext = AvailabilityContext(
    defaults: .standard,
    fileProbe: DefaultFileProbe(),
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    environment: ProcessInfo.processInfo.environment,
    detectBinary: binaryOnPath
)

func binaryOnPath(_ name: String) -> Bool {
    let fm = FileManager.default
    if name.contains("/") { return fm.isExecutableFile(atPath: (name as NSString).expandingTildeInPath) }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains { dir in
        fm.isExecutableFile(atPath: "\(dir)/\(name)")
    }
}
