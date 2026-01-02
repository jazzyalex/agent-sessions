import Foundation

enum SessionIndexingEngine {
    struct Result {
        enum Kind {
            case hydrated
            case scanned
        }

        var kind: Kind
        var sessions: [Session]
        var totalFiles: Int
    }

    struct ScanConfig {
        var source: SessionSource
        var discoverFiles: () -> [URL]
        var parseLightweight: (URL) -> Session?
        var shouldThrottleProgress: Bool
        var throttler: ProgressThrottler
        var onProgress: (Int, Int) -> Void
        var didParseSession: (Session, URL) -> Void

        init(
            source: SessionSource,
            discoverFiles: @escaping () -> [URL],
            parseLightweight: @escaping (URL) -> Session?,
            shouldThrottleProgress: Bool,
            throttler: ProgressThrottler,
            onProgress: @escaping (Int, Int) -> Void,
            didParseSession: @escaping (Session, URL) -> Void = { _, _ in }
        ) {
            self.source = source
            self.discoverFiles = discoverFiles
            self.parseLightweight = parseLightweight
            self.shouldThrottleProgress = shouldThrottleProgress
            self.throttler = throttler
            self.onProgress = onProgress
            self.didParseSession = didParseSession
        }
    }

    static func hydrateOrScan(
        hydrate: (() async throws -> [Session]?)? = nil,
        hydrateRetryDelayNanoseconds: UInt64 = 250_000_000,
        config: ScanConfig
    ) async -> Result {
        if let hydrate {
            var indexed = (try? await hydrate()) ?? nil
            if indexed?.isEmpty ?? true {
                try? await Task.sleep(nanoseconds: hydrateRetryDelayNanoseconds)
                indexed = (try? await hydrate()) ?? nil
            }
            if let indexed, !indexed.isEmpty {
                return Result(kind: .hydrated, sessions: indexed, totalFiles: indexed.count)
            }
        }

        let files = config.discoverFiles()
        config.onProgress(0, files.count)

        var sessions: [Session] = []
        sessions.reserveCapacity(files.count)

        for (index, url) in files.enumerated() {
            if Task.isCancelled { break }
            if let session = config.parseLightweight(url) {
                sessions.append(session)
                config.didParseSession(session, url)
            }

            if config.shouldThrottleProgress {
                if config.throttler.incrementAndShouldFlush() {
                    config.onProgress(index + 1, files.count)
                }
            } else {
                config.onProgress(index + 1, files.count)
            }
        }

        let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: config.source)
        return Result(kind: .scanned, sessions: mergedWithArchives, totalFiles: files.count)
    }
}
