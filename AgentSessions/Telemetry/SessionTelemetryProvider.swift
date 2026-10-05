import Foundation

/// The result of one source-specific telemetry parse.
///
/// Providers own only transcript-format knowledge. Cache invalidation, pricing,
/// quota attribution, and cancellation remain in `SessionTelemetryEngine`.
struct SessionTelemetryProviderResult: Sendable {
    let telemetry: SessionTelemetry
    let durableAccountHash: String?
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
