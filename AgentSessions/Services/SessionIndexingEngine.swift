import Foundation

enum IndexRefreshMode: Equatable {
    case incremental
    case fullReconcile
}

enum IndexRefreshTrigger: String, Equatable {
    case launch
    case monitor
    case manual
    case providerEnabled
    case cleanup
}

struct IndexRefreshExecutionProfile: Equatable {
    var workerCount: Int
    var sliceSize: Int
    var interSliceYieldNanoseconds: UInt64
    var deferNonCriticalWork: Bool

    static let interactive = IndexRefreshExecutionProfile(
        workerCount: 2,
        sliceSize: 12,
        interSliceYieldNanoseconds: 20_000_000,
        deferNonCriticalWork: false
    )

    static let lightBackground = IndexRefreshExecutionProfile(
        workerCount: 1,
        sliceSize: 4,
        interSliceYieldNanoseconds: 80_000_000,
        deferNonCriticalWork: true
    )
}

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
                var workerCount: Int
                var sliceSize: Int
                var interSliceYieldNanoseconds: UInt64
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
                    workerCount: Int = 1,
                    sliceSize: Int = 12,
                    interSliceYieldNanoseconds: UInt64 = 20_000_000,
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
                    self.workerCount = max(1, workerCount)
                    self.sliceSize = max(1, sliceSize)
                    self.interSliceYieldNanoseconds = interSliceYieldNanoseconds
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
            var processed = 0
            var processedSinceYield = 0
            while processed < files.count {
                if !config.shouldContinue() { break }
                if Task.isCancelled { break }

                let end = min(processed + config.workerCount, files.count)
                let batchStart = processed
                let batch = Array(files[batchStart..<end])
                var parsedBatch: [(index: Int, url: URL, session: Session)] = []

                await withTaskGroup(of: (Int, URL, Session?).self) { group in
                    for (offset, url) in batch.enumerated() {
                        let absoluteIndex = batchStart + offset
                        group.addTask {
                            guard config.shouldParseFile(url) else {
                                return (absoluteIndex, url, nil)
                            }
                            return (absoluteIndex, url, config.parseLightweight(url))
                        }
                    }

                    while let (index, url, session) = await group.next() {
                        if let session {
                            parsedBatch.append((index: index, url: url, session: session))
                        }
                    }
                }

                parsedBatch.sort { $0.index < $1.index }
                for parsed in parsedBatch {
                    sessions.append(parsed.session)
                    config.didParseSession(parsed.session, parsed.url)
                }

                for _ in batch {
                    processed += 1
                    processedSinceYield += 1
                    if config.shouldThrottleProgress {
                        if config.throttler.incrementAndShouldFlush() {
                            await config.onProgress(processed, files.count)
                        }
                    } else {
                        await config.onProgress(processed, files.count)
                    }
                }

                if config.interSliceYieldNanoseconds > 0,
                   processedSinceYield >= config.sliceSize,
                   processed < files.count {
                    processedSinceYield = 0
                    try? await Task.sleep(nanoseconds: config.interSliceYieldNanoseconds)
                }
            }

	        let sorted = sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        let final = config.shouldMergeArchives
            ? SessionArchiveManager.shared.mergePinnedArchiveFallbacks(into: sorted, source: config.source)
            : sorted
        return Result(kind: .scanned, sessions: final, totalFiles: files.count)
    }
}
