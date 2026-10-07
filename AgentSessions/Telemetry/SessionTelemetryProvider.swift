import Foundation

/// The result of one source-specific telemetry parse.
///
/// Providers own only transcript-format knowledge. Cache invalidation, pricing,
/// quota attribution, and cancellation remain in `SessionTelemetryEngine`.
struct SessionTelemetryProviderResult: Sendable {
    let telemetry: SessionTelemetry
    let durableAccountHash: String?
}

/// Revision identity for one telemetry input. File-backed providers use the
/// physical signature; shared databases use a logical session revision so two
/// sessions in the same database cannot collide in the cache.
enum SessionTelemetryRevision: Hashable, Sendable {
    case file(RunwayFileSignature)
    case logical(String)
}

/// Result of a registry-owned non-JSONL telemetry scan.
///
/// The scanner owns only source-format decoding. The engine still owns cache
/// identity, cancellation, pricing, quota attribution, and publication.
struct SessionTelemetryProviderScan: Sendable {
    let result: SessionTelemetryProviderResult
    /// Bytes read from the source payload. A SQLite scanner reports message
    /// payload bytes, not a database path or transcript content.
    let bytesScanned: UInt64
    /// Revision captured from the exact descriptors used by the scanner. Most
    /// providers leave this nil and let the engine re-stat their source path;
    /// descriptor-backed readers use it to prevent a path A -> B -> A swap
    /// from publishing bytes read from B under revision A.
    let inputRevision: SessionTelemetryRevision?
    /// Set when the provider observed its exact input descriptors change while
    /// scanning. The engine treats this as a retryable revision race rather
    /// than falling through to another parser path.
    let revisionChanged: Bool

    init(result: SessionTelemetryProviderResult,
         bytesScanned: UInt64,
         inputRevision: SessionTelemetryRevision? = nil,
         revisionChanged: Bool = false) {
        self.result = result
        self.bytesScanned = bytesScanned
        self.inputRevision = inputRevision
        self.revisionChanged = revisionChanged
    }
}

/// A source-specific streamed telemetry parser.
///
/// The registry stores a factory for this protocol on the source descriptor. That
/// keeps the engine provider-neutral: adding a parser changes one source descriptor
/// and one provider, not a second engine switch.
protocol SessionTelemetryProvider {
    mutating func consume(line: String, index: Int)
    func finish() -> SessionTelemetryProviderResult
}

struct CodexTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = CodexTelemetryAccumulator()
    private var identity = CodexTranscriptAccountIdentity()

    mutating func consume(line: String, index: Int) {
        identity.consume(line: line)
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(),
                                       durableAccountHash: identity.durableAccountHash)
    }
}

struct ClaudeTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = ClaudeTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(),
                                       durableAccountHash: nil)
    }
}

struct PiTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = PiTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(),
                                       durableAccountHash: nil)
    }
}

struct CopilotTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = CopilotTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(),
                                       durableAccountHash: nil)
    }
}
