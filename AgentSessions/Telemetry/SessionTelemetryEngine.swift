import Foundation

/// On-demand telemetry for one session.
///
/// Telemetry is not stored on `Session`, not in SQLite, and NOT derived from
/// hydrated `SessionEvent`s: both transcript parsers truncate `rawJSON` (Claude at
/// 8 KB, Codex sanitizes lines over 100 KB), so `message.usage` on a large assistant
/// line is already gone by the time events exist. The file is therefore re-read.
///
/// Recompute is a FULL re-read, so callers must not poll this on a timer — a live
/// session's file signature changes on every append. It is built for "the user
/// selected this session and wants its numbers".
///
/// `@unchecked Sendable`: lock-guarded mutable cache, mirroring `RunwayPriceTable`.
final class SessionTelemetryEngine: @unchecked Sendable {
    static let shared = SessionTelemetryEngine()

    /// One selected transcript at a time in practice; sized generously so revisiting
    /// a handful of sessions stays instant.
    private static let cacheCapacity = 16

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    /// Least-recently-used last.
    private var order: [String] = []
    private let priceTable: RunwayPriceTable

    /// The sources `compute` can actually dispatch. A source whose descriptor
    /// declares telemetry available but is missing here returns nil forever, and
    /// silently — the `default` arm cannot tell that case from a source that
    /// correctly declares nothing. `SessionTelemetryEngineTests` asserts this set
    /// matches the descriptors, so adding a provider cannot half-land.
    static let dispatchableSources: Set<SessionSource> = [.codex, .claude, .pi, .copilot]

    /// Counts full parses, so cache tests can prove a second call did no work.
    private var _parseCount = 0
    /// Lock-guarded: `compute` runs on a detached task, so an unsynchronized read
    /// from the test thread is a data race even though the value is only a counter.
    var parseCount: Int { lock.lock(); defer { lock.unlock() }; return _parseCount }

    init(priceTable: RunwayPriceTable = .shared) {
        self.priceTable = priceTable
    }

    private struct Entry {
        let signature: RunwayFileSignature
        let parserVersion: Int
        let telemetry: SessionTelemetry
    }

    /// nil when the source cannot produce telemetry, or the file is unreadable.
    func telemetry(for session: Session) async -> SessionTelemetry? {
        let capabilities = SessionSourceRegistry.descriptor(for: session.source).telemetry
        // Capability-gated rather than a hardcoded provider list: adding a provider
        // later is a descriptor edit plus an accumulator, with no change here.
        guard capabilities.configuration.isAvailable || capabilities.tokens.isAvailable else { return nil }

        let path = session.filePath
        guard !path.isEmpty else { return nil }

        // A nil signature means the file is missing or unstat-able. Bypass the cache
        // entirely rather than risk serving a stale result for a file we cannot check.
        guard let signature = RunwayFileSignature.read(path: path) else { return nil }
        if let cached = cachedTelemetry(path: path, signature: signature) { return cached }

        let source = session.source
        let priceTable = self.priceTable
        let computed = await Task.detached(priority: .utility) { [weak self] in
            self?.compute(path: path, source: source, capabilities: capabilities, priceTable: priceTable)
        }.value

        guard let computed else { return nil }
        store(computed, path: path, signature: signature)
        return computed
    }

    // MARK: - Computation

    private func compute(path: String,
                         source: SessionSource,
                         capabilities: TelemetryCapabilities,
                         priceTable: RunwayPriceTable) -> SessionTelemetry? {
        let url = URL(fileURLWithPath: path)
        var telemetry: SessionTelemetry?

        // Streamed, never materialized: the largest local Codex rollout is 256 MB.
        switch source {
        case .codex:
            var accumulator = CodexTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .claude:
            var accumulator = ClaudeTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .pi:
            var accumulator = PiTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .copilot:
            var accumulator = CopilotTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        default:
            return nil
        }

        guard let base = telemetry else { return nil }
        lock.lock(); _parseCount += 1; lock.unlock()

        // Pricing needs both permission and component tokens: a legacy total-only
        // transcript reports a token count but can never be priced.
        guard capabilities.cost.isAvailable, base.usageSummary?.hasComponentBreakdown == true else {
            return base
        }
        let cost = TelemetryCostCalculator.estimate(slices: base.usageSlices, priceTable: priceTable)
        return SessionTelemetry(source: base.source,
                                initialConfiguration: base.initialConfiguration,
                                currentConfiguration: base.currentConfiguration,
                                configurationChanges: base.configurationChanges,
                                usageSlices: base.usageSlices,
                                usageSummary: base.usageSummary,
                                costEstimate: cost,
                                parserVersion: base.parserVersion)
    }

    /// Feeds the shared JSONL reader's emitted records, numbering them as it goes.
    /// That numbering is what `anchorLine` refers to — the reader drops blank lines,
    /// so it is a record index, not a raw file line.
    private func streamLines(at url: URL, into consume: (String, Int) -> Void) -> Bool {
        var index = 0
        do {
            try JSONLReader(url: url).forEachLine { line in
                consume(line, index)
                index += 1
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Cache

    private func cachedTelemetry(path: String, signature: RunwayFileSignature) -> SessionTelemetry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[path],
              entry.signature == signature,
              entry.parserVersion == SessionTelemetry.parserVersion else { return nil }
        touch(path)
        return entry.telemetry
    }

    private func store(_ telemetry: SessionTelemetry, path: String, signature: RunwayFileSignature) {
        lock.lock(); defer { lock.unlock() }
        cache[path] = Entry(signature: signature,
                            parserVersion: SessionTelemetry.parserVersion,
                            telemetry: telemetry)
        touch(path)
        while order.count > Self.cacheCapacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    /// Caller holds `lock`.
    private func touch(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }
}
