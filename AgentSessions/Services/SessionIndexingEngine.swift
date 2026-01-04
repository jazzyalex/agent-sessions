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
	        var shouldParseFile: (URL) -> Bool
	        var parseLightweight: (URL) -> Session?
	        var shouldThrottleProgress: Bool
	        var throttler: ProgressThrottler
	        var shouldContinue: () -> Bool
	        var shouldMergeArchives: Bool
	        var onProgress: @MainActor (Int, Int) -> Void
	        var didParseSession: (Session, URL) -> Void

	        init(
	            source: SessionSource,
	            discoverFiles: @escaping () -> [URL],
	            shouldParseFile: @escaping (URL) -> Bool = { _ in true },
	            parseLightweight: @escaping (URL) -> Session?,
	            shouldThrottleProgress: Bool,
	            throttler: ProgressThrottler,
	            shouldContinue: @escaping () -> Bool = { true },
	            shouldMergeArchives: Bool = true,
	            onProgress: @escaping @MainActor (Int, Int) -> Void,
	            didParseSession: @escaping (Session, URL) -> Void = { _, _ in }
	        ) {
	            self.source = source
	            self.discoverFiles = discoverFiles
	            self.shouldParseFile = shouldParseFile
	            self.parseLightweight = parseLightweight
	            self.shouldThrottleProgress = shouldThrottleProgress
	            self.throttler = throttler
	            self.shouldContinue = shouldContinue
	            self.shouldMergeArchives = shouldMergeArchives
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
	        await config.onProgress(0, files.count)

        var sessions: [Session] = []
        sessions.reserveCapacity(files.count)

        for (index, url) in files.enumerated() {
            if !config.shouldContinue() { break }
            if Task.isCancelled { break }
            if config.shouldParseFile(url) {
                if let session = config.parseLightweight(url) {
                    sessions.append(session)
                    config.didParseSession(session, url)
                }
            }

	            if config.shouldThrottleProgress {
	                if config.throttler.incrementAndShouldFlush() {
	                    await config.onProgress(index + 1, files.count)
	                }
	            } else {
	                await config.onProgress(index + 1, files.count)
	            }
	        }

        let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        let final = config.shouldMergeArchives
            ? SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: config.source)
            : sorted
        return Result(kind: .scanned, sessions: final, totalFiles: files.count)
    }
}
