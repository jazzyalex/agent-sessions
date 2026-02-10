import Foundation

#if DEBUG
enum CrashReportStoreTestHooks {
    static var applicationSupportDirectoryProvider: (() -> URL?)?
}
#endif

enum CrashReportStoreError: Error {
    case applicationSupportUnavailable
    case nothingToExport
}

actor CrashReportStore {
    private let fileManager: FileManager
    private let pendingFileURL: URL
    private let maxPendingCount: Int
    private var cachedPending: [CrashReportEnvelope]?

    init(fileManager: FileManager = .default,
         pendingFileURL: URL? = nil,
         maxPendingCount: Int = 50) {
        self.fileManager = fileManager
        if let pendingFileURL {
            self.pendingFileURL = pendingFileURL
        } else {
            self.pendingFileURL = CrashReportStore.defaultPendingFileURL(fileManager: fileManager)
                ?? fileManager.temporaryDirectory.appendingPathComponent("AgentSessions/CrashReports/pending.json", isDirectory: false)
        }
        self.maxPendingCount = maxPendingCount
    }

    static func defaultPendingFileURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = resolveApplicationSupportDirectoryURL(fileManager: fileManager) else { return nil }
        return appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("CrashReports", isDirectory: true)
            .appendingPathComponent("pending.json", isDirectory: false)
    }

    static func resolveApplicationSupportDirectoryURL(fileManager: FileManager) -> URL? {
#if DEBUG
        if let provider = CrashReportStoreTestHooks.applicationSupportDirectoryProvider {
            return provider()
        }
#endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    func pending() async -> [CrashReportEnvelope] {
        await ensureLoaded()
        return cachedPending ?? []
    }

    func pendingCount() async -> Int {
        await ensureLoaded()
        return cachedPending?.count ?? 0
    }

    func latestDetectedAt() async -> Date? {
        await ensureLoaded()
        return cachedPending?.first?.detectedAt
    }

    func enqueue(_ envelope: CrashReportEnvelope) async {
        await enqueue(contentsOf: [envelope])
    }

    func enqueue(contentsOf envelopes: [CrashReportEnvelope]) async {
        guard !envelopes.isEmpty else { return }
        await ensureLoaded()

        var merged = cachedPending ?? []
        var seen = Set(merged.map(\.id))
        var didChange = false

        for envelope in envelopes {
            if seen.insert(envelope.id).inserted {
                merged.append(envelope)
                didChange = true
            }
        }

        guard didChange else { return }

        merged.sort { $0.detectedAt > $1.detectedAt }
        if merged.count > maxPendingCount {
            merged = Array(merged.prefix(maxPendingCount))
        }
        cachedPending = merged
        persistPending(merged)
    }

    func remove(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        await ensureLoaded()
        let existing = cachedPending ?? []
        let filtered = existing.filter { !ids.contains($0.id) }
        guard filtered.count != existing.count else { return }
        cachedPending = filtered
        persistPending(filtered)
    }

    func clear() async {
        await ensureLoaded()
        cachedPending = []
        persistPending([])
    }

    func contains(id: String) async -> Bool {
        await ensureLoaded()
        return cachedPending?.contains(where: { $0.id == id }) ?? false
    }

    private func ensureLoaded() async {
        guard cachedPending == nil else { return }
        cachedPending = loadPendingFromDisk()
    }

    private func loadPendingFromDisk() -> [CrashReportEnvelope] {
        guard fileManager.fileExists(atPath: pendingFileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: pendingFileURL) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let decoded = try? decoder.decode([CrashReportEnvelope].self, from: data) {
            return decoded.sorted { $0.detectedAt > $1.detectedAt }
        }

        let backupURL = pendingFileURL.deletingLastPathComponent()
            .appendingPathComponent("pending.corrupt.\(Int(Date().timeIntervalSince1970)).json", isDirectory: false)
        try? fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: pendingFileURL, to: backupURL)
        return []
    }

    private func persistPending(_ pending: [CrashReportEnvelope]) {
        let parent = pendingFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(pending) else { return }
        try? data.write(to: pendingFileURL, options: [.atomic])
    }
}
