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

/// Stable activity identity for a session-backed source. Unlike a database
/// path, this distinguishes two sessions that share one SQLite file without
/// exporting filesystem locations in metrics.
public struct SessionInfoMetricsIdentity: Hashable, Sendable {
    public let source: SessionSource
    public let sessionID: String

    public init(source: SessionSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
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
    private enum ActivityIdentity: Hashable {
        case path(String)
        case session(SessionInfoMetricsIdentity)
    }
    private var activeTranscriptCounts = [ActivityIdentity: Int]()
    private var activeTelemetryCounts = [ActivityIdentity: Int]()
    private let loggingEnabled: Bool

    public init() {
        loggingEnabled = ProcessInfo.processInfo.environment["AS_SESSION_INFO_METRICS"] == "1"
    }

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
        emitSnapshot(label: "reset")
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
        emitSnapshot(label: "model_first_paint")
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
        emitSnapshot(label: "telemetry_finished")
    }

    /// Accounts for source-specific freshness work performed before the shared
    /// telemetry worker starts. It contributes to duration and bytes without
    /// pretending that a cache-key check was a second telemetry request.
    public func recordTelemetryPreparation(duration: TimeInterval, bytesScanned: UInt64) {
        lock.lock()
        values = SessionInfoMetricsSnapshot(
            modelFirstPaintCount: values.modelFirstPaintCount,
            modelFirstPaintTotalMilliseconds: values.modelFirstPaintTotalMilliseconds,
            telemetryRequestCount: values.telemetryRequestCount,
            telemetryDurationTotalMilliseconds: values.telemetryDurationTotalMilliseconds + Self.milliseconds(duration),
            telemetryBytesScanned: values.telemetryBytesScanned + bytesScanned,
            cacheHitCount: values.cacheHitCount,
            inFlightJoinCount: values.inFlightJoinCount,
            duplicateParseCount: values.duplicateParseCount,
            transcriptTelemetryOverlapCount: values.transcriptTelemetryOverlapCount)
        lock.unlock()
        emitSnapshot(label: "telemetry_preparation")
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
    /// artifact, this is one observed overlap event.
    public func beginTranscript(path: String) {
        beginTranscript(identity: .path(path))
    }

    public func beginTranscript(identity: SessionInfoMetricsIdentity) {
        beginTranscript(identity: .session(identity))
    }

    private func beginTranscript(identity: ActivityIdentity) {
        lock.lock()
        var recordedOverlap = false
        if activeTranscriptCounts[identity, default: 0] == 0,
           activeTelemetryCounts[identity, default: 0] > 0 {
            values = Self.incrementOverlap(values)
            recordedOverlap = true
        }
        activeTranscriptCounts[identity, default: 0] += 1
        lock.unlock()
        if recordedOverlap { emitSnapshot(label: "transcript_telemetry_overlap") }
    }

    public func endTranscript(path: String) {
        endTranscript(identity: .path(path))
    }

    public func endTranscript(identity: SessionInfoMetricsIdentity) {
        endTranscript(identity: .session(identity))
    }

    private func endTranscript(identity: ActivityIdentity) {
        lock.lock()
        Self.decrement(identity: identity, in: &activeTranscriptCounts)
        lock.unlock()
    }

    /// Marks a telemetry scan. If a transcript is already parsing the same
    /// artifact, this is one observed overlap event.
    public func beginTelemetry(path: String) {
        beginTelemetry(identity: .path(path))
    }

    public func beginTelemetry(identity: SessionInfoMetricsIdentity) {
        beginTelemetry(identity: .session(identity))
    }

    private func beginTelemetry(identity: ActivityIdentity) {
        lock.lock()
        var recordedOverlap = false
        if activeTelemetryCounts[identity, default: 0] == 0,
           activeTranscriptCounts[identity, default: 0] > 0 {
            values = Self.incrementOverlap(values)
            recordedOverlap = true
        }
        activeTelemetryCounts[identity, default: 0] += 1
        lock.unlock()
        if recordedOverlap { emitSnapshot(label: "transcript_telemetry_overlap") }
    }

    public func endTelemetry(path: String) {
        endTelemetry(identity: .path(path))
    }

    public func endTelemetry(identity: SessionInfoMetricsIdentity) {
        endTelemetry(identity: .session(identity))
    }

    private func endTelemetry(identity: ActivityIdentity) {
        lock.lock()
        Self.decrement(identity: identity, in: &activeTelemetryCounts)
        lock.unlock()
    }

    private static func decrement(identity: ActivityIdentity,
                                  in counts: inout [ActivityIdentity: Int]) {
        guard let count = counts[identity] else { return }
        if count <= 1 {
            counts.removeValue(forKey: identity)
        } else {
            counts[identity] = count - 1
        }
    }

    private func update(_ transform: (SessionInfoMetricsSnapshot) -> SessionInfoMetricsSnapshot) {
        lock.lock()
        values = transform(values)
        lock.unlock()
        emitSnapshot(label: "counter")
    }

    /// Emits a machine-readable process-local baseline when the app is launched
    /// with `AS_SESSION_INFO_METRICS=1`. This stays opt-in so normal users never
    /// receive a log stream, while manual smoke tests can collect live metrics
    /// without an in-process debugger or private UI.
    public func emitSnapshot(label: String = "snapshot") {
        guard loggingEnabled else { return }
        let snapshot = self.snapshot
        let averageModelPaint = snapshot.modelFirstPaintCount > 0
            ? snapshot.modelFirstPaintTotalMilliseconds / Double(snapshot.modelFirstPaintCount)
            : 0
        let averageTelemetry = snapshot.telemetryRequestCount > 0
            ? snapshot.telemetryDurationTotalMilliseconds / Double(snapshot.telemetryRequestCount)
            : 0
        let line = String(
            format: "[SessionInfoMetrics] event=%@ model_first_paint_count=%d model_first_paint_avg_ms=%.1f telemetry_count=%d telemetry_avg_ms=%.1f bytes_scanned=%llu cache_hits=%d inflight_joins=%d duplicate_parses=%d transcript_telemetry_overlap=%d",
            label,
            snapshot.modelFirstPaintCount,
            averageModelPaint,
            snapshot.telemetryRequestCount,
            averageTelemetry,
            snapshot.telemetryBytesScanned,
            snapshot.cacheHitCount,
            snapshot.inFlightJoinCount,
            snapshot.duplicateParseCount,
            snapshot.transcriptTelemetryOverlapCount)
        FileHandle.standardError.write(Data((line + "\n").utf8))
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
