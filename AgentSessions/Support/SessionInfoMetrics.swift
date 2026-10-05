import Foundation

/// A point-in-time, process-local snapshot of Session Info performance.
public struct SessionInfoMetricsSnapshot: Equatable, Sendable {
    public let modelFirstPaintCount: Int
    public let modelFirstPaintTotalMilliseconds: Double
    public let telemetryRequestCount: Int
    public let telemetryDurationTotalMilliseconds: Double
    public let telemetryBytesScanned: UInt64
    public let cacheHitCount: Int
    public let inFlightJoinCount: Int
    public let duplicateParseCount: Int
    public let transcriptTelemetryOverlapCount: Int

    public init(
        modelFirstPaintCount: Int = 0,
        modelFirstPaintTotalMilliseconds: Double = 0,
        telemetryRequestCount: Int = 0,
        telemetryDurationTotalMilliseconds: Double = 0,
        telemetryBytesScanned: UInt64 = 0,
        cacheHitCount: Int = 0,
        inFlightJoinCount: Int = 0,
        duplicateParseCount: Int = 0,
        transcriptTelemetryOverlapCount: Int = 0
    ) {
        self.modelFirstPaintCount = modelFirstPaintCount
        self.modelFirstPaintTotalMilliseconds = modelFirstPaintTotalMilliseconds
        self.telemetryRequestCount = telemetryRequestCount
        self.telemetryDurationTotalMilliseconds = telemetryDurationTotalMilliseconds
        self.telemetryBytesScanned = telemetryBytesScanned
        self.cacheHitCount = cacheHitCount
        self.inFlightJoinCount = inFlightJoinCount
        self.duplicateParseCount = duplicateParseCount
        self.transcriptTelemetryOverlapCount = transcriptTelemetryOverlapCount
    }
}

/// Lock-guarded instrumentation for the two Session Info paths.
///
/// The singleton is the production sink. Tests and future benchmarks can use a
/// separate instance so counters never leak across cases.
public final class SessionInfoMetrics: @unchecked Sendable {
    public static let shared = SessionInfoMetrics()

    private let lock = NSLock()
    private var values = SessionInfoMetricsSnapshot()
    private var activeTranscriptPathCounts = [String: Int]()
    private var activeTelemetryPathCounts = [String: Int]()

    public init() {}

    public var snapshot: SessionInfoMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public func reset() {
        lock.lock()
        values = SessionInfoMetricsSnapshot()
        // Preserve active lifetimes. A diagnostic reset can happen while a
        // parse is in flight; forgetting those references would make the next
        // opposite-side begin miss a real overlap and make its end unbalanced.
        lock.unlock()
    }

    public func recordModelFirstPaint(duration: TimeInterval) {
        lock.lock()
        values = SessionInfoMetricsSnapshot(
            modelFirstPaintCount: values.modelFirstPaintCount + 1,
            modelFirstPaintTotalMilliseconds: values.modelFirstPaintTotalMilliseconds + Self.milliseconds(duration),
            telemetryRequestCount: values.telemetryRequestCount,
            telemetryDurationTotalMilliseconds: values.telemetryDurationTotalMilliseconds,
            telemetryBytesScanned: values.telemetryBytesScanned,
            cacheHitCount: values.cacheHitCount,
            inFlightJoinCount: values.inFlightJoinCount,
            duplicateParseCount: values.duplicateParseCount,
            transcriptTelemetryOverlapCount: values.transcriptTelemetryOverlapCount)
        lock.unlock()
    }

    public func recordTelemetryFinished(duration: TimeInterval, bytesScanned: UInt64) {
        lock.lock()
        values = SessionInfoMetricsSnapshot(
            modelFirstPaintCount: values.modelFirstPaintCount,
            modelFirstPaintTotalMilliseconds: values.modelFirstPaintTotalMilliseconds,
            telemetryRequestCount: values.telemetryRequestCount + 1,
            telemetryDurationTotalMilliseconds: values.telemetryDurationTotalMilliseconds + Self.milliseconds(duration),
            telemetryBytesScanned: values.telemetryBytesScanned + bytesScanned,
            cacheHitCount: values.cacheHitCount,
            inFlightJoinCount: values.inFlightJoinCount,
            duplicateParseCount: values.duplicateParseCount,
            transcriptTelemetryOverlapCount: values.transcriptTelemetryOverlapCount)
        lock.unlock()
    }

    public func recordCacheHit() {
        update { snapshot in
            SessionInfoMetricsSnapshot(
                modelFirstPaintCount: snapshot.modelFirstPaintCount,
                modelFirstPaintTotalMilliseconds: snapshot.modelFirstPaintTotalMilliseconds,
                telemetryRequestCount: snapshot.telemetryRequestCount,
                telemetryDurationTotalMilliseconds: snapshot.telemetryDurationTotalMilliseconds,
                telemetryBytesScanned: snapshot.telemetryBytesScanned,
                cacheHitCount: snapshot.cacheHitCount + 1,
                inFlightJoinCount: snapshot.inFlightJoinCount,
                duplicateParseCount: snapshot.duplicateParseCount,
                transcriptTelemetryOverlapCount: snapshot.transcriptTelemetryOverlapCount)
        }
    }

    public func recordInFlightJoin() {
        update { snapshot in
            SessionInfoMetricsSnapshot(
                modelFirstPaintCount: snapshot.modelFirstPaintCount,
                modelFirstPaintTotalMilliseconds: snapshot.modelFirstPaintTotalMilliseconds,
                telemetryRequestCount: snapshot.telemetryRequestCount,
                telemetryDurationTotalMilliseconds: snapshot.telemetryDurationTotalMilliseconds,
                telemetryBytesScanned: snapshot.telemetryBytesScanned,
                cacheHitCount: snapshot.cacheHitCount,
                inFlightJoinCount: snapshot.inFlightJoinCount + 1,
                duplicateParseCount: snapshot.duplicateParseCount,
                transcriptTelemetryOverlapCount: snapshot.transcriptTelemetryOverlapCount)
        }
    }

    public func recordDuplicateParse() {
        update { snapshot in
            SessionInfoMetricsSnapshot(
                modelFirstPaintCount: snapshot.modelFirstPaintCount,
                modelFirstPaintTotalMilliseconds: snapshot.modelFirstPaintTotalMilliseconds,
                telemetryRequestCount: snapshot.telemetryRequestCount,
                telemetryDurationTotalMilliseconds: snapshot.telemetryDurationTotalMilliseconds,
                telemetryBytesScanned: snapshot.telemetryBytesScanned,
                cacheHitCount: snapshot.cacheHitCount,
                inFlightJoinCount: snapshot.inFlightJoinCount,
                duplicateParseCount: snapshot.duplicateParseCount + 1,
                transcriptTelemetryOverlapCount: snapshot.transcriptTelemetryOverlapCount)
        }
    }

    /// Marks a full transcript parse. If telemetry is already scanning the same
    /// path, this is one observed overlap event.
    public func beginTranscript(path: String) {
        lock.lock()
        if activeTranscriptPathCounts[path, default: 0] == 0,
           activeTelemetryPathCounts[path, default: 0] > 0 {
            values = Self.incrementOverlap(values)
        }
        activeTranscriptPathCounts[path, default: 0] += 1
        lock.unlock()
    }

    public func endTranscript(path: String) {
        lock.lock()
        Self.decrement(path: path, in: &activeTranscriptPathCounts)
        lock.unlock()
    }

    /// Marks a telemetry scan. If a transcript is already parsing the same
    /// path, this is one observed overlap event.
    public func beginTelemetry(path: String) {
        lock.lock()
        if activeTelemetryPathCounts[path, default: 0] == 0,
           activeTranscriptPathCounts[path, default: 0] > 0 {
            values = Self.incrementOverlap(values)
        }
        activeTelemetryPathCounts[path, default: 0] += 1
        lock.unlock()
    }

    public func endTelemetry(path: String) {
        lock.lock()
        Self.decrement(path: path, in: &activeTelemetryPathCounts)
        lock.unlock()
    }

    private static func decrement(path: String, in counts: inout [String: Int]) {
        guard let count = counts[path] else { return }
        if count <= 1 {
            counts.removeValue(forKey: path)
        } else {
            counts[path] = count - 1
        }
    }

    private func update(_ transform: (SessionInfoMetricsSnapshot) -> SessionInfoMetricsSnapshot) {
        lock.lock()
        values = transform(values)
        lock.unlock()
    }

    private static func incrementOverlap(_ snapshot: SessionInfoMetricsSnapshot) -> SessionInfoMetricsSnapshot {
        SessionInfoMetricsSnapshot(
            modelFirstPaintCount: snapshot.modelFirstPaintCount,
            modelFirstPaintTotalMilliseconds: snapshot.modelFirstPaintTotalMilliseconds,
            telemetryRequestCount: snapshot.telemetryRequestCount,
            telemetryDurationTotalMilliseconds: snapshot.telemetryDurationTotalMilliseconds,
            telemetryBytesScanned: snapshot.telemetryBytesScanned,
            cacheHitCount: snapshot.cacheHitCount,
            inFlightJoinCount: snapshot.inFlightJoinCount,
            duplicateParseCount: snapshot.duplicateParseCount,
            transcriptTelemetryOverlapCount: snapshot.transcriptTelemetryOverlapCount + 1)
    }

    private static func milliseconds(_ duration: TimeInterval) -> Double {
        max(0, duration) * 1_000
    }
}
