import Foundation
import Observation

/// The OpenCode sessions one Quota Meter surface is showing: session ID → working.
struct OpenCodeRateDemand: Equatable, Sendable {
    let sessions: [String: Bool]
}

/// One published set of OpenCode row values. Every view reads the same snapshot.
struct OpenCodeRateSnapshot: Equatable, Sendable {
    let databasePath: String?
    let presentation: RunwayPresentation
    let demandRevision: UInt64
    let version: UInt64
    let values: [String: OpenCodeRateValue]

    static let empty = OpenCodeRateSnapshot(databasePath: nil, presentation: .fiveHour,
                                            demandRevision: 0, version: 0, values: [:])
}

/// Reads recent OpenCode usage for a batch of sessions. Production wraps
/// `OpenCodeSqliteReader.recentUsage`; tests substitute a fake.
protocol OpenCodeRecentUsageReading: Sendable {
    func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest],
                     now: Date) -> [String: OpenCodeRecentUsageResult]?
}

struct OpenCodeSqliteRecentUsageReader: OpenCodeRecentUsageReading {
    func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest],
                     now: Date) -> [String: OpenCodeRecentUsageResult]? {
        OpenCodeSqliteReader.recentUsage(databaseURL: databaseURL, requests: requests, now: now)
    }
}

/// Collects what every Quota Meter surface shows and publishes the sampler's
/// snapshot. Demand changes reach the sampler through one ordered stream, so a
/// newer hide is never overtaken by an older show.
@MainActor @Observable
final class OpenCodeRateStore {
    static let shared = OpenCodeRateStore()

    private(set) var snapshot: OpenCodeRateSnapshot = .empty
    /// Bumped on every demand change; the sampler checks it after each read.
    private(set) var currentDemandRevision: UInt64 = 0
    /// The sampler's mailbox; it has exactly one consumer.
    @ObservationIgnored let updates: AsyncStream<(UInt64, OpenCodeRateDemand?)>
    @ObservationIgnored private let continuation: AsyncStream<(UInt64, OpenCodeRateDemand?)>.Continuation
    @ObservationIgnored private var demands: [UUID: OpenCodeRateDemand] = [:]
    #if DEBUG
    @ObservationIgnored var onPublishForTesting: ((OpenCodeRateSnapshot) -> Void)?
    var demandUnionForTesting: OpenCodeRateDemand? { union }
    #endif

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: (UInt64, OpenCodeRateDemand?).self)
    }

    /// Ends the mailbox; the sampler then stops for good. Used by tests and teardown.
    func finishUpdates() {
        continuation.finish()
    }

    /// nil = this surface shows no OpenCode rates.
    func setDemand(_ surface: UUID, _ demand: OpenCodeRateDemand?) {
        demands[surface] = demand
        currentDemandRevision &+= 1
        continuation.yield((currentDemandRevision, union))
    }

    /// Sampler-only. Accepts a snapshot made under the current demand and newer
    /// than the last accepted one. Views redraw only when what they draw changed:
    /// the sampler publishes every cycle, mostly with the same values.
    func publish(_ snapshot: OpenCodeRateSnapshot) {
        guard snapshot.demandRevision == currentDemandRevision,
              snapshot.version > acceptedVersion else { return }
        acceptedVersion = snapshot.version
        let current = self.snapshot
        if snapshot.values != current.values || snapshot.presentation != current.presentation
            || snapshot.databasePath != current.databasePath || snapshot.demandRevision != current.demandRevision {
            self.snapshot = snapshot
        }
        #if DEBUG
        onPublishForTesting?(snapshot)
        #endif
    }

    @ObservationIgnored private var acceptedVersion: UInt64 = 0

    /// Every session any surface shows; working if any surface sees it working.
    private var union: OpenCodeRateDemand? {
        var sessions: [String: Bool] = [:]
        for demand in demands.values {
            for (id, working) in demand.sessions { sessions[id] = (sessions[id] ?? false) || working }
        }
        return sessions.isEmpty ? nil : OpenCodeRateDemand(sessions: sessions)
    }
}

/// The only code that reads OpenCode usage for the Quota Meter. One refresh loop,
/// one read at a time, running only while some surface shows OpenCode rates.
actor OpenCodeRateSampler {
    /// Re-read a session this long after its last read even if its tail is unchanged.
    static let forceReloadInterval: TimeInterval = 60

    private struct CacheKey: Hashable { let path: String; let sessionID: String }
    private struct CacheEntry {
        let tail: String?
        let lastRead: Date
        let window: OpenCodeRecentWindow?
        let activity: OpenCodeSessionActivity?
    }

    private let store: OpenCodeRateStore
    private let reader: OpenCodeRecentUsageReading
    private let clock: @Sendable () -> Date
    private let databaseURL: @Sendable () -> URL?
    private let presentation: @Sendable () -> RunwayPresentation
    private let prices: @Sendable () -> RunwayPriceSnapshot
    /// Fetches the price manifest. Called only in the $ lens, like the runway, so
    /// the token lens makes no network request.
    private let refreshPrices: @Sendable () -> Void
    private let cadence: TimeInterval

    private var demand: OpenCodeRateDemand?
    private var demandRevision: UInt64 = 0
    private var stopRequested = true
    private var loopTask: Task<Void, Never>?
    private var cache: [CacheKey: CacheEntry] = [:]
    private var lastPath: String?
    private var version: UInt64 = 0

    init(store: OpenCodeRateStore, reader: OpenCodeRecentUsageReading,
         clock: @escaping @Sendable () -> Date, databaseURL: @escaping @Sendable () -> URL?,
         presentation: @escaping @Sendable () -> RunwayPresentation,
         prices: @escaping @Sendable () -> RunwayPriceSnapshot,
         refreshPrices: @escaping @Sendable () -> Void = {},
         cadence: TimeInterval = 5) {
        self.store = store
        self.reader = reader
        self.clock = clock
        self.databaseURL = databaseURL
        self.presentation = presentation
        self.prices = prices
        self.refreshPrices = refreshPrices
        self.cadence = cadence
    }

    /// Consumes demand updates in order for the sampler's lifetime. When the
    /// mailbox ends there is no demand left, so the loop stops too.
    func run(updates: AsyncStream<(UInt64, OpenCodeRateDemand?)>) async {
        for await (revision, union) in updates {
            apply(revision: revision, demand: union)
        }
        stopRequested = true
        demand = nil
    }

    /// Records demand and wakes the loop. It never reads itself.
    private func apply(revision: UInt64, demand: OpenCodeRateDemand?) {
        demandRevision = revision
        self.demand = demand
        if demand == nil {
            // The loop stops after any in-flight read returns.
            stopRequested = true
        } else {
            stopRequested = false
            if loopTask == nil { loopTask = Task { await self.loop() } }
        }
    }

    private func loop() async {
        while true {
            await cycle()
            if stopRequested { loopTask = nil; return }
            try? await Task.sleep(nanoseconds: UInt64(cadence * 1_000_000_000))
            if stopRequested { loopTask = nil; return }
        }
    }

    private func cycle() async {
        guard let demand, let url = databaseURL() else { return }
        let path = url.standardizedFileURL.path
        let revision = demandRevision
        if path != lastPath {
            cache.removeAll()
            lastPath = path
            version &+= 1
            await store.publish(OpenCodeRateSnapshot(databasePath: path, presentation: presentation(),
                                                     demandRevision: revision, version: version, values: [:]))
        }
        let now = clock()
        let requests = demand.sessions.keys.sorted().map { id -> OpenCodeRecentUsageRequest in
            let entry = cache[CacheKey(path: path, sessionID: id)]
            let stale = entry.map { now.timeIntervalSince($0.lastRead) >= Self.forceReloadInterval } ?? false
            return OpenCodeRecentUsageRequest(sessionID: id, previousTail: entry?.tail, forceReload: stale)
        }
        let reader = self.reader
        let results = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: reader.recentUsage(databaseURL: url, requests: requests, now: now))
            }
        }
        // Use the store's live revision, not the last one taken from the mailbox:
        // newer updates may still be queued while the read was suspended.
        let liveRevision = await store.currentDemandRevision
        guard liveRevision == revision,
              databaseURL()?.standardizedFileURL.path == path else { return }

        if presentation() == .dollar { refreshPrices() }
        let snapshotPrices = prices()
        for id in demand.sessions.keys {
            let key = CacheKey(path: path, sessionID: id)
            switch results?[id] {
            case .loaded(let tail, let window):
                var activity: OpenCodeSessionActivity?
                if case .usage(let events) = window, let burst = OpenCodeSessionRate.burst(events) {
                    activity = OpenCodeSessionRate.activity(burst: burst, prices: snapshotPrices)
                }
                cache[key] = CacheEntry(tail: tail, lastRead: now, window: window, activity: activity)
            case .unchanged:
                break
            case .unreadable, .none:
                cache[key] = nil
            }
        }

        let valueTime = clock()
        let currentPresentation = presentation()
        let unit = OpenCodeSessionRate.unit(for: currentPresentation)
        var values: [String: OpenCodeRateValue] = [:]
        for (id, working) in demand.sessions {
            let entry = cache[CacheKey(path: path, sessionID: id)]
            values[id] = OpenCodeSessionRate.value(window: entry?.window, activity: entry?.activity,
                                                   isWorking: working, unit: unit, now: valueTime)
        }
        version &+= 1
        await store.publish(OpenCodeRateSnapshot(databasePath: path, presentation: currentPresentation,
                                                 demandRevision: revision, version: version, values: values))
    }
}

extension OpenCodeRateSampler {
    /// The app's sampler: the shared store, the real reader and the user's settings.
    @MainActor static func startShared() {
        guard !AppRuntime.isRunningTests, sharedTask == nil else { return }
        let store = OpenCodeRateStore.shared
        let sampler = OpenCodeRateSampler(
            store: store,
            reader: OpenCodeSqliteRecentUsageReader(),
            clock: { Date() },
            databaseURL: {
                let root = UserDefaults.standard.string(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
                return OpenCodeBackendDetector.dbURL(customRoot: root?.isEmpty == false ? root : nil)
            },
            presentation: {
                RunwayPresentation.current(raw: UserDefaults.standard.string(
                    forKey: PreferencesKey.quotaMeterRunwayPresentation) ?? "")
            },
            prices: { RunwayPriceTable.shared.snapshot() },
            refreshPrices: { RunwayPriceTable.shared.refreshInBackground() })
        let updates = store.updates
        sharedTask = Task { await sampler.run(updates: updates) }
    }

    @MainActor private static var sharedTask: Task<Void, Never>?
}
